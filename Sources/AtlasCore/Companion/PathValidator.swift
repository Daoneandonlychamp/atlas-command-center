import Foundation

public final class PathValidator {
    public static let shared = PathValidator()

    public init() {}

    public func resolveCanonicalPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        return url.resolvingSymlinksInPath().standardized.path
    }

    public func isPathPermitted(_ path: String, allowedScopes: [String]) -> Bool {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let canonicalTarget = resolveCanonicalPath(path)

        for scope in allowedScopes {
            let canonicalScope = resolveCanonicalPath(scope)

            if canonicalTarget == canonicalScope {
                return true
            }

            let scopePrefix = canonicalScope.hasSuffix("/") ? canonicalScope : canonicalScope + "/"
            if canonicalTarget.hasPrefix(scopePrefix) {
                return true
            }
        }
        return false
    }

    public func validateObsidianURI(_ uri: String) -> Bool {
        guard let url = URL(string: uri),
              url.scheme?.lowercased() == "obsidian",
              url.host?.lowercased() == "open" else {
            return false
        }
        if uri.contains("..") || uri.contains("%2e%2e") {
            return false
        }
        return true
    }
}
