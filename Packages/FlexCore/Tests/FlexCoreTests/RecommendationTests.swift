import XCTest
@testable import FlexCore

final class RecommendationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let a = UUID(), b = UUID(), c = UUID(), viewer = UUID()

    func video(_ author: UUID, _ caption: String, hoursAgo: Double = 1, likes: Int = 0, mood: Mood? = nil,
               visibility: VideoVisibility = .everyone) -> Video {
        Video(authorID: author, caption: caption, mood: mood, source: .bundled("x"), likesCount: likes,
              viewsCount: 100, createdAt: now.addingTimeInterval(-hoursAgo * 3600), visibility: visibility)
    }

    func testFollowedAuthorsRankHigher() {
        let engine = RecommendationEngine(diversityWindow: 1)
        let v1 = video(a, "#x"), v2 = video(b, "#x")
        let ctx = RecommendationEngine.Context(viewerID: viewer, following: [b], now: now)
        XCTAssertEqual(engine.rank([v1, v2], context: ctx).first?.id, v2.id)
    }

    func testFresherBeatsOlderAllElseEqual() {
        let engine = RecommendationEngine(diversityWindow: 1)
        let old = video(a, "#x", hoursAgo: 200), fresh = video(b, "#x", hoursAgo: 1)
        XCTAssertEqual(engine.rank([old, fresh], context: .init(now: now)).first?.id, fresh.id)
    }

    func testInterestsFromLikesBoostTags() {
        var interests = InterestProfile()
        let liked = video(c, "#котики")
        interests.record(.like, video: liked)
        interests.record(.like, video: liked)
        let engine = RecommendationEngine(diversityWindow: 1)
        let cats = video(a, "#котики"), other = video(b, "#авто")
        let ranked = engine.rank([other, cats], context: .init(interests: interests, now: now))
        XCTAssertEqual(ranked.first?.id, cats.id)
        XCTAssertGreaterThan(interests.tagAffinity["котики"] ?? 0, 0)
    }

    func testSeenVideosArePushedDown() {
        let engine = RecommendationEngine(diversityWindow: 1)
        let v1 = video(a, "#x", likes: 1000), v2 = video(b, "#x")
        var interests = InterestProfile()
        interests.markSeen(v1.id)
        XCTAssertEqual(engine.rank([v1, v2], context: .init(interests: interests, now: now)).first?.id, v2.id)
    }

    func testBlockedHiddenAndPrivateAreFiltered() {
        let engine = RecommendationEngine()
        let blocked = video(a, "#ok"), hidden = video(b, "#spoiler"), priv = video(c, "#ok", visibility: .onlyMe),
            followersOnly = video(c, "#ok", visibility: .followers), fine = video(b, "#ok")
        let ctx = RecommendationEngine.Context(viewerID: viewer, blocked: [a], hiddenTags: ["spoiler"], now: now)
        let ids = engine.rank([blocked, hidden, priv, followersOnly, fine], context: ctx).map(\.id)
        XCTAssertEqual(ids, [fine.id])
        var ctx2 = ctx; ctx2.following = [c]
        XCTAssertTrue(engine.rank([followersOnly], context: ctx2).map(\.id).contains(followersOnly.id))
    }

    func testMoodFilterUsesExplicitMoodOrTagDictionary() {
        let engine = RecommendationEngine()
        let explicit = video(a, "#что-то", mood: .calm)
        let byTag = video(b, "#релакс #вечер")
        let wrong = video(c, "#спорт", mood: .energetic)
        let ids = Set(engine.rank([explicit, byTag, wrong], context: .init(mood: .calm, now: now)).map(\.id))
        XCTAssertEqual(ids, [explicit.id, byTag.id])
    }

    func testDiversityAvoidsSameAuthorBackToBack() {
        let engine = RecommendationEngine(diversityWindow: 2)
        let a1 = video(a, "#x", likes: 900), a2 = video(a, "#x", likes: 800), b1 = video(b, "#x", likes: 1)
        let ranked = engine.rank([a1, a2, b1], context: .init(now: now)).map(\.authorID)
        XCTAssertEqual(ranked, [a, b, a])
    }

    func testDiversityFallsBackWhenOnlyOneAuthor() {
        let engine = RecommendationEngine(diversityWindow: 3)
        let list = [video(a, "#1"), video(a, "#2"), video(a, "#3")]
        XCTAssertEqual(engine.diversify(list).count, 3)
    }

    func testFollowingFeedIsChronological() {
        let engine = RecommendationEngine()
        let old = video(a, "#x", hoursAgo: 10), new = video(a, "#y", hoursAgo: 1), stranger = video(b, "#z")
        let ctx = RecommendationEngine.Context(viewerID: viewer, following: [a], now: now)
        XCTAssertEqual(engine.followingFeed([old, stranger, new], context: ctx).map(\.id), [new.id, old.id])
    }

    func testAffinityIsCappedAndDecays() {
        var p = InterestProfile()
        let v = video(a, "#x")
        for _ in 0..<50 { p.record(.share, video: v) }
        XCTAssertEqual(p.tagAffinity["x"], InterestProfile.affinityCap)
        p.decay(factor: 0.5)
        XCTAssertEqual(p.tagAffinity["x"], InterestProfile.affinityCap / 2)
    }
}
