import AtlasCore
import Foundation
import WebKit

/// Injects the shared HTML design system into a web view configuration.
///
/// All five ATLAS surfaces call this and nothing else — the delivery mechanism
/// lives here so a change to how the stylesheet is escaped, guarded or ordered
/// happens once rather than five times.
///
/// Why injection rather than `<link rel="stylesheet">`: every page runs from
/// file:// under a CSP whose `style-src` is `'unsafe-inline'` with no `'self'`,
/// and Chat and Canvas are loaded with `allowingReadAccessTo:` their own file
/// only. A sibling `.css` is unreachable on both counts. Injecting the text
/// satisfies the existing policy as-is and widens no boundary.
extension WKUserContentController {
    /// Adds the shared stylesheet as a `<style id="atlas-shared-styles">`.
    ///
    /// Runs at `.atDocumentStart`, so the element lands in the document before
    /// the page's own `<style>` is parsed. Equal-specificity rules later in
    /// document order win, which means every page keeps the ability to
    /// override a shared default just by declaring the same property.
    func addAtlasSharedStyles() {
        guard let css = AtlasResources.sharedStyles else { return }

        let source = """
        (function () {
          var ID = 'atlas-shared-styles';
          var CSS = \(Self.javaScriptStringLiteral(css));

          function install() {
            if (document.getElementById(ID)) { return true; }
            // At document start the parser may not have created <html> yet,
            // let alone <head>. Nothing to attach to means try again later.
            var root = document.head || document.documentElement;
            if (!root) { return false; }
            var style = document.createElement('style');
            style.id = ID;
            style.textContent = CSS;
            // First child, so the page's own <style> still comes later in
            // document order and keeps the last word on equal specificity.
            root.insertBefore(style, root.firstChild);
            return true;
          }

          if (!install()) {
            // MutationObserver can watch `document` before documentElement
            // exists, which readystatechange alone cannot.
            var observer = new MutationObserver(function () {
              if (install()) { observer.disconnect(); }
            });
            observer.observe(document, { childList: true, subtree: true });
            document.addEventListener('DOMContentLoaded', function () {
              install();
              observer.disconnect();
            });
          }
        })();
        """

        addUserScript(WKUserScript(source: source,
                                   injectionTime: .atDocumentStart,
                                   forMainFrameOnly: true))
    }

    /// Encodes arbitrary text as a JavaScript string literal.
    ///
    /// JSON encoding covers quotes, backslashes and control characters. U+2028
    /// and U+2029 are legal inside a JSON string but are line terminators in
    /// JavaScript, so they are escaped separately — otherwise a stylesheet
    /// containing either would end the literal and break the script.
    static func javaScriptStringLiteral(_ text: String) -> String {
        let encoded: String
        if let data = try? JSONSerialization.data(withJSONObject: [text], options: []),
           let array = String(data: data, encoding: .utf8) {
            // JSONSerialization only encodes top-level containers, so unwrap
            // the single-element array it produced: ["…"] -> "…"
            encoded = String(array.dropFirst().dropLast())
        } else {
            encoded = "\"\""
        }

        return encoded
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
