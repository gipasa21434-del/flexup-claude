import Foundation

/// Fully local backend for demo mode. Every action really changes state (likes, comments, follows,
/// publications, blocks…) and is persisted to a JSON file on the device, but nothing is sent to a server.
public actor DemoBackend: FlexBackend {
    public nonisolated let mode: BackendMode = .demo

    public enum NetworkCondition: String, Codable, CaseIterable, Sendable {
        case normal, slow, offline
        public var title: String {
            switch self { case .normal: return "Нормальная сеть"; case .slow: return "Медленная сеть"; case .offline: return "Нет сети" }
        }
    }

    struct Account: Codable { var userID: UUID; var passwordHash: String }

    struct State: Codable {
        var users: [UserProfile]
        var videos: [Video]
        var comments: [Comment]
        var accounts: [String: Account]
        var liked: [UUID: Set<UUID>] = [:]      // userID -> videoIDs
        var saved: [UUID: Set<UUID>] = [:]
        var following: [UUID: Set<UUID>] = [:] // follower -> followees
        var blocked: [UUID: Set<UUID>] = [:]
        var notifications: [UUID: [ActivityNotification]] = [:]
        var reports: [Report] = []
    }

    private var state: State
    private let storageURL: URL?
    private let mediaDirectory: URL?
    private let sessionStore: SessionStore
    private var session: AuthSession?
    private var limiter = RateLimiter.default
    private let recommender = RecommendationEngine()
    private let searchEngine = SearchEngine()
    private let challengeEngine: ChallengeEngine
    private let clock: @Sendable () -> Date
    public private(set) var condition: NetworkCondition = .normal
    /// Artificial latency for `.normal`; 0 in unit tests.
    private let baseLatency: TimeInterval
    private var uploadChunkDelay: TimeInterval
    private let extraVideos: [Video]

    /// - Parameters:
    ///   - storageURL: JSON file for persistence (nil = memory only).
    ///   - mediaDirectory: where "uploaded" demo videos are copied (nil = keep original URL).
    ///   - extraVideos: additional local test videos merged into the feed (added once, kept across launches).
    public init(storageURL: URL? = nil, mediaDirectory: URL? = nil, sessionStore: SessionStore = InMemorySessionStore(),
                latency: TimeInterval = 0.25, uploadChunkDelay: TimeInterval = 0.12,
                calendar: Calendar = .current, extraVideos: [Video] = [], clock: @escaping @Sendable () -> Date = { Date() }) {
        self.storageURL = storageURL
        self.mediaDirectory = mediaDirectory
        self.sessionStore = sessionStore
        self.baseLatency = latency
        self.uploadChunkDelay = uploadChunkDelay
        self.clock = clock
        self.challengeEngine = ChallengeEngine(calendar: calendar)
        if let url = storageURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder.flex.decode(State.self, from: data) {
            state = saved
        } else {
            state = Self.seed(now: clock(), calendar: calendar)
        }
        let known = Set(state.videos.map(\.id))
        state.videos.append(contentsOf: extraVideos.filter { !known.contains($0.id) })
        self.extraVideos = extraVideos
        session = sessionStore.load()
    }

    static func seed(now: Date, calendar: Calendar) -> State {
        var accounts: [String: Account] = [:]
        for a in DemoContent.accounts {
            accounts[a.email] = Account(userID: a.userID, passwordHash: hash(DemoContent.demoPassword, salt: a.email))
        }
        let startOfDay = calendar.startOfDay(for: now)
        let videos = DemoContent.videos(now: now).map { v -> Video in
            var v = v
            // Keep today's challenge entries inside today's window so the leaderboard is never empty.
            if v.hashtags.contains("flexchallenge") { v.createdAt = min(now, max(v.createdAt, startOfDay.addingTimeInterval(60))) }
            return v
        }
        var s = State(users: DemoContent.users(now: now), videos: videos, comments: DemoContent.comments(now: now), accounts: accounts)
        let me = DemoContent.accounts[0].userID
        s.following[me] = [DemoContent.uid(2), DemoContent.uid(3), DemoContent.uid(5)]
        for a in DemoContent.accounts { s.notifications[a.userID] = DemoContent.notifications(for: a.userID, now: now) }
        return s
    }

    /// Not cryptographically meaningful; demo accounts live only on this device. Real auth = Supabase.
    static func hash(_ password: String, salt: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in (salt.lowercased() + ":" + password).utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    // MARK: Simulation controls

    public func setCondition(_ c: NetworkCondition) { condition = c }

    public func resetAllData() {
        state = Self.seed(now: clock(), calendar: challengeEngine.calendar)
        state.videos.append(contentsOf: extraVideos)
        persist()
    }

    private func network() async throws {
        switch condition {
        case .offline:
            try await Task.sleep(nanoseconds: UInt64(min(baseLatency, 0.4) * 1_000_000_000))
            throw BackendError.offline
        case .slow:
            try await Task.sleep(nanoseconds: 2_500_000_000)
        case .normal:
            if baseLatency > 0 { try await Task.sleep(nanoseconds: UInt64(baseLatency * 1_000_000_000)) }
        }
    }

    private func persist() {
        guard let url = storageURL else { return }
        if let data = try? JSONEncoder.flex.encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func requireUser() throws -> UUID {
        guard let s = session else { throw BackendError.unauthorized }
        if s.isGuest { throw BackendError.accountRequired }
        return s.userID
    }

    private var viewerID: UUID? { session?.isGuest == false ? session?.userID : nil }

    // MARK: Auth

    public func restoreSession() async -> AuthSession? { session }

    public func signUp(email: String, password: String, username: String) async throws -> AuthSession {
        if let e = Validator.email(email) { throw BackendError.validation(e) }
        if let e = Validator.password(password) { throw BackendError.validation(e) }
        if let e = Validator.username(username) { throw BackendError.validation(e) }
        try await network()
        let key = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard state.accounts[key] == nil else { throw BackendError.conflict("Аккаунт с таким email уже есть") }
        guard !state.users.contains(where: { $0.username == username.lowercased() }) else {
            throw BackendError.conflict("Никнейм уже занят")
        }
        let user = UserProfile(username: username.lowercased(), displayName: username, createdAt: clock())
        state.users.append(user)
        state.accounts[key] = Account(userID: user.id, passwordHash: Self.hash(password, salt: key))
        state.notifications[user.id] = [ActivityNotification(kind: .system, text: "Добро пожаловать во FLEX UP! (демо-аккаунт на этом устройстве)", createdAt: clock())]
        persist()
        return start(AuthSession(userID: user.id, email: key))
    }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        if let e = Validator.email(email) { throw BackendError.validation(e) }
        try await network()
        let key = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard let acc = state.accounts[key], acc.passwordHash == Self.hash(password, salt: key) else {
            throw BackendError.invalidCredentials
        }
        return start(AuthSession(userID: acc.userID, email: key))
    }

    public func signInAsGuest() async throws -> AuthSession {
        start(AuthSession(userID: UUID(), email: nil, isGuest: true))
    }

    private func start(_ s: AuthSession) -> AuthSession {
        session = s
        sessionStore.save(s)
        return s
    }

    public func sendPasswordReset(email: String) async throws {
        if let e = Validator.email(email) { throw BackendError.validation(e) }
        try await network()
        throw BackendError.notConfigured("В демо-режиме письма не отправляются. Пароль тестовых аккаунтов: \(DemoContent.demoPassword)")
    }

    public func signOut() async {
        session = nil
        sessionStore.save(nil)
    }

    public func deleteAccount() async throws {
        let me = try requireUser()
        try await network()
        state.users.removeAll { $0.id == me }
        state.videos.removeAll { $0.authorID == me }
        state.comments.removeAll { $0.authorID == me }
        state.accounts = state.accounts.filter { $0.value.userID != me }
        for k in state.following.keys { state.following[k]?.remove(me) }
        state.liked[me] = nil; state.saved[me] = nil; state.following[me] = nil
        state.blocked[me] = nil; state.notifications[me] = nil
        recount()
        persist()
        await signOut()
    }

    // MARK: Profiles

    private func user(_ id: UUID) throws -> UserProfile {
        guard let u = state.users.first(where: { $0.id == id }) else { throw BackendError.notFound }
        return u
    }

    private func recount() {
        for i in state.users.indices {
            let id = state.users[i].id
            let mine = state.videos.filter { $0.authorID == id }
            state.users[i].postsCount = mine.count
            state.users[i].followingCount = max(state.users[i].followingCount, 0)
            if state.accounts.values.contains(where: { $0.userID == id }) {
                state.users[i].followingCount = state.following[id]?.count ?? 0
            }
            if !mine.isEmpty && !mine.allSatisfy(\.isDemo) {
                state.users[i].likesCount = mine.reduce(0) { $0 + $1.likesCount }
            }
        }
    }

    public func profile(id: UUID) async throws -> UserProfile {
        try await network()
        return try user(id)
    }

    public func updateProfile(_ update: ProfileUpdate) async throws -> UserProfile {
        let me = try requireUser()
        if let e = Validator.displayName(update.displayName) { throw BackendError.validation(e) }
        if let e = Validator.username(update.username) { throw BackendError.validation(e) }
        if let e = Validator.text(update.bio, limit: Validator.bioLimit, allowEmpty: true) { throw BackendError.validation(e) }
        try await network()
        let uname = update.username.lowercased()
        if state.users.contains(where: { $0.username == uname && $0.id != me }) { throw BackendError.conflict("Никнейм уже занят") }
        guard let i = state.users.firstIndex(where: { $0.id == me }) else { throw BackendError.notFound }
        state.users[i].displayName = update.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        state.users[i].username = uname
        state.users[i].bio = update.bio.trimmingCharacters(in: .whitespacesAndNewlines)
        state.users[i].isPrivate = update.isPrivate
        if let data = update.avatarJPEG, let dir = mediaDirectory {
            let url = dir.appendingPathComponent("avatar_\(me.uuidString)_\(Int(clock().timeIntervalSince1970)).jpg")
            try? data.write(to: url, options: .atomic)
            state.users[i].avatarURL = url
        }
        persist()
        return state.users[i]
    }

    public func isUsernameAvailable(_ username: String) async throws -> Bool {
        try await network()
        let me = viewerID
        return !state.users.contains { $0.username == username.lowercased() && $0.id != me }
    }

    public func setFollow(_ follow: Bool, userID: UUID) async throws -> UserProfile {
        let me = try requireUser()
        guard me != userID else { throw BackendError.forbidden }
        try limiter.hit("follow", now: clock())
        try await network()
        guard let i = state.users.firstIndex(where: { $0.id == userID }) else { throw BackendError.notFound }
        var set = state.following[me] ?? []
        let was = set.contains(userID)
        if follow && !was {
            set.insert(userID); state.users[i].followersCount += 1
        } else if !follow && was {
            set.remove(userID); state.users[i].followersCount = max(0, state.users[i].followersCount - 1)
        }
        state.following[me] = set
        if let mi = state.users.firstIndex(where: { $0.id == me }) { state.users[mi].followingCount = set.count }
        persist()
        return state.users[i]
    }

    public func isFollowing(userID: UUID) async throws -> Bool {
        guard let me = viewerID else { return false }
        return state.following[me]?.contains(userID) ?? false
    }

    // MARK: Videos

    private func item(_ v: Video) -> FeedItem? {
        guard let author = state.users.first(where: { $0.id == v.authorID }) else { return nil }
        let me = viewerID
        return FeedItem(video: v, author: author,
                        isLiked: me.map { state.liked[$0]?.contains(v.id) ?? false } ?? false,
                        isSaved: me.map { state.saved[$0]?.contains(v.id) ?? false } ?? false,
                        isFollowingAuthor: me.map { state.following[$0]?.contains(v.authorID) ?? false } ?? false)
    }

    private func context(mood: Mood? = nil, hiddenTags: Set<String> = [], interests: InterestProfile = InterestProfile()) -> RecommendationEngine.Context {
        let me = viewerID
        return RecommendationEngine.Context(viewerID: me,
                                            following: me.flatMap { state.following[$0] } ?? [],
                                            blocked: me.flatMap { state.blocked[$0] } ?? [],
                                            hiddenTags: hiddenTags, mood: mood, interests: interests, now: clock())
    }

    private func visible(_ v: Video) -> Bool { recommender.isEligible(v, context: context()) }

    public func feed(_ query: FeedQuery) async throws -> [FeedItem] {
        try await network()
        let ctx = context(mood: query.mood, hiddenTags: query.hiddenTags, interests: query.interests)
        let ranked: [Video]
        switch query.kind {
        case .forYou: ranked = recommender.rank(state.videos, context: ctx)
        case .following:
            guard viewerID != nil else { throw BackendError.accountRequired }
            ranked = recommender.followingFeed(state.videos, context: ctx)
        }
        return ranked.prefix(query.limit).compactMap(item)
    }

    public func videos(by authorID: UUID) async throws -> [FeedItem] {
        try await network()
        let me = viewerID
        if let me, state.blocked[me]?.contains(authorID) == true { return [] }
        return state.videos.filter { $0.authorID == authorID && (authorID == me || visible($0)) }
            .sorted { $0.createdAt > $1.createdAt }.compactMap(item)
    }

    public func savedVideos() async throws -> [FeedItem] {
        let me = try requireUser()
        try await network()
        let ids = state.saved[me] ?? []
        return state.videos.filter { ids.contains($0.id) && visible($0) }.compactMap(item)
    }

    public func likedVideos() async throws -> [FeedItem] {
        let me = try requireUser()
        try await network()
        let ids = state.liked[me] ?? []
        return state.videos.filter { ids.contains($0.id) && visible($0) }.compactMap(item)
    }

    public func videos(withTag tag: String, sort: SearchSort) async throws -> [FeedItem] {
        try await network()
        let t = HashtagParser.normalize(tag)
        var list = state.videos.filter { $0.hashtags.contains(t) && $0.visibility == .everyone && visible($0) }
        switch sort {
        case .newest: list.sort { $0.createdAt > $1.createdAt }
        case .popular, .relevance: list.sort { $0.viewsCount > $1.viewsCount }
        }
        return list.compactMap(item)
    }

    public func reactions(to videoID: UUID) async throws -> [FeedItem] {
        try await network()
        return state.videos.filter { $0.replyToVideoID == videoID && visible($0) }
            .sorted { $0.createdAt > $1.createdAt }.compactMap(item)
    }

    public func feedItem(videoID: UUID) async throws -> FeedItem {
        try await network()
        guard let v = state.videos.first(where: { $0.id == videoID }), visible(v) || v.authorID == viewerID,
              let it = item(v) else { throw BackendError.notFound }
        return it
    }

    public func setLike(_ like: Bool, videoID: UUID) async throws -> Video {
        let me = try requireUser()
        try limiter.hit("like", now: clock())
        try await network()
        guard let i = state.videos.firstIndex(where: { $0.id == videoID }) else { throw BackendError.notFound }
        var set = state.liked[me] ?? []
        if like && !set.contains(videoID) {
            set.insert(videoID); state.videos[i].likesCount += 1
            notify(owner: state.videos[i].authorID, from: me, kind: .like, video: videoID, text: "оценил(а) твой ролик")
        } else if !like && set.contains(videoID) {
            set.remove(videoID); state.videos[i].likesCount = max(0, state.videos[i].likesCount - 1)
        }
        state.liked[me] = set
        persist()
        return state.videos[i]
    }

    public func setSave(_ save: Bool, videoID: UUID) async throws -> Video {
        let me = try requireUser()
        try await network()
        guard let i = state.videos.firstIndex(where: { $0.id == videoID }) else { throw BackendError.notFound }
        var set = state.saved[me] ?? []
        if save && !set.contains(videoID) { set.insert(videoID); state.videos[i].savesCount += 1 }
        else if !save && set.contains(videoID) { set.remove(videoID); state.videos[i].savesCount = max(0, state.videos[i].savesCount - 1) }
        state.saved[me] = set
        persist()
        return state.videos[i]
    }

    public func recordShare(videoID: UUID) async {
        if let i = state.videos.firstIndex(where: { $0.id == videoID }) { state.videos[i].sharesCount += 1; persist() }
    }

    public func recordView(videoID: UUID) async {
        if let i = state.videos.firstIndex(where: { $0.id == videoID }) { state.videos[i].viewsCount += 1 }
    }

    private func notify(owner: UUID, from actor: UUID, kind: ActivityKind, video: UUID?, text: String) {
        guard owner != actor else { return }
        state.notifications[owner, default: []].insert(
            ActivityNotification(kind: kind, actorID: actor, videoID: video, text: text, createdAt: clock()), at: 0)
    }

    public func publish(_ request: PublishRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> Video {
        let me = try requireUser()
        if let e = Validator.text(request.caption, limit: Validator.captionLimit, allowEmpty: true) { throw BackendError.validation(e) }
        guard FileManager.default.fileExists(atPath: request.fileURL.path) else { throw BackendError.notFound }
        try limiter.hit("publish", now: clock())
        if condition == .offline { throw BackendError.offline }
        let id = UUID()
        var source = VideoSource.local(request.fileURL.lastPathComponent)
        var thumb: VideoSource?
        // Simulated chunked upload: real file copy + visible progress + cooperative cancellation.
        let steps = 20
        for step in 1...steps {
            try Task.checkCancellation()
            if condition == .offline { throw BackendError.offline }
            let delay = condition == .slow ? uploadChunkDelay * 4 : uploadChunkDelay
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            progress(Double(step) / Double(steps) * 0.95)
        }
        try Task.checkCancellation()
        if let dir = mediaDirectory {
            let dest = dir.appendingPathComponent("\(id.uuidString).mp4")
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: request.fileURL, to: dest) }
            catch { throw BackendError.server("Не удалось сохранить файл: \(error.localizedDescription)") }
            source = .local(dest.lastPathComponent)
            if let cover = request.coverJPEG {
                let coverURL = dir.appendingPathComponent("\(id.uuidString).jpg")
                try? cover.write(to: coverURL, options: .atomic)
                thumb = .local(coverURL.lastPathComponent)
            }
        } else {
            source = .remote(request.fileURL)
        }
        var tags = HashtagParser.extract(from: request.caption)
        if let c = request.challengeTag.map(HashtagParser.normalize), !tags.contains(c) { tags.append(c) }
        let video = Video(id: id, authorID: me, caption: request.caption.trimmingCharacters(in: .whitespacesAndNewlines),
                          hashtags: tags, musicTitle: request.musicTitle, mood: request.mood, duration: request.duration,
                          source: source, thumbnail: thumb, createdAt: clock(), visibility: request.visibility,
                          challengeTag: request.challengeTag.map(HashtagParser.normalize), replyToVideoID: request.replyToVideoID)
        state.videos.insert(video, at: 0)
        if let original = request.replyToVideoID, let o = state.videos.first(where: { $0.id == original }) {
            notify(owner: o.authorID, from: me, kind: .react, video: id, text: "записал(а) DUO REACT на твой ролик")
        }
        recount()
        persist()
        progress(1)
        return video
    }

    public func deleteVideo(id: UUID) async throws {
        let me = try requireUser()
        try await network()
        guard let v = state.videos.first(where: { $0.id == id }) else { throw BackendError.notFound }
        guard v.authorID == me else { throw BackendError.forbidden }
        state.videos.removeAll { $0.id == id }
        state.comments.removeAll { $0.videoID == id }
        if case let .local(name) = v.source, let dir = mediaDirectory {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        recount()
        persist()
    }

    // MARK: Comments

    public func comments(videoID: UUID) async throws -> [CommentItem] {
        try await network()
        let me = viewerID
        let blocked = me.flatMap { state.blocked[$0] } ?? []
        return state.comments.filter { $0.videoID == videoID && !blocked.contains($0.authorID) }
            .sorted { $0.createdAt > $1.createdAt }
            .compactMap { c in (try? user(c.authorID)).map { CommentItem(comment: c, author: $0, isMine: c.authorID == me) } }
    }

    public func addComment(videoID: UUID, text: String) async throws -> CommentItem {
        let me = try requireUser()
        if let e = Validator.text(text, limit: Validator.commentLimit) { throw BackendError.validation(e) }
        try limiter.hit("comment", now: clock())
        try await network()
        guard let i = state.videos.firstIndex(where: { $0.id == videoID }) else { throw BackendError.notFound }
        if state.blocked[state.videos[i].authorID]?.contains(me) == true { throw BackendError.forbidden }
        let c = Comment(videoID: videoID, authorID: me, text: text.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: clock())
        state.comments.append(c)
        state.videos[i].commentsCount += 1
        notify(owner: state.videos[i].authorID, from: me, kind: .comment, video: videoID, text: "прокомментировал(а): «\(c.text.prefix(60))»")
        persist()
        return CommentItem(comment: c, author: try user(me), isMine: true)
    }

    public func deleteComment(id: UUID) async throws {
        let me = try requireUser()
        try await network()
        guard let c = state.comments.first(where: { $0.id == id }) else { throw BackendError.notFound }
        let videoOwner = state.videos.first(where: { $0.id == c.videoID })?.authorID
        // Own comments, or any comment under your own video (moderation of your space).
        guard c.authorID == me || videoOwner == me else { throw BackendError.forbidden }
        state.comments.removeAll { $0.id == id }
        if let i = state.videos.firstIndex(where: { $0.id == c.videoID }) {
            state.videos[i].commentsCount = max(0, state.videos[i].commentsCount - 1)
        }
        persist()
    }

    // MARK: Discovery

    public func search(_ query: String, scope: SearchScope, sort: SearchSort, mood: Mood?) async throws -> SearchResults {
        try await network()
        let blocked = viewerID.flatMap { state.blocked[$0] } ?? []
        var r = searchEngine.search(query, scope: scope, sort: sort, mood: mood, users: state.users,
                                    videos: state.videos.filter(visible), blocked: blocked)
        r.videoItems = r.videos.compactMap(item)
        return r
    }

    public func suggestions(prefix: String, history: [String]) async -> [String] {
        searchEngine.suggestions(for: prefix, history: history, users: state.users, videos: state.videos.filter(visible))
    }

    public func trendingHashtags() async throws -> [HashtagSummary] {
        try await network()
        return Array(searchEngine.hashtagIndex(state.videos.filter(visible)).prefix(12))
    }

    public func challenges() async throws -> [Challenge] {
        try await network()
        return demoSchedule()
    }

    private func demoSchedule() -> [Challenge] {
        let t = DemoContent.challengeTemplates
        let cal = challengeEngine.calendar
        let dayIndex = Int(cal.startOfDay(for: clock()).timeIntervalSince1970 / 86_400)
        let k = ((dayIndex % t.count) + t.count) % t.count
        // Rotate so that today's challenge is always #flexchallenge in the demo.
        let rotated = t.indices.map { t[($0 - k + t.count) % t.count] }
        return challengeEngine.dailySchedule(templates: rotated, around: clock())
    }

    public func leaderboard(for challenge: Challenge) async throws -> [LeaderboardEntry] {
        try await network()
        let blocked = viewerID.flatMap { state.blocked[$0] } ?? []
        return challengeEngine.leaderboard(for: challenge, videos: state.videos, blocked: blocked).compactMap { e in
            item(e.video).map { LeaderboardEntry(rank: e.rank, score: e.score, item: $0) }
        }
    }

    // MARK: Safety

    public func report(_ report: Report) async throws {
        _ = try requireUser()
        try limiter.hit("report", now: clock())
        try await network()
        state.reports.append(report)
        persist()
    }

    public func setBlocked(_ blocked: Bool, userID: UUID) async throws {
        let me = try requireUser()
        guard me != userID else { throw BackendError.forbidden }
        try await network()
        var set = state.blocked[me] ?? []
        if blocked {
            set.insert(userID)
            state.following[me]?.remove(userID)
            state.following[userID]?.remove(me)
        } else {
            set.remove(userID)
        }
        state.blocked[me] = set
        persist()
    }

    public func blockedUsers() async throws -> [UserProfile] {
        let me = try requireUser()
        try await network()
        let ids = state.blocked[me] ?? []
        return state.users.filter { ids.contains($0.id) }
    }

    // MARK: Activity

    public func notifications() async throws -> [ActivityNotification] {
        let me = try requireUser()
        try await network()
        let blocked = state.blocked[me] ?? []
        return (state.notifications[me] ?? []).filter { $0.actorID.map { !blocked.contains($0) } ?? true }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func markNotificationsRead() async throws {
        let me = try requireUser()
        state.notifications[me] = state.notifications[me]?.map { var n = $0; n.isRead = true; return n }
        persist()
    }

    // MARK: Helpers for UI that need cached lookups

    public func cachedUser(_ id: UUID) -> UserProfile? { state.users.first { $0.id == id } }
    public func reportsCount() -> Int { state.reports.count }
}

extension JSONDecoder {
    public static let flex: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    public static let flex: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
