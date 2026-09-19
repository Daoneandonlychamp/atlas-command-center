import SwiftUI
import AtlasCore

/// Finances: plan, money in, money out.
///
/// The whole page is `finances.html`, which owns its own tabs and toolbar. This
/// holds the bridge and the refresh timer and nothing else — the SwiftUI it
/// replaced is gone rather than kept alongside, so there is one page to change
/// rather than two that drift.
struct FinancesView: View {
    /// Owns the page's channel into the store. Held here rather than rebuilt per
    /// redraw, so the web view is not torn down mid-edit.
    @State private var bridge = FinancesBridge()

    private let refresh = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        FinancesWebView(bridge: bridge)
            .onReceive(refresh) { _ in
                // Provider figures move on their own, so re-reading them is how
                // a silent price rise gets noticed rather than quietly applied.
                bridge.refreshProviderAmounts()
            }
    }
}
