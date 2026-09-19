import Foundation
import WebKit

/// Reloads a web view when the HTML file it was loaded from changes on disk.
///
/// Only ever active for the `ATLAS_*_PAGE` development overrides. A bundled page
/// cannot change while the app is running, so this attaches to nothing in a
/// normal launch and costs nothing.
///
/// Without it the loop is: edit, switch off the tab, switch back. That is quick
/// enough to tolerate and slow enough to stop you making small adjustments, so
/// they do not get made.
final class PageLiveReload {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private let url: URL
    private weak var webView: WKWebView?
    /// Serialises re-arming against the watcher's own callbacks.
    private let queue = DispatchQueue(label: "com.atlas.app.pagereload")

    /// Starts watching, or returns nil when there is nothing to watch.
    ///
    /// Returned rather than fire-and-forget: the caller has to hold it, and a
    /// watcher nobody holds is deallocated immediately and silently does
    /// nothing.
    @discardableResult
    static func watch(_ url: URL?, reloading webView: WKWebView) -> PageLiveReload? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let watcher = PageLiveReload(url: url, webView: webView)
        watcher.arm()
        return watcher
    }

    private init(url: URL, webView: WKWebView) {
        self.url = url
        self.webView = webView
    }

    deinit {
        source?.cancel()
    }

    private func arm() {
        queue.async { [weak self] in
            guard let self else { return }
            self.source?.cancel()
            self.source = nil
            if self.descriptor >= 0 { close(self.descriptor) }

            self.descriptor = open(self.url.path, O_EVTONLY)
            guard self.descriptor >= 0 else {
                NSLog("[ATLAS live reload] could not watch %@", self.url.lastPathComponent)
                return
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: self.descriptor,
                // Most editors save by writing a new file and renaming it over
                // the old one, so the descriptor we hold stops pointing at the
                // path. Watching delete and rename as well as write is what
                // makes this survive the second save.
                eventMask: [.write, .delete, .rename, .extend],
                queue: self.queue
            )

            source.setEventHandler { [weak self] in
                guard let self else { return }
                let events = source.data

                if events.contains(.delete) || events.contains(.rename) {
                    // The file was replaced. Give the writer a moment to finish,
                    // then watch the new one at the same path.
                    self.queue.asyncAfter(deadline: .now() + 0.15) { self.arm() }
                }
                self.reload()
            }

            source.setCancelHandler { [descriptor = self.descriptor] in
                if descriptor >= 0 { close(descriptor) }
            }

            self.source = source
            source.resume()
            NSLog("[ATLAS live reload] watching %@", self.url.path)
        }
    }

    /// Coalesces the burst of events a single save produces into one reload.
    private var pending: DispatchWorkItem?

    private func reload() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let webView = self.webView else { return }
                // loadFileURL rather than reload(): the page was loaded from a
                // file URL, and reload() on a file URL can serve WebKit's cached
                // copy — which is the change not appearing, which is the bug
                // this whole class exists to avoid.
                webView.loadFileURL(self.url, allowingReadAccessTo: self.url)
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}
