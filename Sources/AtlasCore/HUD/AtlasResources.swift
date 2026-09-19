import Foundation

/// Locates files that ship inside the AtlasCore resource bundle.
///
/// `Bundle.module` resolves per target, so AtlasApp cannot reach AtlasCore's
/// resources directly — this is the seam that hands them over.
public enum AtlasResources {
    public static var hudPage: URL? {
        Bundle.module.url(forResource: "hud", withExtension: "html")
    }

    /// The Assistant transcript renderer. Hosted by AssistantChatWebView, which
    /// runs it under a much tighter web view configuration than the HUD.
    public static var chatPage: URL? {
        Bundle.module.url(forResource: "chat", withExtension: "html")
    }

    /// Calendar, week and day views. Hosted by CalendarWebView, which — unlike
    /// the Assistant transcript — does give its page a channel into the app.
    public static var calendarPage: URL? {
        Bundle.module.url(forResource: "calendar", withExtension: "html")
    }

    /// The board over Apple Reminders. It loads a vendored copy of Sortable from
    /// the same directory, so its host grants read access to the folder rather
    /// than to the single file.
    public static var kanbanPage: URL? {
        Bundle.module.url(forResource: "kanban", withExtension: "html")
    }

    /// The infinite canvas over JSON Canvas files.
    public static var canvasPage: URL? {
        Bundle.module.url(forResource: "canvas", withExtension: "html")
    }

    /// The local CRM: companies, contacts, opportunities and their history.
    public static var crmPage: URL? {
        Bundle.module.url(forResource: "crm", withExtension: "html")
    }

    /// Cinema & Media Streaming Hub (movy.bz clone).
    public static var cinemaPage: URL? {
        Bundle.module.url(forResource: "cinema", withExtension: "html")
    }

    /// The Assistant: transcript, conversations, composer and controls.
    ///
    /// Supersedes `chat.html`, which rendered only the transcript while the
    /// chrome around it stayed in SwiftUI. The menu-bar window loads this same
    /// page and calls `compact()` to strip it back to the transcript, so there
    /// is one renderer rather than two that drift.
    public static var assistantPage: URL? {
        Bundle.module.url(forResource: "assistant", withExtension: "html")
    }

    /// Money out: subscriptions, one-off spend and what falls due next.
    public static var financesPage: URL? {
        Bundle.module.url(forResource: "finances", withExtension: "html")
    }

    /// The markdown renderer shared by the transcript and the canvas.
    ///
    /// Injected as a user script rather than loaded with `<script src>`: a
    /// file:// page cannot reliably load a sibling under a strict CSP, and
    /// injection keeps both pages' file access at nothing.
    public static var markdownScript: String? {
        guard let url = Bundle.module.url(forResource: "markdown", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Any bundled page by base name, for trying a candidate visual.
    public static func page(named name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "html")
    }

    /// Tokens, reset and components shared by all five HTML surfaces.
    ///
    /// Delivered the same way as `markdownScript` and for the same reason: the
    /// pages run from file:// under a CSP whose `style-src` has no `'self'`,
    /// and Chat and Canvas are handed read access to nothing but their own
    /// file. Injecting the text keeps both of those boundaries untouched —
    /// `'unsafe-inline'` already permits a `<style>` element.
    ///
    /// Order matters: theme first so components can use its tokens.
    public static var sharedStyles: String? {
        let sheets = ["atlas-theme", "atlas-components"].compactMap { name -> String? in
            guard let url = Bundle.module.url(forResource: name, withExtension: "css") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        return sheets.isEmpty ? nil : sheets.joined(separator: "\n")
    }
}
