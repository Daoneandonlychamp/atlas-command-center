import SwiftUI
import AtlasCore
import Luminare

/// Calendar & Reminders, rendered by `calendar.html`.
///
/// This was a SwiftUI month grid. It is a web page now for the same reason the
/// HUD is: a time grid with drag-to-reschedule is dense vector work that iterates
/// far faster in HTML than in hand-built `Path`s and gesture recognisers. The
/// data still comes from EventKit natively — see `CalendarBridge`.
struct CalendarView: View {
    @EnvironmentObject var appState: AtlasAppState
    @State private var bridge = CalendarBridge()
    @State private var calendarStatus = CalendarManager.shared.calendarAuthorizationStatus
    @State private var reminderStatus = CalendarManager.shared.reminderAuthorizationStatus

    private var needsPermission: Bool {
        calendarStatus != .authorized || reminderStatus != .authorized
    }

    var body: some View {
        Group {
            if needsPermission {
                permissionGate
            } else {
                CalendarWebView(bridge: bridge)
            }
        }
        .background(AtlasTheme.Colors.background)
        .onAppear {
            refreshStatus()
            bridge.onDataChanged = { appState.refreshAllData() }
            bridge.onOpenJournal = { day in
                appState.pendingJournalDay = day
                appState.selectedSection = .journal
            }
        }
    }

    /// Shown instead of the page when access is missing. Once macOS has been told
    /// "don't allow" it stops asking, so this says where to go rather than
    /// offering a button that would do nothing.
    private var permissionGate: some View {
        VStack(spacing: AtlasTheme.Spacing.md) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 30))
                .foregroundColor(AtlasTheme.Colors.champagneGold)
            Text("ATLAS needs access to your Calendar and Reminders")
                .font(AtlasTheme.Typography.headline)
                .foregroundColor(AtlasTheme.Colors.textPrimary)
            Text(statusLine)
                .font(AtlasTheme.Typography.caption)
                .foregroundColor(AtlasTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: AtlasTheme.Spacing.sm) {
                Button("Request access") {
                    CalendarManager.shared.requestCalendarAccess { _ in
                        CalendarManager.shared.requestReminderAccess { _ in refreshStatus() }
                    }
                }
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Check again") { refreshStatus() }
            }
            .font(AtlasTheme.Typography.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusLine: String {
        var parts: [String] = []
        if calendarStatus != .authorized { parts.append("Calendar: \(calendarStatus.rawValue)") }
        if reminderStatus != .authorized { parts.append("Reminders: \(reminderStatus.rawValue)") }
        let detail = parts.joined(separator: " · ")
        return calendarStatus == .denied || reminderStatus == .denied
            ? "\(detail)\nOnce access is denied macOS stops asking — turn it on in System Settings › Privacy & Security."
            : detail
    }

    private func refreshStatus() {
        calendarStatus = CalendarManager.shared.calendarAuthorizationStatus
        reminderStatus = CalendarManager.shared.reminderAuthorizationStatus
        if !needsPermission { bridge.reload() }
    }
}
