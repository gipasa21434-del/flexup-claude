import Foundation

public enum BackendMode: String, Sendable {
    /// Local, in-memory/on-device data. Nothing leaves the phone. Clearly labelled «ДЕМО» in the UI.
    case demo
    /// Real Supabase project (Auth + Postgres + Storage) configured via xcconfig / Info.plist.
    case supabase
}

public enum BackendError: Error, Equatable, LocalizedError, Sendable {
    case offline
    case timeout
    case unauthorized
    case invalidCredentials
    case emailConfirmationRequired
    case accountRequired
    case notFound
    case forbidden
    case rateLimited(retryAfter: Int)
    case validation(ValidationError)
    case conflict(String)
    case server(String)
    case cancelled
    case notConfigured(String)

    public var errorDescription: String? {
        switch self {
        case .offline: return "Нет подключения к интернету. Проверь сеть и попробуй ещё раз."
        case .timeout: return "Сервер долго не отвечает. Попробуй ещё раз."
        case .unauthorized: return "Сессия истекла — войди снова."
        case .invalidCredentials: return "Неверный email или пароль."
        case .emailConfirmationRequired: return "Мы отправили письмо — подтверди email и войди."
        case .accountRequired: return "Чтобы это сделать, войди или зарегистрируйся."
        case .notFound: return "Не найдено или удалено."
        case .forbidden: return "Нет доступа."
        case let .rateLimited(s): return "Слишком часто. Подожди \(s) с."
        case let .validation(v): return v.errorDescription
        case let .conflict(m): return m
        case let .server(m): return "Ошибка сервера: \(m)"
        case .cancelled: return "Отменено."
        case let .notConfigured(m): return m
        }
    }
}

public struct AuthSession: Codable, Hashable, Sendable {
    public var userID: UUID
    public var email: String?
    public var accessToken: String?
    public var refreshToken: String?
    public var expiresAt: Date?
    public var isGuest: Bool

    public init(userID: UUID, email: String?, accessToken: String? = nil, refreshToken: String? = nil,
                expiresAt: Date? = nil, isGuest: Bool = false) {
        self.userID = userID; self.email = email; self.accessToken = accessToken
        self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.isGuest = isGuest
    }
}

public struct CommentItem: Identifiable, Hashable, Sendable {
    public var comment: Comment
    public var author: UserProfile
    public var isMine: Bool
    public var id: UUID { comment.id }
    public init(comment: Comment, author: UserProfile, isMine: Bool) {
        self.comment = comment; self.author = author; self.isMine = isMine
    }
}

public struct LeaderboardEntry: Identifiable, Hashable, Sendable {
    public var rank: Int
    public var score: Int
    public var item: FeedItem
    public var id: UUID { item.id }
    public init(rank: Int, score: Int, item: FeedItem) { self.rank = rank; self.score = score; self.item = item }
}

public struct FeedQuery: Sendable {
    public var kind: FeedKind
    public var mood: Mood?
    public var hiddenTags: Set<String>
    public var interests: InterestProfile
    public var limit: Int
    public init(kind: FeedKind = .forYou, mood: Mood? = nil, hiddenTags: Set<String> = [],
                interests: InterestProfile = InterestProfile(), limit: Int = 30) {
        self.kind = kind; self.mood = mood; self.hiddenTags = hiddenTags; self.interests = interests; self.limit = limit
    }
}

public struct PublishRequest: Sendable {
    public var fileURL: URL
    public var coverJPEG: Data?
    public var caption: String
    public var mood: Mood?
    public var visibility: VideoVisibility
    public var challengeTag: String?
    public var replyToVideoID: UUID?
    public var duration: Double
    public var musicTitle: String

    public init(fileURL: URL, coverJPEG: Data?, caption: String, mood: Mood?, visibility: VideoVisibility,
                challengeTag: String?, replyToVideoID: UUID?, duration: Double, musicTitle: String = "Оригинальный звук") {
        self.fileURL = fileURL; self.coverJPEG = coverJPEG; self.caption = caption; self.mood = mood
        self.visibility = visibility; self.challengeTag = challengeTag; self.replyToVideoID = replyToVideoID
        self.duration = duration; self.musicTitle = musicTitle
    }
}

public struct ProfileUpdate: Sendable {
    public var displayName: String
    public var username: String
    public var bio: String
    public var isPrivate: Bool
    public var avatarJPEG: Data?
    public init(displayName: String, username: String, bio: String, isPrivate: Bool, avatarJPEG: Data? = nil) {
        self.displayName = displayName; self.username = username; self.bio = bio
        self.isPrivate = isPrivate; self.avatarJPEG = avatarJPEG
    }
}

/// Everything the app needs from a backend. `DemoBackend` and `SupabaseBackend` implement it.
public protocol FlexBackend: AnyObject, Sendable {
    var mode: BackendMode { get }

    // Auth
    func restoreSession() async -> AuthSession?
    func signUp(email: String, password: String, username: String) async throws -> AuthSession
    func signIn(email: String, password: String) async throws -> AuthSession
    func signInAsGuest() async throws -> AuthSession
    func sendPasswordReset(email: String) async throws
    func signOut() async
    func deleteAccount() async throws

    // Profiles
    func profile(id: UUID) async throws -> UserProfile
    func updateProfile(_ update: ProfileUpdate) async throws -> UserProfile
    func isUsernameAvailable(_ username: String) async throws -> Bool
    func setFollow(_ follow: Bool, userID: UUID) async throws -> UserProfile
    func isFollowing(userID: UUID) async throws -> Bool

    // Videos
    func feed(_ query: FeedQuery) async throws -> [FeedItem]
    func videos(by authorID: UUID) async throws -> [FeedItem]
    func savedVideos() async throws -> [FeedItem]
    func likedVideos() async throws -> [FeedItem]
    func videos(withTag tag: String, sort: SearchSort) async throws -> [FeedItem]
    func reactions(to videoID: UUID) async throws -> [FeedItem]
    func feedItem(videoID: UUID) async throws -> FeedItem
    func setLike(_ like: Bool, videoID: UUID) async throws -> Video
    func setSave(_ save: Bool, videoID: UUID) async throws -> Video
    func recordShare(videoID: UUID) async
    func recordView(videoID: UUID) async
    func publish(_ request: PublishRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> Video
    func deleteVideo(id: UUID) async throws

    // Comments
    func comments(videoID: UUID) async throws -> [CommentItem]
    func addComment(videoID: UUID, text: String) async throws -> CommentItem
    func deleteComment(id: UUID) async throws

    // Discovery
    func search(_ query: String, scope: SearchScope, sort: SearchSort, mood: Mood?) async throws -> SearchResults
    func suggestions(prefix: String, history: [String]) async -> [String]
    func trendingHashtags() async throws -> [HashtagSummary]
    func challenges() async throws -> [Challenge]
    func leaderboard(for challenge: Challenge) async throws -> [LeaderboardEntry]

    // Safety
    func report(_ report: Report) async throws
    func setBlocked(_ blocked: Bool, userID: UUID) async throws
    func blockedUsers() async throws -> [UserProfile]

    // Activity
    func notifications() async throws -> [ActivityNotification]
    func markNotificationsRead() async throws
}

/// Persists the auth session (Keychain on iOS, memory in tests).
public protocol SessionStore: Sendable {
    func load() -> AuthSession?
    func save(_ session: AuthSession?)
}

public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private var value: AuthSession?
    private let lock = NSLock()
    public init(_ value: AuthSession? = nil) { self.value = value }
    public func load() -> AuthSession? { lock.lock(); defer { lock.unlock() }; return value }
    public func save(_ session: AuthSession?) { lock.lock(); value = session; lock.unlock() }
}

// MARK: - Rate limiting (client side, mirrors server triggers)

/// Sliding-window limiter. The authoritative limit lives in Postgres triggers (see supabase/migrations);
/// this one gives instant feedback and protects demo mode from spam taps.
public struct RateLimiter: Sendable {
    public struct Rule: Sendable {
        public var limit: Int
        public var window: TimeInterval
        public init(limit: Int, window: TimeInterval) { self.limit = limit; self.window = window }
    }

    public var rules: [String: Rule]
    private var hits: [String: [Date]] = [:]

    public init(rules: [String: Rule]) { self.rules = rules }

    public static let `default` = RateLimiter(rules: [
        "comment": Rule(limit: 10, window: 60),
        "publish": Rule(limit: 10, window: 3600),
        "report": Rule(limit: 20, window: 3600),
        "follow": Rule(limit: 60, window: 60),
        "like": Rule(limit: 120, window: 60)
    ])

    /// Records the hit if allowed; otherwise throws `.rateLimited` with seconds to wait.
    public mutating func hit(_ action: String, now: Date = Date()) throws {
        guard let rule = rules[action] else { return }
        var list = (hits[action] ?? []).filter { now.timeIntervalSince($0) < rule.window }
        if list.count >= rule.limit, let oldest = list.first {
            hits[action] = list
            let wait = Int((rule.window - now.timeIntervalSince(oldest)).rounded(.up))
            throw BackendError.rateLimited(retryAfter: max(1, wait))
        }
        list.append(now)
        hits[action] = list
    }
}
