import SwiftUI
import AtlasCore

/// The Business pane: a local, encrypted CRM.
///
/// The whole surface is `crm.html` in a web view, the same arrangement the
/// calendar, board and canvas use. Nothing here reaches Contacts, Mail,
/// Calendar or the network — the records live only in `crm.sqlite`, which is
/// SQLCipher-encrypted with a key held in the login Keychain.
struct BusinessView: View {
    @StateObject private var host = CRMHost()

    var body: some View {
        CRMWebView(bridge: host.bridge)
    }
}

/// Keeps one bridge alive for the lifetime of the pane.
///
/// A fresh bridge per SwiftUI body evaluation would detach the web view from
/// the store mid-edit, so it is held here rather than constructed inline.
@MainActor
private final class CRMHost: ObservableObject {
    let bridge = CRMBridge()
}
