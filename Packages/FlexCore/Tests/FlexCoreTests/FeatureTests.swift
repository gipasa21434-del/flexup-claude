import XCTest
@testable import FlexCore

final class StreakTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }()
    lazy var tracker = StreakTracker(calendar: cal)
    let day0 = Date(timeIntervalSince1970: 1_800_000_000) // fixed reference

    func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: day0)! }

    func completeDay(_ state: inout StreakState, _ offset: Int) {
        for _ in 0..<5 { tracker.record(.watched(nil), in: &state, at: day(offset)) }
    }

    func testDayCompletesWhenAnyGoalIsReached() {
        var s = StreakState()
        for _ in 0..<4 { tracker.record(.watched(nil), in: &s, at: day0) }
        XCTAssertFalse(tracker.isDayComplete(s, on: day0))
        tracker.record(.published(challenge: false), in: &s, at: day0)
        XCTAssertTrue(tracker.isDayComplete(s, on: day0))
        XCTAssertEqual(tracker.progress(.watch, in: s, on: day0), 4)
        XCTAssertEqual(tracker.progress(.publish, in: s, on: day0), 1)
    }

    func testConsecutiveDaysAndTodayNotYetDone() {
        var s = StreakState()
        completeDay(&s, -3); completeDay(&s, -2); completeDay(&s, -1)
        XCTAssertEqual(tracker.currentStreak(s, now: day0), 3, "today is not done yet but streak survives")
        completeDay(&s, 0)
        XCTAssertEqual(tracker.currentStreak(s, now: day0), 4)
    }

    func testGapResetsButOneFreezePerWeekIsForgiven() {
        var s = StreakState()
        completeDay(&s, -2); completeDay(&s, 0) // day -1 missed → freeze
        XCTAssertEqual(tracker.currentStreak(s, now: day0), 2)
        var s2 = StreakState()
        completeDay(&s2, -5); completeDay(&s2, -4); completeDay(&s2, 0) // gap of 3 days
        XCTAssertEqual(tracker.currentStreak(s2, now: day0), 1)
    }

    func testAchievementsUnlockOnce() {
        var s = StreakState()
        let first = tracker.record(.published(challenge: true), in: &s, at: day0)
        XCTAssertEqual(Set(first), [.firstVideo, .firstChallenge])
        XCTAssertTrue(tracker.record(.published(challenge: true), in: &s, at: day0).isEmpty)
        for _ in 0..<49 { tracker.record(.liked, in: &s, at: day0) }
        XCTAssertNil(s.unlocked[.likes50])
        XCTAssertEqual(tracker.record(.liked, in: &s, at: day0), [.likes50])
    }

    func testStreakAchievementsAndExplorer() {
        var s = StreakState()
        completeDay(&s, -2); completeDay(&s, -1)
        XCTAssertNil(s.unlocked[.streak3])
        completeDay(&s, 0)
        XCTAssertNotNil(s.unlocked[.streak3])
        for m in Mood.allCases { tracker.record(.watched(m), in: &s, at: day0) }
        XCTAssertNotNil(s.unlocked[.explorer])
    }

    func testDisabledStreakRecordsNothing() {
        var s = StreakState(isEnabled: false)
        tracker.record(.published(challenge: false), in: &s, at: day0)
        XCTAssertTrue(s.days.isEmpty)
        XCTAssertTrue(s.unlocked.isEmpty)
    }

    func testHistoryLength() {
        var s = StreakState()
        completeDay(&s, 0)
        let h = tracker.history(s, days: 14, now: day0)
        XCTAssertEqual(h.count, 14)
        XCTAssertTrue(h.last!.complete)
        XCTAssertFalse(h.first!.complete)
    }
}

final class ChallengeTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()

    func testScheduleHasExactlyOneActiveChallenge() {
        let engine = ChallengeEngine(calendar: cal)
        let list = engine.dailySchedule(templates: DemoContent.challengeTemplates, around: now)
        XCTAssertEqual(list.count, 7)
        XCTAssertEqual(list.filter { $0.isActive(at: now) }.count, 1)
        XCTAssertNotNil(engine.current(from: list, at: now))
        XCTAssertEqual(engine.upcoming(from: list, at: now).count, 3)
        XCTAssertEqual(engine.past(from: list, at: now).count, 3)
        // Stable ids across calls.
        XCTAssertEqual(list.map(\.id), engine.dailySchedule(templates: DemoContent.challengeTemplates, around: now).map(\.id))
    }

    func testLeaderboardRanksByScoreWithinWindowOnly() {
        let engine = ChallengeEngine(calendar: cal)
        let ch = Challenge(tag: "#Test", title: "t", details: "", emoji: "🏆",
                           startsAt: now.addingTimeInterval(-3600), endsAt: now.addingTimeInterval(3600))
        let author = UUID()
        let low = Video(authorID: author, caption: "#test", source: .bundled("x"), likesCount: 1, createdAt: now)
        let high = Video(authorID: author, caption: "#test", source: .bundled("x"), likesCount: 1, commentsCount: 5, createdAt: now)
        let viaField = Video(authorID: author, caption: "без тега", source: .bundled("x"), likesCount: 3, createdAt: now, challengeTag: "test")
        let tooEarly = Video(authorID: author, caption: "#test", source: .bundled("x"), likesCount: 99, createdAt: now.addingTimeInterval(-7200))
        let hidden = Video(authorID: author, caption: "#test", source: .bundled("x"), likesCount: 99, createdAt: now, visibility: .onlyMe)
        let board = engine.leaderboard(for: ch, videos: [low, tooEarly, high, viaField, hidden])
        XCTAssertEqual(board.map(\.video.id), [high.id, viaField.id, low.id])
        XCTAssertEqual(board.map(\.rank), [1, 2, 3])
        XCTAssertEqual(board.first?.score, 11)
        XCTAssertTrue(engine.leaderboard(for: ch, videos: [high], blocked: [author]).isEmpty)
    }
}

final class SearchTests: XCTestCase {
    let users = DemoContent.users()
    let videos = DemoContent.videos()
    let engine = SearchEngine()

    func testFindsUsersByPrefixAndDisplayName() {
        let r = engine.search("даша", users: users, videos: videos)
        XCTAssertEqual(r.users.first?.username, "dasha.waves")
        XCTAssertEqual(engine.search("@max", users: users, videos: videos).videos.count, 0)
        XCTAssertEqual(engine.search("@max", users: users, videos: videos).users.first?.username, "max.pulse")
    }

    func testHashtagSearchAndYoEquivalence() {
        let r = engine.search("#уют", scope: .all, users: users, videos: videos)
        XCTAssertTrue(r.users.isEmpty)
        XCTAssertFalse(r.videos.isEmpty)
        XCTAssertEqual(r.hashtags.first?.tag, "уют")
        XCTAssertEqual(SearchEngine.matchScore("Ёлка", "елка"), 3)
    }

    func testScopesSortAndMood() {
        let popular = engine.search("#юмор", scope: .videos, sort: .popular, users: users, videos: videos).videos
        XCTAssertEqual(popular.map(\.viewsCount), popular.map(\.viewsCount).sorted(by: >))
        let newest = engine.search("#flexchallenge", scope: .videos, sort: .newest, users: users, videos: videos).videos
        XCTAssertEqual(newest.map(\.createdAt), newest.map(\.createdAt).sorted(by: >))
        let calmOnly = engine.search("природа", scope: .videos, mood: .energetic, users: users, videos: videos)
        XCTAssertTrue(calmOnly.videos.isEmpty)
        XCTAssertTrue(engine.search("   ", users: users, videos: videos).isEmpty)
    }

    func testBlockedAuthorsAreHidden() {
        let dasha = users.first { $0.username == "dasha.waves" }!
        let r = engine.search("#спокойно", users: users, videos: videos, blocked: [dasha.id])
        XCTAssertTrue(r.videos.allSatisfy { $0.authorID != dasha.id })
    }

    func testSuggestions() {
        let empty = engine.suggestions(for: "", history: ["котики"], users: users, videos: videos)
        XCTAssertEqual(empty.first, "котики")
        XCTAssertTrue(empty.contains { $0.hasPrefix("#") })
        let s = engine.suggestions(for: "#flex", history: [], users: users, videos: videos)
        XCTAssertEqual(s, ["#flexchallenge"])
        XCTAssertTrue(engine.suggestions(for: "da", history: [], users: users, videos: videos).contains("@dasha.waves"))
    }
}
