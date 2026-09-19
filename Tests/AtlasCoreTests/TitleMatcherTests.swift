import XCTest
@testable import AtlasCore

/// The rule that decides whether an Archive upload is the film that was asked
/// for. Getting this wrong plays a stranger's video, so the rejections matter
/// more than the matches.
final class TitleMatcherTests: XCTestCase {

    func testNormaliseDropsArticlesCaseAndPunctuation() {
        XCTAssertEqual(TitleMatcher.normalise("The Gold Rush"), "gold rush")
        XCTAssertEqual(TitleMatcher.normalise("A Trip to the Moon"), "trip to moon")
        XCTAssertEqual(TitleMatcher.normalise("His Girl Friday!"), "his girl friday")
        XCTAssertEqual(TitleMatcher.normalise("Dr. Strangelove, or:  How I Learned"),
                       "dr strangelove or how i learned")
    }

    func testNormaliseKeepsArticleLettersInsideWords() {
        // The "a" in "canary" and the "an" in "analyse" are not articles.
        XCTAssertEqual(TitleMatcher.normalise("The Canary Murder Case"), "canary murder case")
        XCTAssertEqual(TitleMatcher.normalise("Ant-Man"), "ant man")
    }

    func testExactAndArticleOnlyDifferencesMatch() {
        XCTAssertTrue(TitleMatcher.matches(wanted: "The Gold Rush", candidate: "Gold Rush"))
        XCTAssertTrue(TitleMatcher.matches(wanted: "his girl friday", candidate: "His Girl Friday"))
    }

    func testSubtitleAndReleaseTagsStillMatch() {
        XCTAssertTrue(TitleMatcher.matches(wanted: "His Girl Friday",
                                           candidate: "His Girl Friday 1940 restored"))
    }

    func testUnrelatedSupersetIsRejected() {
        // The failure this rule exists to prevent: a long fan upload that merely
        // begins with the right words.
        XCTAssertFalse(TitleMatcher.matches(
            wanted: "The Walking Dead",
            candidate: "The Walking Dead parody by some youtuber channel 2019"))
    }

    func testSlackBoundaryIsExact() {
        let wanted = "metropolis"
        let justInside = wanted + String(repeating: "x", count: TitleMatcher.slack)
        let justOutside = wanted + String(repeating: "x", count: TitleMatcher.slack + 1)
        XCTAssertTrue(TitleMatcher.matches(wanted: wanted, candidate: justInside))
        XCTAssertFalse(TitleMatcher.matches(wanted: wanted, candidate: justOutside))
    }

    func testEmptyOrPunctuationOnlyNeverMatches() {
        XCTAssertFalse(TitleMatcher.matches(wanted: "", candidate: "Metropolis"))
        XCTAssertFalse(TitleMatcher.matches(wanted: "Metropolis", candidate: "---"))
        // Two titles that normalise to nothing are not a match either.
        XCTAssertFalse(TitleMatcher.matches(wanted: "the", candidate: "a"))
    }

    func testMatchIsSymmetric() {
        XCTAssertEqual(
            TitleMatcher.matches(wanted: "Nosferatu", candidate: "Nosferatu 1922"),
            TitleMatcher.matches(wanted: "Nosferatu 1922", candidate: "Nosferatu"))
    }
}
