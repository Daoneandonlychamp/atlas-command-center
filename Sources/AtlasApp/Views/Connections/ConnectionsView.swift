import SwiftUI
import AtlasCore

/// The Connections section: every identity Hermes can act as, grouped by
/// provider family, read live from the credential broker. The actual OAuth
/// dance still belongs to the Connection Center on localhost — ATLAS shows the
/// truth and keeps that server alive.
struct ConnectionsView: View {
    @StateObject private var service = ConnectionCenterService()

    private var families: [String] {
        Array(Set(service.identities.map(\.family))).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let err = service.lastError {
                    Text(err)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(AtlasTheme.Colors.error)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AtlasTheme.Colors.cardSurface)
                        .cornerRadius(8)
                }

                ForEach(families, id: \.self) { family in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(family.uppercased())
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.6)
                            .foregroundColor(AtlasTheme.Colors.champagneGold)

                        ForEach(service.identities.filter { $0.family == family }) { identity in
                            row(identity)
                        }
                    }
                }
            }
            .padding(28)
        }
        .background(AtlasTheme.Colors.background)
        .onAppear { service.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connections")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(AtlasTheme.Colors.textPrimary)
                Text("\(service.healthyCount) of \(service.identities.count) identities active")
                    .font(.system(size: 13))
                    .foregroundColor(AtlasTheme.Colors.textSecondary)
            }
            Spacer()
            HStack(spacing: 10) {
                statusPill
                Button(service.isRunning ? "Open Connection Center" : "Start Connection Center") {
                    if service.isRunning {
                        NSWorkspace.shared.open(ConnectionCenterService.url)
                    } else if service.startServer() {
                        NSWorkspace.shared.open(ConnectionCenterService.url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AtlasTheme.Colors.champagneGold)

                Button("Refresh") { service.refresh() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(service.isRunning ? AtlasTheme.Colors.success : AtlasTheme.Colors.textMuted)
                .frame(width: 7, height: 7)
            Text(service.isRunning ? "server up" : "server down")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(AtlasTheme.Colors.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AtlasTheme.Colors.cardSurface)
        .clipShape(Capsule())
    }

    private func row(_ identity: BrokerIdentity) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(identity.isHealthy ? AtlasTheme.Colors.success
                      : (identity.isWired ? AtlasTheme.Colors.warning : AtlasTheme.Colors.textMuted))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(identity.identityId)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(AtlasTheme.Colors.textPrimary)
                HStack(spacing: 8) {
                    Text(identity.provider)
                    Text("·")
                    Text(identity.lifecycleState)
                    if let handle = identity.handle, !handle.isEmpty {
                        Text("·")
                        Text(handle)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(AtlasTheme.Colors.textMuted)
            }

            Spacer()

            if !identity.isWired {
                Text("NOT WIRED")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(AtlasTheme.Colors.textMuted)
            } else {
                Button(identity.isHealthy ? "Reconnect" : "Connect") {
                    if !service.isRunning { service.startServer() }
                    NSWorkspace.shared.open(
                        ConnectionCenterService.url
                            .appendingPathComponent("auth/start")
                            .appending(queryItems: [URLQueryItem(name: "identity_id", value: identity.identityId)])
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(AtlasTheme.Colors.cardSurface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AtlasTheme.Colors.borderSubtle))
        .cornerRadius(8)
    }
}
