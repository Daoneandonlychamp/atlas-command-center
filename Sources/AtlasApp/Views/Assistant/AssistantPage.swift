import SwiftUI
import AtlasCore

/// The Assistant, as one HTML page.
///
/// Replaces `AssistantView` and the five SwiftUI files around it. Everything
/// that page did — mode switch, model badge, sampling, personas, saved prompts,
/// the conversation rail, the composer — now lives in `assistant.html`, and this
/// holds the bridge that feeds it.
///
/// Kept behind `ATLAS_ASSISTANT_HTML=1` until it has been used in anger. The old
/// page is still there and still the default; nothing is deleted until this one
/// has earned it.
struct AssistantPage: View {
    /// Owns the page's channel into the sessions. Held here rather than rebuilt
    /// per redraw, so a reply streaming into the page is not interrupted by a
    /// SwiftUI body evaluation.
    @State private var bridge = AssistantBridge()

    var body: some View {
        AssistantWebView(bridge: bridge)
    }
}
