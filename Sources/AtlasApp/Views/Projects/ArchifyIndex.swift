import SwiftUI
import AtlasCore

/// Which projects currently have an archify diagram.
///
/// The sidebar marks every row, so this holds the answer as a set read once
/// rather than a directory listing per row per redraw. It is refreshed when the
/// view appears and after a diagram is dropped in.
@MainActor
final class ArchifyIndex: ObservableObject {
    @Published private(set) var slugs: Set<String> = []

    /// The last thing to go wrong, shown next to the drop target so a rejected
    /// file says why instead of silently doing nothing.
    @Published var lastError: String?

    init() { refresh() }

    func refresh() {
        slugs = ArchifyDiagrams.availableSlugs()
    }

    /// Answered from the cached set: this runs for every visible row.
    func hasDiagram(_ project: AtlasProject) -> Bool {
        ArchifyDiagrams.match(project.name, among: slugs) != nil
    }

    /// The diagram's location, derived from the cached set so a redraw does not
    /// hit the disk. Recomputes when `slugs` changes, i.e. right after a drop.
    func diagramURL(for project: AtlasProject) -> URL? {
        guard let name = ArchifyDiagrams.match(project.name, among: slugs) else { return nil }
        return ArchifyDiagrams.directory.appendingPathComponent(name + ".html")
    }

    /// Files a dropped diagram under the name this project looks for.
    func install(_ source: URL, for project: AtlasProject) {
        do {
            try ArchifyDiagrams.install(source, for: project.name)
            lastError = nil
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Pulls the file URL out of a drag and files it. Returns whether the drop
    /// was taken on.
    func handleDrop(_ providers: [NSItemProvider], for project: AtlasProject) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) })
                ?? providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in self.install(url, for: project) }
        }
        return true
    }
}
