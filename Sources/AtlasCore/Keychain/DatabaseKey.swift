import Foundation
import Security

/// Decides whether a SQLCipher database may be opened, and mints its key the
/// one time that is safe.
///
/// Every encrypted store in ATLAS faces the same question at startup: the
/// Keychain lookup did not hand back a usable key — is that because there has
/// never been one, or because this process could not read the one that exists?
/// Answering "mint a new one" to the second case destroys the only key the
/// database has. That is not hypothetical; it is what orphaned two databases
/// here, so the rule lives in one place with tests rather than in three copies.
public enum DatabaseKey {

    /// What to do about a database, given what the Keychain said.
    public enum Decision: Equatable {
        /// Open with this key.
        case open(String)
        /// No key and no database: mint one.
        case mint
        /// Do not open, and do not write a key. The text explains why.
        case refuse(String)
    }

    /// Length of a raw 256-bit SQLCipher key in hex.
    static let keyLength = 64

    /// The pure decision. No Keychain, no filesystem — both are passed in, so
    /// every branch can be tested.
    ///
    /// - Parameters:
    ///   - read: what the Keychain lookup returned.
    ///   - databaseExists: whether the database file is already on disk.
    ///   - name: how to refer to the database in a message ("CRM", "expenses").
    ///   - fileName: the file to name when suggesting the person move it aside.
    public static func decide(read: KeychainManager.ReadResult,
                              databaseExists: Bool,
                              name: String,
                              fileName: String) -> Decision {
        switch read {
        case .found(let key) where key.count == keyLength:
            return .open(key)

        case .found:
            // Present but the wrong shape. Overwriting it would orphan the
            // database, so stop and let a person look.
            return .refuse("The \(name) encryption key in the Keychain is malformed. "
                           + "The database has not been touched.")

        case .unreadable(let status):
            // The item is there; this process could not read it — a denied
            // prompt, a locked keychain, a changed code signature after a
            // rebuild. Minting here would replace the real key and lock the
            // database away for good.
            return .refuse("ATLAS could not read the \(name) encryption key from the Keychain "
                           + "(status \(status)). The database was left alone. "
                           + "Grant access when macOS asks, then reopen this page.")

        case .notFound:
            // Genuinely absent. Minting is only safe when there is no database
            // that an older key belonged to.
            guard !databaseExists else {
                return .refuse("The \(name) database exists but its Keychain key is gone, so it "
                               + "cannot be opened. A new key would not decrypt it. "
                               + "Restore the Keychain item, or move \(fileName) aside "
                               + "to start fresh.")
            }
            return .mint
        }
    }

    /// Resolves the key for a store, minting only when that is safe.
    ///
    /// Returns nil on refusal, with the reason written to `failure`.
    public static func resolve(account: String,
                               databaseURL: URL,
                               name: String,
                               failure: inout String?,
                               keychain: KeychainManager = .shared) -> String? {
        let exists = FileManager.default.fileExists(atPath: databaseURL.path)
        switch decide(read: keychain.read(key: account),
                      databaseExists: exists,
                      name: name,
                      fileName: databaseURL.lastPathComponent) {
        case .open(let key):
            return key

        case .refuse(let reason):
            failure = reason
            return nil

        case .mint:
            guard let key = mintKey() else {
                failure = "Could not generate an encryption key for the \(name) database."
                return nil
            }
            // create, not save: if an item appeared between the read and now,
            // this fails rather than overwriting it.
            guard keychain.create(key: account, value: key) else {
                // Storing failed, so using the key would encrypt a database
                // nobody could ever open again.
                failure = "Could not store the \(name) encryption key in the Keychain. "
                    + "The database was not created."
                return nil
            }
            return key
        }
    }

    /// What to say when the key is well-formed but does not decrypt the file.
    ///
    /// This is unrecoverable by design — SQLCipher has no way back in without
    /// the original key — so the message has to be about what to do next, not
    /// about what went wrong. It happens when a key was replaced while its
    /// database stayed put.
    public static func mismatchMessage(name: String, fileName: String) -> String {
        "The \(name) database was encrypted with a different key than the one now in the "
            + "Keychain, so it cannot be opened and cannot be recovered. "
            + "Move \(fileName) out of the ATLAS folder to start a new one."
    }

    /// A random 256-bit key as hex.
    static func mintKey() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
