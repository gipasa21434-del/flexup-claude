import Foundation

// MARK: - User

public struct UserProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var username: String
    public var displayName: String
    public var bio: String
    /// Hex colours used to draw a generated gradient avatar when there is no photo.
    public var avatarColors: [String]
    public var avatarURL: URL?
    public var followersCount: Int
    public var followingCount: Int
    public var likesCount: Int
    public var postsCount: Int
    public var isPrivate: Bool
    public var isVerified: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), username: String, displayName: String, bio: String = "",
                avatarColors: [String] = ["#8A2BFF", "#19E3D1"], avatarURL: URL? = nil,
                followersCount: Int = 0, followingCount: Int = 0, likesCount: Int = 0, postsCount: Int = 0,
                isPrivate: Bool = false, isVerified: Bool = false, createdAt: Date = Date()) {
        self.id = id; self.username = username; self.displayName = displayName; self.bio = bio
        self.avatarColors = avatarColors; self.avatarURL = avatarURL
        self.followersCount = followersCount; self.followingCount = followingCount
        self.likesCount = likesCount; self.postsCount = postsCount
        self.isPrivate = isPrivate; self.isVerified = isVerified; self.createdAt = createdAt
    }

    public var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? String(username.prefix(1)).uppercased() : letters.uppercased()
    }
}

// MARK: - Mood

public enum Mood: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case funny, calm, energetic, inspiring, cozy

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .funny: return "Смешно"
        case .calm: return "Спокойно"
        case .energetic: return "Энергично"
        case .inspiring: return "Вдохновляет"
        case .cozy: return "Уютно"
        }
    }

    public var emoji: String {
        switch self {
        case .funny: return "😂"
        case .calm: return "🌊"
        case .energetic: return "⚡️"
        case .inspiring: return "✨"
        case .cozy: return "☕️"
        }
    }

    /// Tags that also count as this mood when a video has no explicit mood.
    /// This is a hand-written dictionary, NOT a machine-learning classifier.
    public var relatedTags: Set<String> {
        switch self {
        case .funny: return ["юмор", "смешно", "прикол", "мем", "funny", "comedy", "лол"]
        case .calm: return ["спокойно", "релакс", "медитация", "природа", "asmr", "calm", "lofi"]
        case .energetic: return ["энергия", "спорт", "танцы", "драйв", "dance", "workout", "трен"]
        case .inspiring: return ["мотивация", "вдохновение", "искусство", "art", "цели", "космос"]
        case .cozy: return ["уют", "кофе", "дом", "осень", "готовка", "книги", "cozy"]
        }
    }
}

// MARK: - Video

public enum VideoVisibility: String, Codable, CaseIterable, Hashable, Sendable {
    case everyone, followers, onlyMe

    public var title: String {
        switch self {
        case .everyone: return "Все"
        case .followers: return "Подписчики"
        case .onlyMe: return "Только я"
        }
    }
}

public enum VideoSource: Codable, Hashable, Sendable {
    /// A file shipped inside the app bundle (demo content). Name without extension, `.mp4` assumed.
    case bundled(String)
    /// A file stored on this device (demo-mode publications).
    case local(String)
    /// Progressive MP4 or HLS (.m3u8) URL served by the backend/CDN.
    case remote(URL)

    public var isHLS: Bool {
        if case let .remote(url) = self { return url.pathExtension.lowercased() == "m3u8" }
        return false
    }
}

public struct Video: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var authorID: UUID
    public var caption: String
    public var hashtags: [String]
    public var musicTitle: String
    public var mood: Mood?
    public var duration: Double
    public var source: VideoSource
    public var thumbnail: VideoSource?
    public var likesCount: Int
    public var commentsCount: Int
    public var savesCount: Int
    public var sharesCount: Int
    public var viewsCount: Int
    public var createdAt: Date
    public var visibility: VideoVisibility
    public var challengeTag: String?
    /// DUO REACT: id of the video this one reacts to.
    public var replyToVideoID: UUID?
    public var isDemo: Bool

    public init(id: UUID = UUID(), authorID: UUID, caption: String, hashtags: [String]? = nil,
                musicTitle: String = "Оригинальный звук", mood: Mood? = nil, duration: Double = 8,
                source: VideoSource, thumbnail: VideoSource? = nil,
                likesCount: Int = 0, commentsCount: Int = 0, savesCount: Int = 0, sharesCount: Int = 0,
                viewsCount: Int = 0, createdAt: Date = Date(), visibility: VideoVisibility = .everyone,
                challengeTag: String? = nil, replyToVideoID: UUID? = nil, isDemo: Bool = false) {
        self.id = id; self.authorID = authorID; self.caption = caption
        self.hashtags = hashtags ?? HashtagParser.extract(from: caption)
        self.musicTitle = musicTitle; self.mood = mood; self.duration = duration
        self.source = source; self.thumbnail = thumbnail
        self.likesCount = likesCount; self.commentsCount = commentsCount; self.savesCount = savesCount
        self.sharesCount = sharesCount; self.viewsCount = viewsCount; self.createdAt = createdAt
        self.visibility = visibility; self.challengeTag = challengeTag; self.replyToVideoID = replyToVideoID
        self.isDemo = isDemo
    }

    /// Mood used by MOOD FEED: explicit mood or a tag-dictionary match.
    public func matches(mood target: Mood) -> Bool {
        if let mood { return mood == target }
        return !target.relatedTags.isDisjoint(with: Set(hashtags))
    }
}

// MARK: - Comments

public struct Comment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var videoID: UUID
    public var authorID: UUID
    public var text: String
    public var createdAt: Date
    public var likesCount: Int

    public init(id: UUID = UUID(), videoID: UUID, authorID: UUID, text: String,
                createdAt: Date = Date(), likesCount: Int = 0) {
        self.id = id; self.videoID = videoID; self.authorID = authorID
        self.text = text; self.createdAt = createdAt; self.likesCount = likesCount
    }
}

// MARK: - Challenges

public struct Challenge: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var tag: String
    public var title: String
    public var details: String
    public var emoji: String
    public var startsAt: Date
    public var endsAt: Date

    public init(id: UUID = UUID(), tag: String, title: String, details: String, emoji: String,
                startsAt: Date, endsAt: Date) {
        self.id = id; self.tag = HashtagParser.normalize(tag); self.title = title; self.details = details
        self.emoji = emoji; self.startsAt = startsAt; self.endsAt = endsAt
    }

    public func isActive(at date: Date) -> Bool { date >= startsAt && date < endsAt }
}

// MARK: - Notifications

public enum ActivityKind: String, Codable, CaseIterable, Hashable, Sendable {
    case like, comment, follow, mention, challenge, react, system
}

public struct ActivityNotification: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: ActivityKind
    public var actorID: UUID?
    public var videoID: UUID?
    public var text: String
    public var createdAt: Date
    public var isRead: Bool

    public init(id: UUID = UUID(), kind: ActivityKind, actorID: UUID? = nil, videoID: UUID? = nil,
                text: String, createdAt: Date = Date(), isRead: Bool = false) {
        self.id = id; self.kind = kind; self.actorID = actorID; self.videoID = videoID
        self.text = text; self.createdAt = createdAt; self.isRead = isRead
    }
}

// MARK: - Moderation

public enum ReportReason: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case spam, harassment, violence, nudity, hate, misinformation, copyright, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .spam: return "Спам или мошенничество"
        case .harassment: return "Травля или оскорбления"
        case .violence: return "Насилие или опасные действия"
        case .nudity: return "Откровенный контент"
        case .hate: return "Язык вражды"
        case .misinformation: return "Ложная информация"
        case .copyright: return "Нарушение авторских прав"
        case .other: return "Другое"
        }
    }
}

public enum ReportTarget: Codable, Hashable, Sendable {
    case video(UUID), comment(UUID), user(UUID)
}

public struct Report: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var target: ReportTarget
    public var reason: ReportReason
    public var details: String
    public var createdAt: Date

    public init(id: UUID = UUID(), target: ReportTarget, reason: ReportReason, details: String = "",
                createdAt: Date = Date()) {
        self.id = id; self.target = target; self.reason = reason; self.details = details; self.createdAt = createdAt
    }
}

// MARK: - Feed

public enum FeedKind: String, Codable, CaseIterable, Hashable, Sendable {
    case forYou, following
    public var title: String { self == .forYou ? "Для тебя" : "Подписки" }
}

/// Everything the feed screen needs for one video, already joined with the author and viewer state.
public struct FeedItem: Identifiable, Hashable, Sendable {
    public var video: Video
    public var author: UserProfile
    public var isLiked: Bool
    public var isSaved: Bool
    public var isFollowingAuthor: Bool
    public var id: UUID { video.id }

    public init(video: Video, author: UserProfile, isLiked: Bool = false, isSaved: Bool = false,
                isFollowingAuthor: Bool = false) {
        self.video = video; self.author = author; self.isLiked = isLiked
        self.isSaved = isSaved; self.isFollowingAuthor = isFollowingAuthor
    }
}
