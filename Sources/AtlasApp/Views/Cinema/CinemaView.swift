import SwiftUI
import AtlasCore

/// Cinema & Media Streaming Hub (movy.bz clone).
struct CinemaView: View {
    @EnvironmentObject var appState: AtlasAppState
    @State private var bridge = CinemaBridge()

    var body: some View {
        CinemaWebView(bridge: bridge)
            .background(Color.black)
    }
}
