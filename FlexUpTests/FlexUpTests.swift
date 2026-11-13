import XCTest
@testable import FlexUp
import FlexCore

@MainActor
final class AppModelTests: XCTestCase {
    private func makeApp() -> AppModel {
        let suite = "flexup.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let backend = DemoBackend(latency: 0, uploadChunkDelay: 0)
        return AppModel(backend: backend, defaults: defaults, isUITesting: true)
    }

    func testBootstrapWithoutSessionShowsOnboardingThenAuth() async {
        let app = makeApp()
        await app.bootstrap()
        XCTAssertEqual(app.phase, .onboarding)
        app.finishOnboarding()
        XCTAssertEqual(app.phase, .auth)
        XCTAssertTrue(app.settings.hasSeenOnboarding)
    }

    func testDemoLoginLoadsCurrentUser() async throws {
        let app = makeApp()
        let s = try await app.backend.signIn(email: "demo@flexup.app", password: DemoContent.demoPassword)
        await app.didAuthenticate(s)
        XCTAssertEqual(app.phase, .main)
        XCTAssertEqual(app.currentUser?.username, "flexer")
        XCTAssertFalse(app.isGuest)
        XCTAssertTrue(app.isDemo)
    }

    func testGuestActionsOpenAuthPrompt() async throws {
        let app = makeApp()
        await app.didAuthenticate(try await app.backend.signInAsGuest())
        var ran = false
        app.requireAccount { ran = true }
        XCTAssertFalse(ran)
        XCTAssertTrue(app.showAuthPrompt)
    }

    func testStreakRecordingUnlocksAchievement() {
        let app = makeApp()
        app.record(.published(challenge: true))
        XCTAssertNotNil(app.streak.unlocked[.firstVideo])
        XCTAssertNotNil(app.streak.unlocked[.firstChallenge])
        XCTAssertEqual(app.currentStreak, 1)
    }

    func testSearchHistoryIsDedupedAndCapped() {
        let app = makeApp()
        for i in 0..<15 { app.remember(query: "q\(i)") }
        app.remember(query: "Q3")
        XCTAssertEqual(app.settings.searchHistory.count, 10)
        XCTAssertEqual(app.settings.searchHistory.first, "Q3")
    }
}

@MainActor
final class FeedViewModelTests: XCTestCase {
    func testLoadLikeAndRemove() async throws {
        let defaults = UserDefaults(suiteName: "flexup.feedtests.\(UUID().uuidString)")!
        let app = AppModel(backend: DemoBackend(latency: 0, uploadChunkDelay: 0), defaults: defaults, isUITesting: true)
        await app.didAuthenticate(try await app.backend.signIn(email: "demo@flexup.app", password: DemoContent.demoPassword))
        let vm = FeedViewModel(source: .main)
        vm.app = app
        await vm.load()
        XCTAssertEqual(vm.state, .loaded)
        XCTAssertEqual(vm.pages.last, .end)
        let first = try XCTUnwrap(vm.activeItem)
        vm.toggleLike(first.id)
        XCTAssertEqual(vm.item(first.id)?.isLiked, true, "optimistic update")
        XCTAssertEqual(vm.item(first.id)?.video.likesCount, first.video.likesCount + 1)
        vm.notInterested(first.id)
        XCTAssertNil(vm.item(first.id))
        XCTAssertGreaterThan(app.players.liveEntriesCount, 0)
        XCTAssertLessThanOrEqual(app.players.liveEntriesCount, 3, "player pool must stay bounded")
    }
}

@MainActor
final class CreateViewModelTests: XCTestCase {
    func testPrefillAndValidation() {
        let ch = Challenge(tag: "flexchallenge", title: "Утро", details: "", emoji: "⚡️", startsAt: .distantPast, endsAt: .distantFuture)
        let vm = CreateViewModel(context: ComposeContext(challenge: ch))
        XCTAssertTrue(vm.caption.hasPrefix("#flexchallenge"))
        XCTAssertFalse(vm.canPublish, "no video selected yet")
        vm.caption = String(repeating: "a", count: Validator.captionLimit + 1)
        XCTAssertNotNil(vm.captionError)
    }

    func testHashtagSuggestions() {
        let vm = CreateViewModel(context: ComposeContext())
        vm.caption = "привет #фл"
        vm.updateTagSuggestions(trending: ["флекс", "flexchallenge", "фломастеры"])
        XCTAssertEqual(vm.tagSuggestions.prefix(2), ["флекс", "фломастеры"])
        vm.applySuggestion("флекс")
        XCTAssertEqual(vm.caption, "привет #флекс ")
    }

    func testDemoClipImportReadsDuration() async {
        let vm = CreateViewModel(context: ComposeContext())
        await vm.useDemoClip()
        XCTAssertEqual(vm.step, .edit)
        XCTAssertGreaterThan(vm.duration, 5)
        XCTAssertEqual(vm.trimEnd, vm.duration, accuracy: 0.01)
    }
}
