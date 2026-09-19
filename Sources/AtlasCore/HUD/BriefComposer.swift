import Foundation

/// Turns the HUD snapshot into something worth saying out loud.
///
/// Composed from the live payload rather than read from the `morning-brief`
/// cron output, for two reasons: it is accurate at the moment you press the
/// button rather than whenever the job last ran, and it works even on a day the
/// job has not fired. Everything spoken here is a number already on screen.
public enum BriefComposer {

    public static func spokenBrief(from payload: HUDPayload) -> String {
        var lines: [String] = []

        lines.append("\(payload.brief.greeting).")

        // Calendar first — it is the only part with a deadline attached.
        if !payload.brief.calendarAuthorized {
            lines.append("I don't have calendar access yet.")
        } else if payload.brief.events.isEmpty {
            lines.append("Your day is clear.")
        } else {
            let count = payload.brief.events.count
            lines.append("You have \(count) event\(count == 1 ? "" : "s") today.")
            if let next = payload.brief.events.sorted(by: { $0.startEpoch < $1.startEpoch }).first {
                let time = timeFormatter.string(from: Date(timeIntervalSince1970: next.startEpoch))
                lines.append(next.isAllDay ? "\(next.title), all day."
                                           : "Next up, \(next.title) at \(time).")
            }
        }

        if payload.brief.overdueTasks > 0 {
            let n = payload.brief.overdueTasks
            lines.append("\(n) reminder\(n == 1 ? " is" : "s are") overdue.")
        }

        // Then anything actually broken.
        let cron = payload.cron
        if cron.failing > 0 {
            lines.append("Warning. \(cron.failing) scheduled job\(cron.failing == 1 ? " is" : "s are") failing.")
            let broken = cron.jobs.filter { $0.health == "failing" }.map(\.name)
            if !broken.isEmpty { lines.append("Namely, \(spokenList(broken)).") }
        } else if cron.jobs.isEmpty {
            lines.append("No scheduled jobs are registered.")
        } else {
            lines.append("All \(cron.jobs.count) scheduled jobs are healthy.")
        }

        if let next = cron.jobs.compactMap(\.nextRunEpoch).min() {
            let wait = next - Date().timeIntervalSince1970
            if wait > 0,
               let name = cron.jobs.first(where: { $0.nextRunEpoch == next })?.name {
                lines.append("Next run is \(name), in \(spokenDuration(wait)).")
            }
        }

        // Then money, framed as what it is — an estimate, not a bill.
        let sessions = payload.sessions
        if sessions.totalCost > 0 {
            lines.append("Claude usage today is running at \(spokenMoney(sessions.todayCost)), "
                         + "with \(spokenMoney(sessions.totalCost)) over the last thirty days, estimated.")
        }

        // Then the work itself.
        let dirty = payload.workspace.projects.filter { $0.uncommitted > 0 }
        if let busiest = dirty.max(by: { $0.uncommitted < $1.uncommitted }) {
            lines.append("\(dirty.count) project\(dirty.count == 1 ? " has" : "s have") uncommitted work. "
                         + "\(busiest.name) leads with \(busiest.uncommitted) file\(busiest.uncommitted == 1 ? "" : "s").")
        }

        if payload.workspace.pendingApprovals > 0 {
            let n = payload.workspace.pendingApprovals
            lines.append("\(n) action\(n == 1 ? "" : "s") await\(n == 1 ? "s" : "") your approval.")
        }

        // And anything about the machine worth interrupting for.
        let vitals = payload.vitals
        if vitals.diskPercent >= 90 {
            lines.append("Storage is at \(Int(vitals.diskPercent)) percent.")
        }
        if let battery = vitals.batteryPercent, battery < 20, !vitals.isCharging {
            lines.append("Battery is at \(Int(battery)) percent and not charging.")
        }
        if vitals.thermalState == "serious" || vitals.thermalState == "critical" {
            lines.append("Thermal state is \(vitals.thermalState).")
        }

        return lines.joined(separator: " ")
    }

    /// "a, b and c" — an Oxford-comma-free list, because it is being spoken.
    static func spokenList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    static func spokenDuration(_ seconds: Double) -> String {
        if seconds < 90 { return "under a minute" }
        if seconds < 3600 {
            let minutes = Int((seconds / 60).rounded())
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        let hours = seconds / 3600
        if hours < 24 {
            let rounded = Int(hours.rounded())
            return "about \(rounded) hour\(rounded == 1 ? "" : "s")"
        }
        let days = Int((hours / 24).rounded())
        return "about \(days) day\(days == 1 ? "" : "s")"
    }

    /// Spoken money drops the cents once the number is large enough that they
    /// stop meaning anything.
    static func spokenMoney(_ amount: Double) -> String {
        if amount >= 100 { return "\(Int(amount.rounded())) dollars" }
        if amount >= 1 {
            let dollars = Int(amount)
            let cents = Int(((amount - Double(dollars)) * 100).rounded())
            return cents == 0 ? "\(dollars) dollars" : "\(dollars) dollars \(cents)"
        }
        return "\(Int((amount * 100).rounded())) cents"
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}
