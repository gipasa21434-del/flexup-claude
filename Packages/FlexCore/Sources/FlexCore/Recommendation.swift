import Foundation

/// Per-viewer interest signals collected from explicit interactions.
/// Stored locally (demo) or derived server-side; there is no ML model involved.
public struct InterestProfile: Codable, Hashable, Sendable {
    public private(set) var tagAffinity: [String: Double]
    public private(set) var authorAffinity: [UUID: Double]
    public var seenVideoIDs: [UUID: Date]

    public init(tagAffinity: [String: Double] = [:], authorAffinity: [UUID: Double] = [:],
                seenVideoIDs: [UUID: Date] = [:]) {
        self.tagAffinity = tagAffinity; self.authorAffinity = authorAffinity; self.seenVideoIDs = seenVideoIDs
    }

    public enum Signal: Sendable {
        case like, unlike, save, comment, share, watchedFully, skippedQuickly, notInterested

        var weight: Double {
            switch self {
            case .like: return 1.0
            case .unlike: return -1.0
            case .save: return 1.5
            case .comment: return 1.2
            case .share: return 2.0
            case .watchedFully: return 0.5
            case .skippedQuickly: return -0.3
            case .notInterested: return -3.0
            }
        }
    }

    public static let affinityCap = 10.0

    public mutating func record(_ signal: Signal, video: Video, at date: Date = Date()) {
        for tag in video.hashtags {
            tagAffinity[tag] = clamp((tagAffinity[tag] ?? 0) + signal.weight)
        }
        authorAffinity[video.authorID] = clamp((authorAffinity[video.authorID] ?? 0) + signal.weight * 0.5)
        seenVideoIDs[video.id] = date
    }

    public mutating func markSeen(_ id: UUID, at date: Date = Date()) { seenVideoIDs[id] = date }

    /// Multiplies every affinity by `factor` so old interests fade (call e.g. once per day).
    public mutating func decay(factor: Double = 0.9) {
        tagAffinity = tagAffinity.mapValues { $0 * factor }.filter { abs($0.value) > 0.05 }
        authorAffinity = authorAffinity.mapValues { $0 * factor }.filter { abs($0.value) > 0.05 }
    }

    public func affinity(for video: Video) -> Double {
        let tags = video.hashtags.map { tagAffinity[$0] ?? 0 }
        let tagScore = tags.isEmpty ? 0 : tags.reduce(0, +) / Double(tags.count)
        return tagScore + (authorAffinity[video.authorID] ?? 0) * 0.5
    }

    private func clamp(_ v: Double) -> Double { min(Self.affinityCap, max(-Self.affinityCap, v)) }
}

/// Transparent rule-based ranking. It is NOT a trained model:
/// score = follow bonus + interest (tags/author) + mood match + freshness + engagement − already-seen penalty,
/// followed by an author-diversity re-ranking pass.
public struct RecommendationEngine: Sendable {
    public struct Weights: Sendable {
        public var following = 2.0
        public var interest = 0.6
        public var mood = 3.0
        public var freshness = 1.5
        public var engagement = 1.0
        public var seenPenalty = 4.0
        public var freshnessHalfLifeHours = 48.0
        public init() {}
    }

    public struct Context: Sendable {
        public var viewerID: UUID?
        public var following: Set<UUID>
        public var blocked: Set<UUID>
        public var hiddenTags: Set<String>
        public var mood: Mood?
        public var interests: InterestProfile
        public var now: Date

        public init(viewerID: UUID? = nil, following: Set<UUID> = [], blocked: Set<UUID> = [],
                    hiddenTags: Set<String> = [], mood: Mood? = nil,
                    interests: InterestProfile = InterestProfile(), now: Date = Date()) {
            self.viewerID = viewerID; self.following = following; self.blocked = blocked
            self.hiddenTags = hiddenTags; self.mood = mood; self.interests = interests; self.now = now
        }
    }

    public var weights: Weights
    /// The same author may not appear more than once in any window of this size (when alternatives exist).
    public var diversityWindow: Int

    public init(weights: Weights = Weights(), diversityWindow: Int = 3) {
        self.weights = weights; self.diversityWindow = diversityWindow
    }

    /// Filters out content the viewer must not or does not want to see.
    public func isEligible(_ video: Video, context: Context) -> Bool {
        if context.blocked.contains(video.authorID) { return false }
        if !context.hiddenTags.isDisjoint(with: video.hashtags) { return false }
        switch video.visibility {
        case .everyone: break
        case .followers:
            if video.authorID != context.viewerID && !context.following.contains(video.authorID) { return false }
        case .onlyMe:
            if video.authorID != context.viewerID { return false }
        }
        if let mood = context.mood, !video.matches(mood: mood) { return false }
        return true
    }

    public func score(_ video: Video, context: Context) -> Double {
        var s = 0.0
        if context.following.contains(video.authorID) { s += weights.following }
        s += weights.interest * context.interests.affinity(for: video)
        if let mood = context.mood, video.matches(mood: mood) { s += weights.mood }
        let ageHours = max(0, context.now.timeIntervalSince(video.createdAt) / 3600)
        s += weights.freshness * pow(0.5, ageHours / weights.freshnessHalfLifeHours)
        let likes: Double = Double(video.likesCount)
        let comments: Double = 2 * Double(video.commentsCount)
        let saves: Double = 3 * Double(video.savesCount)
        let shares: Double = 3 * Double(video.sharesCount)
        let interactions: Double = likes + comments + saves + shares
        let rate: Double = interactions / Double(max(video.viewsCount, 50))
        let engagement: Double = log1p(interactions) / 10 + min(rate, 1)
        s += weights.engagement * engagement
        if context.interests.seenVideoIDs[video.id] != nil { s -= weights.seenPenalty }
        if video.authorID == context.viewerID { s -= 1 }
        return s
    }

    public func rank(_ videos: [Video], context: Context) -> [Video] {
        // Written as simple loops: long closure chains blow up the type checker on CI.
        var scored: [(video: Video, score: Double)] = []
        for v in videos where isEligible(v, context: context) {
            scored.append((v, score(v, context: context)))
        }
        scored.sort { (a: (video: Video, score: Double), b: (video: Video, score: Double)) -> Bool in
            if a.score == b.score { return a.video.createdAt > b.video.createdAt }
            return a.score > b.score
        }
        let ordered: [Video] = scored.map { $0.video }
        return diversify(ordered)
    }

    public func followingFeed(_ videos: [Video], context: Context) -> [Video] {
        var list: [Video] = []
        for v in videos where context.following.contains(v.authorID) && isEligible(v, context: context) {
            list.append(v)
        }
        list.sort { (a: Video, b: Video) -> Bool in a.createdAt > b.createdAt }
        return list
    }

    /// Greedy re-ranking: picks the best remaining video whose author is not among the last
    /// `diversityWindow - 1` authors; falls back to the best remaining when impossible.
    public func diversify(_ ranked: [Video]) -> [Video] {
        guard diversityWindow > 1 else { return ranked }
        var pool = ranked
        var result: [Video] = []
        while !pool.isEmpty {
            let recent = Set(result.suffix(diversityWindow - 1).map(\.authorID))
            let idx = pool.firstIndex { !recent.contains($0.authorID) } ?? 0
            result.append(pool.remove(at: idx))
        }
        return result
    }
}
