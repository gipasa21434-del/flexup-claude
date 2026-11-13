import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SupabaseConfig: Sendable, Equatable {
    public var url: URL
    public var anonKey: String
    public var videoBucket = "videos"
    public var thumbBucket = "thumbnails"
    public var avatarBucket = "avatars"
    public var requestTimeout: TimeInterval = 20

    public init(url: URL, anonKey: String) { self.url = url; self.anonKey = anonKey }

    /// Reads `SUPABASE_URL` / `SUPABASE_ANON_KEY` (Info.plist or environment). Returns nil when absent/placeholder.
    public static func from(values: [String: Any]) -> SupabaseConfig? {
        guard let raw = values["SUPABASE_URL"] as? String, let key = values["SUPABASE_ANON_KEY"] as? String,
              !raw.isEmpty, !key.isEmpty, !raw.contains("$("), !key.contains("$("),
              let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme == "https",
              let host = url.host, host.contains(".") else { return nil }
        return SupabaseConfig(url: url, anonKey: key)
    }
}

/// Real backend over Supabase REST APIs (GoTrue auth, PostgREST, Storage) using plain URLSession —
/// no third-party SDK, so the project has zero external dependencies.
/// Server-side guarantees (RLS, rate limits, counters, notifications) live in `supabase/migrations`.
public final class SupabaseBackend: FlexBackend, @unchecked Sendable {
    public let mode: BackendMode = .supabase
    public let config: SupabaseConfig
    private let session: URLSession
    private let store: SessionStore
    private let lock = NSLock()
    private var auth: AuthSession?

    public init(config: SupabaseConfig, sessionStore: SessionStore, urlSession: URLSession? = nil) {
        self.config = config
        self.store = sessionStore
        if let urlSession {
            self.session = urlSession
        } else {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = config.requestTimeout
            #if !canImport(FoundationNetworking)
            c.waitsForConnectivity = false
            #endif
            self.session = URLSession(configuration: c)
        }
        self.auth = sessionStore.load()
    }

    var currentAuth: AuthSession? { lock.lock(); defer { lock.unlock() }; return auth }
    private func setAuth(_ a: AuthSession?) { lock.lock(); auth = a; lock.unlock(); store.save(a) }

    private func requireUser() throws -> UUID {
        guard let a = currentAuth else { throw BackendError.unauthorized }
        if a.isGuest { throw BackendError.accountRequired }
        return a.userID
    }

    // MARK: - HTTP core

    enum Method: String { case GET, POST, PATCH, DELETE }

    func makeRequest(_ method: Method, path: String, query: [URLQueryItem] = [], body: Data? = nil,
                     headers: [String: String] = [:], authorized: Bool = true) -> URLRequest {
        var comps = URLComponents(url: config.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method.rawValue
        r.timeoutInterval = config.requestTimeout
        r.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        let bearer = (authorized ? currentAuth?.accessToken : nil) ?? config.anonKey
        r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        headers.forEach { r.setValue($0.value, forHTTPHeaderField: $0.key) }
        r.httpBody = body
        return r
    }

    @discardableResult
    func send(_ request: URLRequest, retryOnAuth: Bool = true) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let e as URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: throw BackendError.offline
            case .timedOut: throw BackendError.timeout
            case .cancelled: throw BackendError.cancelled
            default: throw BackendError.server(e.localizedDescription)
            }
        } catch is CancellationError {
            throw BackendError.cancelled
        }
        guard let http = response as? HTTPURLResponse else { throw BackendError.server("Нет ответа") }
        if http.statusCode == 401, retryOnAuth, currentAuth?.refreshToken != nil {
            try await refresh()
            var retried = request
            if let token = currentAuth?.accessToken { retried.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            return try await send(retried, retryOnAuth: false)
        }
        try Self.check(status: http.statusCode, data: data, headers: http.allHeaderFields)
        return data
    }

    static func check(status: Int, data: Data, headers: [AnyHashable: Any] = [:]) throws {
        guard !(200..<300).contains(status) else { return }
        let message = Self.errorMessage(data)
        switch status {
        case 400 where message.lowercased().contains("invalid login"): throw BackendError.invalidCredentials
        case 400 where message.lowercased().contains("email not confirmed"): throw BackendError.emailConfirmationRequired
        case 401: throw BackendError.unauthorized
        case 403: throw BackendError.forbidden
        case 404: throw BackendError.notFound
        case 409: throw BackendError.conflict(message.isEmpty ? "Конфликт данных" : message)
        case 429:
            let retry = (headers["Retry-After"] as? String).flatMap(Int.init) ?? 30
            throw BackendError.rateLimited(retryAfter: retry)
        default:
            // Postgres rate-limit trigger raises SQLSTATE P0429 with this prefix.
            if message.contains("rate_limited") { throw BackendError.rateLimited(retryAfter: 60) }
            if message.contains("duplicate key") { throw BackendError.conflict("Уже существует") }
            throw BackendError.server(message.isEmpty ? "HTTP \(status)" : message)
        }
    }

    static func errorMessage(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        for key in ["msg", "message", "error_description", "error", "hint"] {
            if let s = obj[key] as? String, !s.isEmpty { return s }
        }
        return ""
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
            if let d = f1.date(from: s) ?? f2.date(from: s) { return d }
            // Postgres default text form: "2026-11-13 10:00:00.123+00"
            let pg = s.replacingOccurrences(of: " ", with: "T")
            let fixed = pg.hasSuffix("+00") ? pg + ":00" : pg
            if let d = f1.date(from: fixed) ?? f2.date(from: fixed) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
        }
        return d
    }()

    func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    // MARK: - DTOs

    struct AuthResponse: Decodable {
        struct U: Decodable { let id: UUID; let email: String? }
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Double?
        let user: U?
        let id: UUID?          // signup without session returns the user object at top level
    }

    struct ProfileRow: Decodable {
        let id: UUID
        let username: String
        let displayName: String
        let bio: String?
        let avatarUrl: String?
        let avatarColors: [String]?
        let followersCount: Int?
        let followingCount: Int?
        let likesCount: Int?
        let postsCount: Int?
        let isPrivate: Bool?
        let isVerified: Bool?
        let createdAt: Date?

        var model: UserProfile {
            UserProfile(id: id, username: username, displayName: displayName, bio: bio ?? "",
                        avatarColors: avatarColors ?? ["#8A2BFF", "#19E3D1"], avatarURL: avatarUrl.flatMap(URL.init(string:)),
                        followersCount: followersCount ?? 0, followingCount: followingCount ?? 0,
                        likesCount: likesCount ?? 0, postsCount: postsCount ?? 0,
                        isPrivate: isPrivate ?? false, isVerified: isVerified ?? false, createdAt: createdAt ?? Date())
        }
    }

    /// Row shape of the `feed_items` view and feed RPCs (video joined with author + viewer flags).
    struct FeedRow: Decodable {
        let id: UUID
        let authorId: UUID
        let caption: String
        let hashtags: [String]?
        let musicTitle: String?
        let mood: String?
        let duration: Double?
        let videoUrl: String?
        let hlsUrl: String?
        let thumbnailUrl: String?
        let likesCount: Int?
        let commentsCount: Int?
        let savesCount: Int?
        let sharesCount: Int?
        let viewsCount: Int?
        let createdAt: Date
        let visibility: String?
        let challengeTag: String?
        let replyTo: UUID?
        let author: ProfileRow
        let isLiked: Bool?
        let isSaved: Bool?
        let isFollowing: Bool?

        var item: FeedItem {
            // Prefer HLS when the (optional) transcoding pipeline filled it in.
            let src = (hlsUrl ?? videoUrl).flatMap(URL.init(string:)).map(VideoSource.remote) ?? .remote(URL(string: "about:blank")!)
            let v = Video(id: id, authorID: authorId, caption: caption, hashtags: hashtags ?? [],
                          musicTitle: musicTitle ?? "Оригинальный звук", mood: mood.flatMap(Mood.init(rawValue:)),
                          duration: duration ?? 0, source: src,
                          thumbnail: thumbnailUrl.flatMap(URL.init(string:)).map(VideoSource.remote),
                          likesCount: likesCount ?? 0, commentsCount: commentsCount ?? 0, savesCount: savesCount ?? 0,
                          sharesCount: sharesCount ?? 0, viewsCount: viewsCount ?? 0, createdAt: createdAt,
                          visibility: VideoVisibility(rawValue: visibility == "only_me" ? "onlyMe" : (visibility ?? "everyone")) ?? .everyone,
                          challengeTag: challengeTag, replyToVideoID: replyTo)
            return FeedItem(video: v, author: author.model, isLiked: isLiked ?? false, isSaved: isSaved ?? false,
                            isFollowingAuthor: isFollowing ?? false)
        }
    }

    struct CommentRow: Decodable {
        let id: UUID; let videoId: UUID; let authorId: UUID; let body: String; let createdAt: Date
        let likesCount: Int?; let author: ProfileRow
    }

    struct ChallengeRow: Decodable {
        let id: UUID; let tag: String; let title: String; let details: String?; let emoji: String?
        let startsAt: Date; let endsAt: Date
        var model: Challenge { Challenge(id: id, tag: tag, title: title, details: details ?? "", emoji: emoji ?? "🏆", startsAt: startsAt, endsAt: endsAt) }
    }

    struct NotificationRow: Decodable {
        let id: UUID; let kind: String; let actorId: UUID?; let videoId: UUID?; let body: String
        let createdAt: Date; let isRead: Bool
    }

    struct HashtagRow: Decodable { let tag: String; let videoCount: Int; let totalViews: Int }
    struct LeaderRow: Decodable { let rank: Int; let score: Int; let video: FeedRow }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw BackendError.server("Неожиданный ответ сервера (\(error))") }
    }

    // MARK: - Auth

    public func restoreSession() async -> AuthSession? {
        guard let a = currentAuth else { return nil }
        if a.isGuest { return a }
        if let exp = a.expiresAt, exp < Date().addingTimeInterval(60) {
            do { try await refresh() } catch BackendError.offline { return a } catch { setAuth(nil); return nil }
        }
        return currentAuth
    }

    private func handleAuth(_ data: Data, fallbackEmail: String?) throws -> AuthSession {
        let r = try decode(AuthResponse.self, data)
        guard let token = r.accessToken, let user = r.user else { throw BackendError.emailConfirmationRequired }
        let s = AuthSession(userID: user.id, email: user.email ?? fallbackEmail, accessToken: token,
                            refreshToken: r.refreshToken, expiresAt: r.expiresIn.map { Date().addingTimeInterval($0) })
        setAuth(s)
        return s
    }

    public func signUp(email: String, password: String, username: String) async throws -> AuthSession {
        if let e = Validator.email(email) { throw BackendError.validation(e) }
        if let e = Validator.password(password) { throw BackendError.validation(e) }
        if let e = Validator.username(username) { throw BackendError.validation(e) }
        let body = json(["email": email, "password": password, "data": ["username": username.lowercased()]])
        let data = try await send(makeRequest(.POST, path: "auth/v1/signup", body: body, authorized: false))
        return try handleAuth(data, fallbackEmail: email)
    }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        if let e = Validator.email(email) { throw BackendError.validation(e) }
        let body = json(["email": email, "password": password])
        let data = try await send(makeRequest(.POST, path: "auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "password")],
                                              body: body, authorized: false), retryOnAuth: false)
        return try handleAuth(data, fallbackEmail: email)
    }

    func refresh() async throws {
        guard let token = currentAuth?.refreshToken else { throw BackendError.unauthorized }
        let req = makeRequest(.POST, path: "auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                              body: json(["refresh_token": token]), authorized: false)
        let data = try await send(req, retryOnAuth: false)
        _ = try handleAuth(data, fallbackEmail: currentAuth?.email)
    }

    public func signInAsGuest() async throws -> AuthSession {
        // Guests read public content with the anon key; RLS allows SELECT of public videos only.
        let s = AuthSession(userID: UUID(), email: nil, isGuest: true)
        setAuth(s)
        return s
    }

    public func sendPasswordReset(email: String) async throws {
        if let e = Validator.email(email) { throw BackendError.validation(e) }
        try await send(makeRequest(.POST, path: "auth/v1/recover", body: json(["email": email]), authorized: false))
    }

    public func signOut() async {
        if currentAuth?.accessToken != nil {
            _ = try? await send(makeRequest(.POST, path: "auth/v1/logout"), retryOnAuth: false)
        }
        setAuth(nil)
    }

    public func deleteAccount() async throws {
        _ = try requireUser()
        try await send(makeRequest(.POST, path: "rest/v1/rpc/delete_my_account", body: json([:])))
        setAuth(nil)
    }

    // MARK: - Profiles

    static let profileSelect = "id,username,display_name,bio,avatar_url,avatar_colors,followers_count,following_count,likes_count,posts_count,is_private,is_verified,created_at"

    public func profile(id: UUID) async throws -> UserProfile {
        let data = try await send(makeRequest(.GET, path: "rest/v1/profiles", query: [
            URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())"),
            URLQueryItem(name: "select", value: Self.profileSelect)
        ]))
        guard let row = try decode([ProfileRow].self, data).first else { throw BackendError.notFound }
        return row.model
    }

    public func updateProfile(_ update: ProfileUpdate) async throws -> UserProfile {
        let me = try requireUser()
        if let e = Validator.displayName(update.displayName) { throw BackendError.validation(e) }
        if let e = Validator.username(update.username) { throw BackendError.validation(e) }
        if let e = Validator.text(update.bio, limit: Validator.bioLimit, allowEmpty: true) { throw BackendError.validation(e) }
        var fields: [String: Any] = ["display_name": update.displayName, "username": update.username.lowercased(),
                                     "bio": update.bio, "is_private": update.isPrivate]
        if let jpeg = update.avatarJPEG {
            let path = "\(me.uuidString.lowercased())/avatar-\(Int(Date().timeIntervalSince1970)).jpg"
            try await uploadObject(bucket: config.avatarBucket, path: path, data: jpeg, contentType: "image/jpeg")
            fields["avatar_url"] = publicURL(bucket: config.avatarBucket, path: path).absoluteString
        }
        let data = try await send(makeRequest(.PATCH, path: "rest/v1/profiles",
                                              query: [URLQueryItem(name: "id", value: "eq.\(me.uuidString.lowercased())"),
                                                      URLQueryItem(name: "select", value: Self.profileSelect)],
                                              body: json(fields), headers: ["Prefer": "return=representation"]))
        guard let row = try decode([ProfileRow].self, data).first else { throw BackendError.notFound }
        return row.model
    }

    public func isUsernameAvailable(_ username: String) async throws -> Bool {
        let data = try await send(makeRequest(.POST, path: "rest/v1/rpc/username_available", body: json(["p_username": username.lowercased()])))
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? Bool) ?? false
    }

    public func setFollow(_ follow: Bool, userID: UUID) async throws -> UserProfile {
        let me = try requireUser()
        if follow {
            try await send(makeRequest(.POST, path: "rest/v1/follows",
                                       body: json(["follower_id": me.uuidString.lowercased(), "followee_id": userID.uuidString.lowercased()]),
                                       headers: ["Prefer": "resolution=ignore-duplicates"]))
        } else {
            try await send(makeRequest(.DELETE, path: "rest/v1/follows", query: [
                URLQueryItem(name: "follower_id", value: "eq.\(me.uuidString.lowercased())"),
                URLQueryItem(name: "followee_id", value: "eq.\(userID.uuidString.lowercased())")
            ]))
        }
        return try await profile(id: userID)
    }

    public func isFollowing(userID: UUID) async throws -> Bool {
        guard let me = try? requireUser() else { return false }
        let data = try await send(makeRequest(.GET, path: "rest/v1/follows", query: [
            URLQueryItem(name: "follower_id", value: "eq.\(me.uuidString.lowercased())"),
            URLQueryItem(name: "followee_id", value: "eq.\(userID.uuidString.lowercased())"),
            URLQueryItem(name: "select", value: "followee_id")
        ]))
        return ((try? JSONSerialization.jsonObject(with: data)) as? [Any])?.isEmpty == false
    }

    // MARK: - Videos

    private func rpcFeed(_ name: String, _ params: [String: Any]) async throws -> [FeedItem] {
        let data = try await send(makeRequest(.POST, path: "rest/v1/rpc/\(name)", body: json(params)))
        return try decode([FeedRow].self, data).map(\.item)
    }

    public func feed(_ query: FeedQuery) async throws -> [FeedItem] {
        var params: [String: Any] = ["p_limit": query.limit, "p_hidden_tags": Array(query.hiddenTags)]
        params["p_mood"] = query.mood?.rawValue ?? NSNull()
        switch query.kind {
        case .forYou:
            return try await rpcFeed("feed_for_you", params)
        case .following:
            _ = try requireUser()
            return try await rpcFeed("feed_following", ["p_limit": query.limit])
        }
    }

    public func videos(by authorID: UUID) async throws -> [FeedItem] {
        try await rpcFeed("videos_by_author", ["p_author": authorID.uuidString.lowercased()])
    }

    public func savedVideos() async throws -> [FeedItem] { _ = try requireUser(); return try await rpcFeed("my_saved_videos", [:]) }
    public func likedVideos() async throws -> [FeedItem] { _ = try requireUser(); return try await rpcFeed("my_liked_videos", [:]) }

    public func videos(withTag tag: String, sort: SearchSort) async throws -> [FeedItem] {
        try await rpcFeed("videos_by_tag", ["p_tag": HashtagParser.normalize(tag), "p_sort": sort.rawValue])
    }

    public func reactions(to videoID: UUID) async throws -> [FeedItem] {
        try await rpcFeed("video_reactions", ["p_video": videoID.uuidString.lowercased()])
    }

    public func feedItem(videoID: UUID) async throws -> FeedItem {
        guard let first = try await rpcFeed("video_by_id", ["p_video": videoID.uuidString.lowercased()]).first else {
            throw BackendError.notFound
        }
        return first
    }

    private func toggle(table: String, on: Bool, videoID: UUID) async throws -> Video {
        let me = try requireUser()
        let vid = videoID.uuidString.lowercased(), uid = me.uuidString.lowercased()
        if on {
            try await send(makeRequest(.POST, path: "rest/v1/\(table)", body: json(["video_id": vid, "user_id": uid]),
                                       headers: ["Prefer": "resolution=ignore-duplicates"]))
        } else {
            try await send(makeRequest(.DELETE, path: "rest/v1/\(table)", query: [
                URLQueryItem(name: "video_id", value: "eq.\(vid)"), URLQueryItem(name: "user_id", value: "eq.\(uid)")
            ]))
        }
        return try await feedItem(videoID: videoID).video
    }

    public func setLike(_ like: Bool, videoID: UUID) async throws -> Video { try await toggle(table: "likes", on: like, videoID: videoID) }
    public func setSave(_ save: Bool, videoID: UUID) async throws -> Video { try await toggle(table: "saves", on: save, videoID: videoID) }

    public func recordShare(videoID: UUID) async {
        _ = try? await send(makeRequest(.POST, path: "rest/v1/rpc/record_share", body: json(["p_video": videoID.uuidString.lowercased()])))
    }

    public func recordView(videoID: UUID) async {
        _ = try? await send(makeRequest(.POST, path: "rest/v1/rpc/record_view", body: json(["p_video": videoID.uuidString.lowercased()])))
    }

    public func publicURL(bucket: String, path: String) -> URL {
        config.url.appendingPathComponent("storage/v1/object/public/\(bucket)/\(path)")
    }

    func uploadObject(bucket: String, path: String, data: Data, contentType: String) async throws {
        var r = makeRequest(.POST, path: "storage/v1/object/\(bucket)/\(path)", headers: ["Content-Type": contentType, "x-upsert": "false"])
        r.httpBody = data
        try await send(r)
    }

    /// Streams the video file to Supabase Storage with real byte-level progress and cancellation.
    func uploadFile(bucket: String, path: String, fileURL: URL, contentType: String,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        var r = makeRequest(.POST, path: "storage/v1/object/\(bucket)/\(path)", headers: ["Content-Type": contentType, "x-upsert": "false"])
        r.timeoutInterval = 300
        let delegate = UploadProgressDelegate(progress: progress)
        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let task = session.uploadTask(with: r, fromFile: fileURL) { data, response, error in
                    if let e = error as? URLError {
                        cont.resume(throwing: e.code == .cancelled ? BackendError.cancelled
                                    : (e.code == .notConnectedToInternet ? BackendError.offline : BackendError.server(e.localizedDescription)))
                        return
                    }
                    if let error { cont.resume(throwing: BackendError.server(error.localizedDescription)); return }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    do { try Self.check(status: status, data: data ?? Data()); cont.resume() }
                    catch { cont.resume(throwing: error) }
                }
                #if !canImport(FoundationNetworking)
                task.delegate = delegate // per-task delegate (iOS 15+) gives byte-level progress
                #else
                _ = delegate
                #endif
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    public func publish(_ request: PublishRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> Video {
        let me = try requireUser()
        if let e = Validator.text(request.caption, limit: Validator.captionLimit, allowEmpty: true) { throw BackendError.validation(e) }
        let id = UUID()
        let folder = me.uuidString.lowercased()
        let videoPath = "\(folder)/\(id.uuidString.lowercased()).mp4"
        try await uploadFile(bucket: config.videoBucket, path: videoPath, fileURL: request.fileURL, contentType: "video/mp4") {
            progress($0 * 0.9)
        }
        var thumbURL: String?
        if let cover = request.coverJPEG {
            let p = "\(folder)/\(id.uuidString.lowercased()).jpg"
            try await uploadObject(bucket: config.thumbBucket, path: p, data: cover, contentType: "image/jpeg")
            thumbURL = publicURL(bucket: config.thumbBucket, path: p).absoluteString
        }
        try Task.checkCancellation()
        var tags = HashtagParser.extract(from: request.caption)
        if let c = request.challengeTag.map(HashtagParser.normalize), !tags.contains(c) { tags.append(c) }
        let row: [String: Any] = [
            "id": id.uuidString.lowercased(), "author_id": folder, "caption": request.caption,
            "hashtags": tags, "music_title": request.musicTitle, "mood": request.mood?.rawValue ?? NSNull(),
            "duration": request.duration, "storage_path": videoPath,
            "video_url": publicURL(bucket: config.videoBucket, path: videoPath).absoluteString,
            "thumbnail_url": thumbURL ?? NSNull(),
            "visibility": request.visibility == .onlyMe ? "only_me" : request.visibility.rawValue,
            "challenge_tag": request.challengeTag.map(HashtagParser.normalize) ?? NSNull(),
            "reply_to": request.replyToVideoID?.uuidString.lowercased() ?? NSNull()
        ]
        do {
            try await send(makeRequest(.POST, path: "rest/v1/videos", body: json(row), headers: ["Prefer": "return=minimal"]))
        } catch {
            // Don't leave orphaned files when the DB insert is rejected (e.g. rate limit).
            _ = try? await send(makeRequest(.DELETE, path: "storage/v1/object/\(config.videoBucket)/\(videoPath)"))
            throw error
        }
        progress(1)
        return try await feedItem(videoID: id).video
    }

    public func deleteVideo(id: UUID) async throws {
        _ = try requireUser()
        // RLS: only the author can delete; a trigger removes the storage objects.
        try await send(makeRequest(.DELETE, path: "rest/v1/videos", query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")]))
    }

    // MARK: - Comments

    public func comments(videoID: UUID) async throws -> [CommentItem] {
        let me = currentAuth?.isGuest == false ? currentAuth?.userID : nil
        let data = try await send(makeRequest(.GET, path: "rest/v1/comments", query: [
            URLQueryItem(name: "video_id", value: "eq.\(videoID.uuidString.lowercased())"),
            URLQueryItem(name: "select", value: "id,video_id,author_id,body,created_at,likes_count,author:profiles!comments_author_id_fkey(\(Self.profileSelect))"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "200")
        ]))
        return try decode([CommentRow].self, data).map {
            CommentItem(comment: Comment(id: $0.id, videoID: $0.videoId, authorID: $0.authorId, text: $0.body,
                                         createdAt: $0.createdAt, likesCount: $0.likesCount ?? 0),
                        author: $0.author.model, isMine: $0.authorId == me)
        }
    }

    public func addComment(videoID: UUID, text: String) async throws -> CommentItem {
        let me = try requireUser()
        if let e = Validator.text(text, limit: Validator.commentLimit) { throw BackendError.validation(e) }
        let data = try await send(makeRequest(.POST, path: "rest/v1/comments", query: [
            URLQueryItem(name: "select", value: "id,video_id,author_id,body,created_at,likes_count,author:profiles!comments_author_id_fkey(\(Self.profileSelect))")
        ], body: json(["video_id": videoID.uuidString.lowercased(), "author_id": me.uuidString.lowercased(),
                       "body": text.trimmingCharacters(in: .whitespacesAndNewlines)]),
           headers: ["Prefer": "return=representation"]))
        guard let r = try decode([CommentRow].self, data).first else { throw BackendError.server("Пустой ответ") }
        return CommentItem(comment: Comment(id: r.id, videoID: r.videoId, authorID: r.authorId, text: r.body, createdAt: r.createdAt),
                           author: r.author.model, isMine: true)
    }

    public func deleteComment(id: UUID) async throws {
        _ = try requireUser()
        try await send(makeRequest(.DELETE, path: "rest/v1/comments", query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")]))
    }

    // MARK: - Discovery

    public func search(_ query: String, scope: SearchScope, sort: SearchSort, mood: Mood?) async throws -> SearchResults {
        let q = query.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#@")))
        guard !q.isEmpty else { return SearchResults() }
        var result = SearchResults()
        if scope == .all || scope == .users, !query.hasPrefix("#") {
            let data = try await send(makeRequest(.POST, path: "rest/v1/rpc/search_profiles", body: json(["p_query": q])))
            result.users = try decode([ProfileRow].self, data).map(\.model)
        }
        if scope == .all || scope == .videos, !query.hasPrefix("@") {
            result.videoItems = try await rpcFeed("search_videos", ["p_query": q, "p_sort": sort.rawValue, "p_mood": mood?.rawValue ?? NSNull()])
            result.videos = result.videoItems.map(\.video)
        }
        if scope == .all || scope == .hashtags, !query.hasPrefix("@") {
            let data = try await send(makeRequest(.POST, path: "rest/v1/rpc/search_hashtags", body: json(["p_query": q])))
            result.hashtags = try decode([HashtagRow].self, data).map { HashtagSummary(tag: $0.tag, videoCount: $0.videoCount, totalViews: $0.totalViews) }
        }
        return result
    }

    public func suggestions(prefix: String, history: [String]) async -> [String] {
        let p = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        var out = history.filter { p.isEmpty || $0.lowercased().hasPrefix(p) }.prefix(4).map { $0 }
        if let tags = try? await trendingHashtags() {
            out += tags.map { "#" + $0.tag }.filter { p.isEmpty || $0.hasPrefix(p.hasPrefix("#") ? p : "#" + p) }
        }
        return Array(NSOrderedSet(array: out).array.compactMap { $0 as? String }.prefix(8))
    }

    public func trendingHashtags() async throws -> [HashtagSummary] {
        let data = try await send(makeRequest(.POST, path: "rest/v1/rpc/trending_hashtags", body: json(["p_limit": 12])))
        return try decode([HashtagRow].self, data).map { HashtagSummary(tag: $0.tag, videoCount: $0.videoCount, totalViews: $0.totalViews) }
    }

    public func challenges() async throws -> [Challenge] {
        let data = try await send(makeRequest(.GET, path: "rest/v1/challenges", query: [
            URLQueryItem(name: "select", value: "id,tag,title,details,emoji,starts_at,ends_at"),
            URLQueryItem(name: "order", value: "starts_at.desc"), URLQueryItem(name: "limit", value: "30")
        ]))
        return try decode([ChallengeRow].self, data).map(\.model)
    }

    public func leaderboard(for challenge: Challenge) async throws -> [LeaderboardEntry] {
        let data = try await send(makeRequest(.POST, path: "rest/v1/rpc/challenge_leaderboard",
                                              body: json(["p_challenge": challenge.id.uuidString.lowercased(), "p_limit": 50])))
        return try decode([LeaderRow].self, data).map { LeaderboardEntry(rank: $0.rank, score: $0.score, item: $0.video.item) }
    }

    // MARK: - Safety

    public func report(_ report: Report) async throws {
        let me = try requireUser()
        var kind = "video", target = UUID()
        switch report.target {
        case let .video(id): kind = "video"; target = id
        case let .comment(id): kind = "comment"; target = id
        case let .user(id): kind = "user"; target = id
        }
        try await send(makeRequest(.POST, path: "rest/v1/reports", body: json([
            "reporter_id": me.uuidString.lowercased(), "target_kind": kind, "target_id": target.uuidString.lowercased(),
            "reason": report.reason.rawValue, "details": String(report.details.prefix(500))
        ]), headers: ["Prefer": "return=minimal"]))
    }

    public func setBlocked(_ blocked: Bool, userID: UUID) async throws {
        let me = try requireUser()
        if blocked {
            try await send(makeRequest(.POST, path: "rest/v1/blocks",
                                       body: json(["blocker_id": me.uuidString.lowercased(), "blocked_id": userID.uuidString.lowercased()]),
                                       headers: ["Prefer": "resolution=ignore-duplicates"]))
        } else {
            try await send(makeRequest(.DELETE, path: "rest/v1/blocks", query: [
                URLQueryItem(name: "blocker_id", value: "eq.\(me.uuidString.lowercased())"),
                URLQueryItem(name: "blocked_id", value: "eq.\(userID.uuidString.lowercased())")
            ]))
        }
    }

    public func blockedUsers() async throws -> [UserProfile] {
        _ = try requireUser()
        let data = try await send(makeRequest(.POST, path: "rest/v1/rpc/my_blocked_profiles", body: json([:])))
        return try decode([ProfileRow].self, data).map(\.model)
    }

    // MARK: - Activity

    public func notifications() async throws -> [ActivityNotification] {
        _ = try requireUser()
        let data = try await send(makeRequest(.GET, path: "rest/v1/notifications", query: [
            URLQueryItem(name: "select", value: "id,kind,actor_id,video_id,body,created_at,is_read"),
            URLQueryItem(name: "order", value: "created_at.desc"), URLQueryItem(name: "limit", value: "100")
        ]))
        return try decode([NotificationRow].self, data).map {
            ActivityNotification(id: $0.id, kind: ActivityKind(rawValue: $0.kind) ?? .system, actorID: $0.actorId,
                                 videoID: $0.videoId, text: $0.body, createdAt: $0.createdAt, isRead: $0.isRead)
        }
    }

    public func markNotificationsRead() async throws {
        _ = try requireUser()
        try await send(makeRequest(.POST, path: "rest/v1/rpc/mark_notifications_read", body: json([:])))
    }
}

final class TaskBox: @unchecked Sendable { var task: URLSessionTask? }

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
