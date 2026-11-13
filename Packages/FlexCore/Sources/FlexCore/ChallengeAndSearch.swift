import Foundation

// MARK: - FLEX CHALLENGE

public struct ChallengeEngine: Sendable {
    public struct Entry: Identifiable, Hashable, Sendable {
        public var video: Video
        public var rank: Int
        public var score: Int
        public var id: UUID { video.id }
    }

    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }

    /// Active challenge for `date`, or nil.
    public func current(from challenges: [Challenge], at date: Date = Date()) -> Challenge? {
        challenges.filter { $0.isActive(at: date) }.sorted { $0.startsAt > $1.startsAt }.first
    }

    public func upcoming(from challenges: [Challenge], at date: Date = Date()) -> [Challenge] {
        challenges.filter { $0.startsAt > date }.sorted { $0.startsAt < $1.startsAt }
    }

    public func past(from challenges: [Challenge], at date: Date = Date()) -> [Challenge] {
        challenges.filter { $0.endsAt <= date }.sorted { $0.endsAt > $1.endsAt }
    }

    public func isParticipating(_ video: Video, in challenge: Challenge) -> Bool {
        video.challengeTag == challenge.tag || video.hashtags.contains(challenge.tag)
    }

    /// Score is simple and explainable: likes + 2×comments + 3×shares + saves.
    public static func score(_ v: Video) -> Int { v.likesCount + 2 * v.commentsCount + 3 * v.sharesCount + v.savesCount }

    /// Leaderboard: only public videos created during the challenge window; ties → earlier video wins.
    public func leaderboard(for challenge: Challenge, videos: [Video], blocked: Set<UUID> = []) -> [Entry] {
        videos.filter {
            isParticipating($0, in: challenge) && $0.visibility == .everyone && !blocked.contains($0.authorID)
                && $0.createdAt >= challenge.startsAt && $0.createdAt < challenge.endsAt
        }
        .sorted { a, b in
            let sa = Self.score(a), sb = Self.score(b)
            return sa == sb ? a.createdAt < b.createdAt : sa > sb
        }
        .enumerated()
        .map { Entry(video: $1, rank: $0 + 1, score: Self.score($1)) }
    }

    public func timeRemaining(_ challenge: Challenge, now: Date = Date()) -> TimeInterval {
        max(0, challenge.endsAt.timeIntervalSince(now))
    }

    /// Builds a deterministic schedule of daily challenges (used by demo mode and as server seed).
    public func dailySchedule(templates: [(tag: String, title: String, details: String, emoji: String)],
                              around date: Date, daysBack: Int = 3, daysForward: Int = 3) -> [Challenge] {
        guard !templates.isEmpty else { return [] }
        let today = calendar.startOfDay(for: date)
        let dayIndex = Int(today.timeIntervalSince1970 / 86_400)
        return (-daysBack...daysForward).compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let t = templates[((dayIndex + offset) % templates.count + templates.count) % templates.count]
            // Stable UUID per (tag, day) so local state survives relaunches.
            let id = UUID(uuidString: String(format: "C0000000-0000-4000-8000-%012d", abs(dayIndex + offset))) ?? UUID()
            return Challenge(id: id, tag: t.tag, title: t.title, details: t.details, emoji: t.emoji, startsAt: start, endsAt: end)
        }
    }
}

// MARK: - Search

public enum SearchScope: String, CaseIterable, Sendable, Identifiable {
    case all, users, videos, hashtags
    public var id: String { rawValue }
    public var title: String {
        switch self { case .all: return "Всё"; case .users: return "Люди"; case .videos: return "Видео"; case .hashtags: return "Хештеги" }
    }
}

public enum SearchSort: String, CaseIterable, Sendable, Identifiable {
    case relevance, popular, newest
    public var id: String { rawValue }
    public var title: String {
        switch self { case .relevance: return "По релевантности"; case .popular: return "Популярные"; case .newest: return "Новые" }
    }
}

public struct HashtagSummary: Identifiable, Hashable, Sendable {
    public var tag: String
    public var videoCount: Int
    public var totalViews: Int
    public var id: String { tag }
    public init(tag: String, videoCount: Int, totalViews: Int) {
        self.tag = tag; self.videoCount = videoCount; self.totalViews = totalViews
    }
}

public struct SearchResults: Sendable {
    public var users: [UserProfile] = []
    public var videos: [Video] = []
    public var hashtags: [HashtagSummary] = []
    /// `videos` joined with authors/viewer state (filled by backends to avoid N+1 lookups in the UI).
    public var videoItems: [FeedItem] = []
    public var isEmpty: Bool { users.isEmpty && videos.isEmpty && hashtags.isEmpty }
    public init(users: [UserProfile] = [], videos: [Video] = [], hashtags: [HashtagSummary] = []) {
        self.users = users; self.videos = videos; self.hashtags = hashtags
    }
}

public struct SearchEngine: Sendable {
    public init() {}

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru"))
            .replacingOccurrences(of: "ё", with: "е")
    }

    /// 3 = exact, 2 = prefix, 1 = contains, 0 = no match.
    static func matchScore(_ haystack: String, _ needle: String) -> Int {
        let h = fold(haystack), n = fold(needle)
        guard !n.isEmpty else { return 0 }
        if h == n { return 3 }
        if h.hasPrefix(n) { return 2 }
        return h.contains(n) ? 1 : 0
    }

    public func hashtagIndex(_ videos: [Video]) -> [HashtagSummary] {
        var counts: [String: (Int, Int)] = [:]
        for v in videos where v.visibility == .everyone {
            for t in v.hashtags {
                let c = counts[t] ?? (0, 0)
                counts[t] = (c.0 + 1, c.1 + v.viewsCount)
            }
        }
        return counts.map { HashtagSummary(tag: $0.key, videoCount: $0.value.0, totalViews: $0.value.1) }
            .sorted { $0.totalViews == $1.totalViews ? $0.tag < $1.tag : $0.totalViews > $1.totalViews }
    }

    public func search(_ rawQuery: String, scope: SearchScope = .all, sort: SearchSort = .relevance,
                       mood: Mood? = nil, users: [UserProfile], videos: [Video],
                       blocked: Set<UUID> = []) -> SearchResults {
        var query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let tagOnly = query.hasPrefix("#")
        let userOnly = query.hasPrefix("@")
        if tagOnly || userOnly { query.removeFirst() }
        guard !query.isEmpty else { return SearchResults() }

        var result = SearchResults()
        if (scope == .all || scope == .users) && !tagOnly {
            result.users = rankUsers(users, query: query, blocked: blocked)
        }
        if (scope == .all || scope == .videos) && !userOnly {
            result.videos = rankVideos(videos, query: query, tagOnly: tagOnly, sort: sort, mood: mood, blocked: blocked)
        }
        if (scope == .all || scope == .hashtags) && !userOnly {
            result.hashtags = rankTags(videos, query: query, blocked: blocked)
        }
        return result
    }

    private func rankUsers(_ users: [UserProfile], query: String, blocked: Set<UUID>) -> [UserProfile] {
        var scored: [(UserProfile, Int)] = []
        for u in users where !blocked.contains(u.id) {
            let a: Int = Self.matchScore(u.username, query)
            let b: Int = Self.matchScore(u.displayName, query)
            let best: Int = max(a, b)
            if best > 0 { scored.append((u, best)) }
        }
        scored.sort { (l: (UserProfile, Int), r: (UserProfile, Int)) -> Bool in
            if l.1 == r.1 { return l.0.followersCount > r.0.followersCount }
            return l.1 > r.1
        }
        return scored.map { $0.0 }
    }

    private func rankVideos(_ videos: [Video], query: String, tagOnly: Bool, sort: SearchSort,
                            mood: Mood?, blocked: Set<UUID>) -> [Video] {
        var scored: [(Video, Int)] = []
        for v in videos {
            if v.visibility != .everyone || blocked.contains(v.authorID) { continue }
            if let mood, !v.matches(mood: mood) { continue }
            var tagScore = 0
            for t in v.hashtags { tagScore = max(tagScore, Self.matchScore(t, query)) }
            let captionScore: Int = tagOnly ? 0 : Self.matchScore(v.caption, query)
            let musicScore: Int = tagOnly ? 0 : Self.matchScore(v.musicTitle, query)
            // A hashtag hit ranks slightly above the same-quality caption hit.
            let best: Int = max(tagScore > 0 ? tagScore + 1 : 0, max(captionScore, musicScore))
            if best > 0 { scored.append((v, best)) }
        }
        return sortVideos(scored, by: sort)
    }

    private func rankTags(_ videos: [Video], query: String, blocked: Set<UUID>) -> [HashtagSummary] {
        let index = hashtagIndex(videos.filter { !blocked.contains($0.authorID) })
        var scored: [(HashtagSummary, Int)] = []
        for h in index {
            let sc: Int = Self.matchScore(h.tag, query)
            if sc > 0 { scored.append((h, sc)) }
        }
        scored.sort { (l: (HashtagSummary, Int), r: (HashtagSummary, Int)) -> Bool in
            if l.1 == r.1 { return l.0.totalViews > r.0.totalViews }
            return l.1 > r.1
        }
        return scored.map { $0.0 }
    }

    private func sortVideos(_ scored: [(Video, Int)], by sort: SearchSort) -> [Video] {
        switch sort {
        case .relevance:
            let sorted = scored.sorted { (l: (Video, Int), r: (Video, Int)) -> Bool in
                if l.1 == r.1 { return l.0.likesCount > r.0.likesCount }
                return l.1 > r.1
            }
            return sorted.map { $0.0 }
        case .popular:
            return scored.map(\.0).sorted { $0.viewsCount > $1.viewsCount }
        case .newest:
            return scored.map(\.0).sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// Autocomplete: recent queries first, then matching tags and usernames.
    public func suggestions(for prefix: String, history: [String], users: [UserProfile],
                            videos: [Video], limit: Int = 8) -> [String] {
        let p = prefix.trimmingCharacters(in: .whitespaces)
        var out: [String] = []
        func add(_ s: String) { if !out.contains(s) && out.count < limit { out.append(s) } }
        if p.isEmpty {
            history.prefix(5).forEach(add)
            hashtagIndex(videos).prefix(limit).forEach { add("#" + $0.tag) }
            return out
        }
        let bare = p.trimmingCharacters(in: CharacterSet(charactersIn: "#@"))
        history.filter { Self.matchScore($0, bare) >= 2 }.forEach(add)
        if !p.hasPrefix("@") {
            hashtagIndex(videos).filter { Self.matchScore($0.tag, bare) >= 2 }.forEach { add("#" + $0.tag) }
        }
        if !p.hasPrefix("#") {
            users.filter { Self.matchScore($0.username, bare) >= 2 }.forEach { add("@" + $0.username) }
        }
        return out
    }
}
