import XCTest
@testable import FlexCore

final class HashtagParserTests: XCTestCase {
    func testExtractsCyrillicAndLatinTagsInOrderWithoutDuplicates() {
        XCTAssertEqual(HashtagParser.extract(from: "Утро #Энергия и #dance_2026! #энергия #ok"),
                       ["энергия", "dance_2026", "ok"])
    }

    func testIgnoresBareHashAndPunctuation() {
        XCTAssertEqual(HashtagParser.extract(from: "# пусто ## #, #a.b"), ["a"])
    }

    func testLimitsNumberOfTags() {
        let text = (1...20).map { "#t\($0)" }.joined(separator: " ")
        XCTAssertEqual(HashtagParser.extract(from: text).count, HashtagParser.maxTagsPerVideo)
    }

    func testNormalize() {
        XCTAssertEqual(HashtagParser.normalize("  ##FlexChallenge "), "flexchallenge")
    }

    func testTrailingPartialTag() {
        XCTAssertEqual(HashtagParser.trailingPartialTag(in: "привет #тре"), "тре")
        XCTAssertNil(HashtagParser.trailingPartialTag(in: "привет #тренд мир"))
        XCTAssertEqual(HashtagParser.trailingPartialTag(in: "#"), "")
    }
}

final class ValidatorTests: XCTestCase {
    func testEmail() {
        XCTAssertNil(Validator.email("demo@flexup.app"))
        XCTAssertEqual(Validator.email(""), .emptyEmail)
        for bad in ["a@b", "@b.c", "a b@c.d", "a@.c", "a@b.", "a@@b.c", "a@b..c"] {
            XCTAssertEqual(Validator.email(bad), .invalidEmail, bad)
        }
    }

    func testPassword() {
        XCTAssertEqual(Validator.password("short1"), .shortPassword)
        XCTAssertEqual(Validator.password("onlyletters"), .weakPassword)
        XCTAssertEqual(Validator.password("12345678"), .weakPassword)
        XCTAssertNil(Validator.password("flexup2026"))
        XCTAssertEqual(Validator.passwordConfirmation("a", "b"), .passwordsDoNotMatch)
    }

    func testUsername() {
        XCTAssertNil(Validator.username("max.pulse"))
        XCTAssertEqual(Validator.username("ab"), .usernameLength)
        XCTAssertEqual(Validator.username("макс"), .usernameCharacters)
        XCTAssertEqual(Validator.username(".max"), .usernameCharacters)
        XCTAssertEqual(Validator.username("Admin"), .usernameReserved)
    }

    func testTextLimits() {
        XCTAssertEqual(Validator.text("   ", limit: 10), .emptyText)
        XCTAssertNil(Validator.text("", limit: 10, allowEmpty: true))
        XCTAssertEqual(Validator.text(String(repeating: "a", count: 11), limit: 10), .textTooLong(limit: 10))
        XCTAssertNotNil(ValidationError.textTooLong(limit: 10).errorDescription)
    }
}

final class FormattingTests: XCTestCase {
    func testShortCounts() {
        XCTAssertEqual(CountFormatter.short(950), "950")
        XCTAssertEqual(CountFormatter.short(1_000), "1 тыс.")
        XCTAssertEqual(CountFormatter.short(1_250), "1,2 тыс.")
        XCTAssertEqual(CountFormatter.short(3_400_000), "3,4 млн")
        XCTAssertEqual(CountFormatter.short(2_000_000_000), "2 млрд")
    }

    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-30), now: now), "сейчас")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-300), now: now), "5 мин")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-7200), now: now), "2 ч")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-86_400 * 3), now: now), "3 д")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-86_400 * 15), now: now), "2 нед")
    }
}
