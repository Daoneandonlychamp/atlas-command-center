import Foundation
import WebKit
import AtlasCore
import AppKit

@MainActor
final class CinemaBridge {
    private weak var webView: WKWebView?
    private var pageIsReady = false

    /// Archive lookups run here rather than in the page: the search is a
    /// two-request match that the page had no way to retry sensibly, and a
    /// shared circuit breaker means a failing Archive stops being asked.
    private let archive = ArchiveSearchProvider()

    func attach(_ webView: WKWebView) {
        self.webView = webView
        pageIsReady = false
    }

    func pageDidLoad() {
        pageIsReady = true
        sendState()
    }

    // MARK: - Persistence

    private let store = CinemaStore.shared

    /// Hands the page everything Cinema has stored.
    ///
    /// Sent on every load, before the page needs it. `adopt` tells the page
    /// whether the database already has a copy: when it is empty this is a first
    /// run against the new store, and the page answers by pushing up whatever
    /// `localStorage` still holds so it can be taken over rather than lost.
    private func sendState() {
        if let failure = store.openFailure {
            NSLog("[ATLAS Cinema] store unavailable: %@", failure)
            call("atlasCinemaState", ["ok": false, "message": failure])
            return
        }
        var payload: [String: Any] = ["ok": true, "adopt": store.isEmpty, "values": store.all()]
        // The TMDB key travels with the state rather than living in the page, so
        // the source file carries no credential. Absent is a valid answer: the
        // page shows its "set a key" panel instead of failing a search.
        if let key = Self.tmdbKey(), !key.isEmpty { payload["tmdbKey"] = key }
        call("atlasCinemaState", payload)
    }

    /// The TMDB key, from the Keychain, falling back to the environment for a
    /// dev run. Same account name as the Settings field writes.
    static func tmdbKey() -> String? {
        if let stored = KeychainManager.shared.get(key: tmdbKeychainAccount), !stored.isEmpty {
            return stored
        }
        return ProcessInfo.processInfo.environment["ATLAS_TMDB_KEY"]
    }

    static let tmdbKeychainAccount = "TMDB_API_KEY"

    /// Persists one allowlisted key. Anything else is ignored rather than stored.
    private func saveState(key: String, value: String?) {
        guard let slot = CinemaStore.Key(rawValue: key) else {
            NSLog("[ATLAS Cinema] refused to store an unknown key: %@", key)
            return
        }
        if let value { store.set(slot, value) } else { store.remove(slot) }
    }

    /// Calls a function on the page, passing the payload as an argument rather
    /// than splicing it into script text.
    private func call(_ function: String, _ payload: [String: Any]) {
        guard let webView, pageIsReady,
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }

        webView.callAsyncJavaScript("window.\(function) && window.\(function)(json)",
                                    arguments: ["json": json], in: nil, in: .page) { result in
            if case .failure(let error) = result {
                NSLog("[ATLAS Cinema] %@ failed: %@", function, error.localizedDescription)
            }
        }
    }

    func handleMessage(_ body: [String: Any]) {
        guard let action = body["action"] as? String else { return }

        if action == "saveState" {
            let key = body["key"] as? String ?? ""
            // A missing value means remove; an empty string is a real value.
            saveState(key: key, value: body["value"] as? String)
            return
        } else if action == "adoptState" {
            // First run against the database: take over what localStorage held.
            guard let values = body["values"] as? [String: String] else { return }
            for (key, value) in values { saveState(key: key, value: value) }
            NSLog("[ATLAS Cinema] adopted %d value(s) from localStorage", values.count)
            return
        }

        if action == "archiveResolve" {
            let requestId = body["requestId"] as? String ?? ""
            let title = body["title"] as? String ?? ""
            let year = body["year"] as? String
            let key = body["key"] as? String ?? title
            resolveArchive(requestId: requestId, title: title, year: year, key: key)
        } else if action == "archiveForget" {
            let key = body["key"] as? String ?? ""
            Task { await archive.forget(key: key) }
        } else if action == "log" {
            let msg = body["message"] as? String ?? ""
            NSLog("[ATLAS Cinema JS] \(msg)")
        }
    }

    // MARK: - Archive

    /// Searches the Archive for a title and answers the page once.
    ///
    /// Every outcome replies, including "not carried" and "failed" — the page
    /// awaits `requestId`, so a silent return would leave it on its spinner.
    private func resolveArchive(requestId: String, title: String, year: String?, key: String) {
        Task { [archive] in
            var payload: [String: Any] = ["requestId": requestId]
            do {
                if let hit = try await archive.find(title: title, year: year, key: key) {
                    payload["found"] = true
                    payload["id"] = hit.identifier
                    payload["title"] = hit.title
                    payload["url"] = hit.streamURL.absoluteString
                } else {
                    payload["found"] = false
                }
            } catch {
                payload["found"] = false
                payload["error"] = error.localizedDescription
            }
            await MainActor.run { self.call("atlasArchiveResult", payload) }
        }
    }

}
