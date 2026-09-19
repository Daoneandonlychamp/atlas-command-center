import Foundation

/// Amounts as whole minor units.
///
/// Everything that stores money in ATLAS keeps cents as `Int`, so anything that
/// accepts money as text has to convert once, correctly, in one place.
public enum Money {

    /// "21.28" -> 2128, "$1,250" -> 125000.
    ///
    /// Parsed as text, never through `Double`: 21.28 has no exact binary
    /// representation, so `Int(21.28 * 100)` is 2127 and the cent is gone.
    /// A cent lost per row is a total nobody can reconcile.
    public static func minorUnits(_ text: String) -> Int? {
        let cleaned = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }

        let negative = cleaned.hasPrefix("-")
        let digits = negative ? String(cleaned.dropFirst()) : cleaned

        let parts = digits.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = Int(parts[0]), parts[0].allSatisfy(\.isNumber) else { return nil }

        var minor = whole * 100
        if parts.count == 2 {
            let fraction = String(parts[1])
            // Two decimal places is the whole grammar. Three means the number
            // came from somewhere else and guessing at it would be wrong.
            guard (1...2).contains(fraction.count), fraction.allSatisfy(\.isNumber),
                  let cents = Int(fraction.padding(toLength: 2, withPad: "0", startingAt: 0))
            else { return nil }
            minor += cents
        }
        return negative ? -minor : minor
    }

    /// 2128 -> "$21.28".
    public static func format(_ minorUnits: Int) -> String {
        String(format: "$%.2f", Double(minorUnits) / 100)
    }
}
