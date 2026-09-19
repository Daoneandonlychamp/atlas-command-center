import Foundation

/// Deciding whether a search hit is the film that was asked for.
///
/// Archive.org has no TMDB ids, so a title can only be found by searching for its
/// name and then judging what comes back. That judgement is the whole reason
/// `ProviderResolutionEngine` could never be pointed at the Archive: the engine
/// substitutes a known id into a template, and there is no id to substitute.
///
/// Ported from `titlesMatch`/`normaliseTitle` in cinema.html so the rule lives in
/// one place and can be tested without a browser.
public struct TitleMatcher: Sendable {

    /// Lowercased, stripped of articles and punctuation, collapsed to single spaces.
    ///
    /// Articles go because the Archive's uploads disagree about them — "The Gold
    /// Rush" and "Gold Rush" are the same film. Punctuation goes because they
    /// disagree about that too, and about case.
    private static let articles: Set<String> = ["the", "a", "an"]

    public static func normalise(_ text: String) -> String {
        // Split on anything that is not a letter or digit, which does the work of
        // both the punctuation strip and the space collapse in one pass. Articles
        // are dropped per word, so the "a" inside "canary" survives.
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !articles.contains(String($0)) }
            .joined(separator: " ")
    }

    /// How much longer a candidate may be than what was asked for.
    ///
    /// Enough to carry a subtitle or a release tag ("1940 restored"), short enough
    /// to reject an unrelated upload that merely starts with the same words.
    public static let slack = 18

    /// Whether `candidate` names the same work as `wanted`.
    public static func matches(wanted: String, candidate: String) -> Bool {
        let a = normalise(wanted)
        let b = normalise(candidate)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }

        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        return longer.hasPrefix(shorter) && longer.count - shorter.count <= slack
    }
}
