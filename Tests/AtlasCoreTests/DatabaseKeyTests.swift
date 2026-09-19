import XCTest
@testable import AtlasCore

/// The rules that decide whether an encrypted database may be opened.
///
/// These exist because the old code answered "mint a new key" to every failed
/// Keychain lookup, including the ones that meant "the key is right there, you
/// just could not read it" — and minting overwrote the real key, permanently
/// orphaning the database it belonged to.
final class DatabaseKeyTests: XCTestCase {

    private let good = String(repeating: "a", count: 64)

    private func decide(_ read: KeychainManager.ReadResult,
                        databaseExists: Bool) -> DatabaseKey.Decision {
        DatabaseKey.decide(read: read, databaseExists: databaseExists,
                           name: "CRM", fileName: "crm.sqlite")
    }

    // MARK: - The happy path

    func testAValidKeyOpensTheDatabase() {
        XCTAssertEqual(decide(.found(good), databaseExists: true), .open(good))
        XCTAssertEqual(decide(.found(good), databaseExists: false), .open(good))
    }

    func testAFirstRunMintsAKey() {
        XCTAssertEqual(decide(.notFound, databaseExists: false), .mint)
    }

    // MARK: - The rules that prevent data loss

    /// The exact bug. A denied prompt or a locked keychain used to look
    /// identical to "no key", and the response was to mint one over the top.
    func testAnUnreadableKeyRefusesInsteadOfMinting() {
        let decision = decide(.unreadable(errSecAuthFailed), databaseExists: true)
        guard case .refuse(let reason) = decision else {
            return XCTFail("expected a refusal, got \(decision)")
        }
        XCTAssertTrue(reason.contains("left alone"), reason)
    }

    /// Even with no database on disk yet: an unreadable item is still an item,
    /// and replacing it would destroy whatever it protects.
    func testAnUnreadableKeyRefusesEvenWithNoDatabaseYet() {
        guard case .refuse = decide(.unreadable(errSecInteractionNotAllowed),
                                    databaseExists: false) else {
            return XCTFail("an unreadable item must never be overwritten")
        }
    }

    /// A database with no key cannot be opened, and a fresh key would not
    /// decrypt it — so say that rather than silently starting over.
    func testAMissingKeyForAnExistingDatabaseRefusesAndExplains() {
        let decision = decide(.notFound, databaseExists: true)
        guard case .refuse(let reason) = decision else {
            return XCTFail("expected a refusal, got \(decision)")
        }
        XCTAssertTrue(reason.contains("crm.sqlite"), "should name the file to move aside")
        XCTAssertTrue(reason.contains("would not decrypt"), reason)
    }

    func testAKeyOfTheWrongLengthRefusesRatherThanBeingReplaced() {
        for wrong in ["", "deadbeef", String(repeating: "a", count: 63),
                      String(repeating: "a", count: 65)] {
            guard case .refuse = decide(.found(wrong), databaseExists: true) else {
                return XCTFail("a \(wrong.count)-character key should not be silently replaced")
            }
        }
    }

    // MARK: - Minting

    func testAMintedKeyIsSixtyFourHexCharacters() throws {
        let key = try XCTUnwrap(DatabaseKey.mintKey())
        XCTAssertEqual(key.count, DatabaseKey.keyLength)
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertNotEqual(key, DatabaseKey.mintKey(), "two mints must not collide")
    }

    /// A minted key has to survive the round trip through the decision, or the
    /// database gets encrypted with something that cannot be recovered.
    func testAMintedKeyIsAcceptedByTheSameRules() throws {
        let key = try XCTUnwrap(DatabaseKey.mintKey())
        XCTAssertEqual(decide(.found(key), databaseExists: true), .open(key))
    }

    // MARK: - Messages

    func testEveryRefusalNamesTheDatabaseItIsAbout() {
        let reads: [KeychainManager.ReadResult] = [
            .notFound, .unreadable(errSecAuthFailed), .found("short")
        ]
        for read in reads {
            let decision = DatabaseKey.decide(read: read, databaseExists: true,
                                              name: "expenses", fileName: "expenses.sqlite")
            guard case .refuse(let reason) = decision else {
                return XCTFail("expected a refusal for \(read)")
            }
            XCTAssertTrue(reason.contains("expenses"),
                          "a message that does not say which database is not actionable: \(reason)")
        }
    }
}
