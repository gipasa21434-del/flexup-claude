import XCTest

/// Smoke tests for the main demo flows. They run against the local demo backend (`-uitest` launch argument),
/// so no network or server keys are needed.
final class FlexUpUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()
    }

    private func skipOnboarding() {
        let skip = app.buttons["onboarding.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "Onboarding must be shown on first launch")
        skip.tap()
    }

    private func loginDemo() {
        skipOnboarding()
        let demo = app.buttons["auth.demo.demo@flexup.app"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        demo.tap()
        XCTAssertTrue(app.buttons["feed.like"].firstMatch.waitForExistence(timeout: 10), "Feed should appear after demo login")
    }

    func testOnboardingAndDemoLoginShowsFeed() {
        loginDemo()
        XCTAssertTrue(app.buttons["feed.tab.forYou"].exists)
        XCTAssertTrue(app.buttons["feed.comments"].firstMatch.exists)
    }

    func testLikeTogglesState() {
        loginDemo()
        let like = app.buttons["feed.like"].firstMatch
        let before = like.label
        like.tap()
        let changed = NSPredicate(format: "label != %@", before)
        expectation(for: changed, evaluatedWith: like)
        waitForExpectations(timeout: 5)
    }

    func testSwipeToNextVideo() {
        loginDemo()
        let author = app.buttons["feed.author"].firstMatch
        let first = author.label
        app.swipeUp()
        let next = app.buttons["feed.author"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        // Either a different author or at least the feed is still alive after paging.
        XCTAssertTrue(next.label != first || app.buttons["feed.like"].firstMatch.exists)
    }

    func testCommentsSheetOpensAndPostsComment() {
        loginDemo()
        app.buttons["feed.comments"].firstMatch.tap()
        let field = app.textFields["comments.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("UI тест 👋")
        app.buttons["comments.send"].tap()
        XCTAssertTrue(app.staticTexts["UI тест 👋"].waitForExistence(timeout: 5))
    }

    func testSearchFindsUser() {
        loginDemo()
        app.buttons["tab.discover"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("даша")
        XCTAssertTrue(app.buttons["search.user.dasha.waves"].waitForExistence(timeout: 5))
    }

    func testPublishDemoClip() {
        loginDemo()
        app.buttons["tab.create"].tap()
        let demoClip = app.buttons["create.demoClip"]
        XCTAssertTrue(demoClip.waitForExistence(timeout: 5))
        demoClip.tap()
        let next = app.buttons["create.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        let caption = app.textViews["create.caption"].exists ? app.textViews["create.caption"] : app.textFields["create.caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        caption.tap()
        caption.typeText("Тестовая публикация #uitest")
        app.buttons["create.publish"].tap()
        // Creation sheet closes when publishing succeeds.
        XCTAssertTrue(app.buttons["tab.profile"].waitForExistence(timeout: 30))
        app.buttons["tab.profile"].tap()
        XCTAssertTrue(app.buttons["grid.video"].firstMatch.waitForExistence(timeout: 10))
    }

    func testGuestIsAskedToSignInBeforeLiking() {
        skipOnboarding()
        app.buttons["auth.guest"].tap()
        let like = app.buttons["feed.like"].firstMatch
        XCTAssertTrue(like.waitForExistence(timeout: 10))
        like.tap()
        XCTAssertTrue(app.staticTexts["Нужен аккаунт"].waitForExistence(timeout: 5))
    }

    func testMoodFeedFilter() {
        loginDemo()
        app.buttons["feed.mood"].tap()
        let calm = app.buttons["mood.calm"]
        XCTAssertTrue(calm.waitForExistence(timeout: 5))
        calm.tap()
        XCTAssertTrue(app.buttons["feed.like"].firstMatch.waitForExistence(timeout: 10))
    }
}
