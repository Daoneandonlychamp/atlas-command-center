import XCTest
@testable import AtlasCore

/// Money in, money out — the conversion every entry path shares.
final class MoneyTests: XCTestCase {

    /// The reason this is not a `Double`: 21.28 is not representable in binary
    /// floating point, and `Int(21.28 * 100)` truncates to 2127.
    func testCentsSurviveTheConversion() {
        XCTAssertEqual(Money.minorUnits("21.28"), 2128)
        XCTAssertEqual(Money.minorUnits("106.60"), 10660)
        XCTAssertEqual(Money.minorUnits("0.07"), 7)
        XCTAssertEqual(Money.minorUnits("29.59"), 2959)
    }

    func testWholeNumbersAndSingleDecimalsWork() {
        XCTAssertEqual(Money.minorUnits("20"), 2000)
        XCTAssertEqual(Money.minorUnits("0"), 0)
        XCTAssertEqual(Money.minorUnits("5.5"), 550)
    }

    func testCurrencySymbolsAndSeparatorsAreTolerated() {
        XCTAssertEqual(Money.minorUnits("$21.28"), 2128)
        XCTAssertEqual(Money.minorUnits(" $1,250.50 "), 125050)
        XCTAssertEqual(Money.minorUnits("1,000"), 100000)
    }

    func testNegativesParseForRefunds() {
        XCTAssertEqual(Money.minorUnits("-12.50"), -1250)
    }

    /// Junk has to come back nil rather than zero. A silent zero enters the
    /// database as a real charge of nothing and quietly wrongs the total.
    func testNonsenseIsRejectedRatherThanZeroed() {
        for junk in ["", "   ", "abc", "$", "12.345", "1.2.3", "12abc", "--5", "1 000"] {
            XCTAssertNil(Money.minorUnits(junk), "\(junk) should not parse")
        }
    }

    func testFormattingIsTheInverse() {
        for minor in [0, 7, 550, 2128, 10660, 125050] {
            XCTAssertEqual(Money.minorUnits(Money.format(minor)), minor)
        }
    }
}
