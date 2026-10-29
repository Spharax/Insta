import Foundation

enum RouteDecision: Equatable {
    case allow
    case redirectHome
}

enum PathNormalizer {
    /// Trailing slashes are removed except for `/`. Query and fragment are ignored.
    static func normalize(_ path: String) -> String {
        var p = path
        if let hash = p.firstIndex(of: "#") {
            p = String(p[..<hash])
        }
        if let query = p.firstIndex(of: "?") {
            p = String(p[..<query])
        }
        if p.isEmpty {
            return "/"
        }
        if !p.hasPrefix("/") {
            p = "/" + p
        }
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }
}

/// Same order as `classify` in bridge.js and scripts/check_path_rules.py.
/// Allow rules beat block rules, except the exact Reels feed (`^/reels$` by default),
/// which is blocked before the allow list so a username-style pattern cannot permit it.
struct PathPolicy {
    /// Remote config cannot remove these. They keep login, DMs, Stories, and
    /// individual reels reachable even if `allowedPaths` is emptied or too broad a block is added.
    /// `/reels/<id>` is intentionally not here; `reels.allowIdPaths` controls it.
    /// KEEP IN SYNC with SAFETY_FALLBACK in bridge.js.
    static let safetyAllowPatterns: [String] = [
        "^/accounts(?:/.*)?$",
        "^/challenge(?:/.*)?$",
        "^/consent(?:/.*)?$",
        "^/direct(?:/.*)?$",
        "^/stories(?:/.*)?$",
        "^/emails(?:/.*)?$",
        "^/legal(?:/.*)?$",
        "^/privacy(?:/.*)?$",
        "^/terms(?:/.*)?$",
        "^/about(?:/.*)?$",
        "^/oauth(?:/.*)?$",
        "^/reel/[^/]+$",
        "^/[^/]+/reel/[^/]+$",
        "^/p/[^/]+$"
    ]

    let config: AppConfig
    private let cache: [String: NSRegularExpression]

    init(config: AppConfig) {
        self.config = config
        var compiled: [String: NSRegularExpression] = [:]
        for pattern in Self.allPatterns(in: config) {
            if compiled[pattern] != nil {
                continue
            }
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                compiled[pattern] = regex
            }
        }
        cache = compiled
    }

    static func allPatterns(in config: AppConfig) -> [String] {
        var patterns: [String] = []
        patterns.append(contentsOf: safetyAllowPatterns)
        patterns.append(contentsOf: config.allowedPaths)
        patterns.append(contentsOf: config.blockedPaths)
        patterns.append(config.reels.feedPathPattern)
        patterns.append(config.reels.idPathPattern)
        patterns.append(config.reels.allowReelPathPattern)
        patterns.append(config.reels.allowUserReelPathPattern)
        patterns.append(config.reels.postPathPattern)
        patterns.append(config.profile.reelsTabPathPattern)
        patterns.append(contentsOf: config.explore.alwaysAllowPathPatterns)
        patterns.append(contentsOf: config.explore.blockBrowsePathPatterns)
        return patterns
    }

    func decision(forPath raw: String) -> RouteDecision {
        let path = PathNormalizer.normalize(raw)
        let target = PathNormalizer.normalize(config.redirect.targetPath)

        // 1. Never block the redirect target. This is the loop stop.
        if path == target {
            return .allow
        }

        // 2. Exact Reels feed, before any allow regex.
        if config.reels.blockFeed && matches(config.reels.feedPathPattern, path) {
            return .redirectHome
        }

        // 3. `/reels/<id>` when that form is configured off.
        if !config.reels.allowIdPaths && matches(config.reels.idPathPattern, path) {
            return .redirectHome
        }

        // 4. Safety + configured allows, including individual reel patterns.
        if matchesAny(allowPatterns(), path) {
            return .allow
        }

        // 5. Profile Reels tab.
        if config.profile.hideReelsTab && matches(config.profile.reelsTabPathPattern, path) {
            return .redirectHome
        }

        // 6. Explore hashtag and location browse.
        if matchesAny(config.explore.blockBrowsePathPatterns, path) {
            return .redirectHome
        }

        // 7. Entire Explore tree, only in blockAll mode.
        if config.explore.mode == .blockAll && matchesAny(config.explore.alwaysAllowPathPatterns, path) {
            return .redirectHome
        }

        // 8. Extra block regexes.
        if matchesAny(config.blockedPaths, path) {
            return .redirectHome
        }

        // 9. Profiles and anything unknown stay available.
        return .allow
    }

    func redirectURL() -> URL? {
        var path = PathNormalizer.normalize(config.redirect.targetPath)
        if matches(config.reels.feedPathPattern, path) {
            path = "/"
        }
        if !path.hasPrefix("/") {
            path = "/"
        }
        let absolute = "https://www.instagram.com" + (path == "/" ? "/" : path)
        return URL(string: absolute)
    }

    private func allowPatterns() -> [String] {
        var patterns: [String] = []
        patterns.append(contentsOf: Self.safetyAllowPatterns)
        patterns.append(contentsOf: config.allowedPaths)
        if !config.reels.allowReelPathPattern.isEmpty {
            patterns.append(config.reels.allowReelPathPattern)
        }
        if !config.reels.allowUserReelPathPattern.isEmpty {
            patterns.append(config.reels.allowUserReelPathPattern)
        }
        if !config.reels.postPathPattern.isEmpty {
            patterns.append(config.reels.postPathPattern)
        }
        if config.reels.allowIdPaths && !config.reels.idPathPattern.isEmpty {
            patterns.append(config.reels.idPathPattern)
        }
        if config.explore.mode != .blockAll {
            patterns.append(contentsOf: config.explore.alwaysAllowPathPatterns)
        }
        if !config.reels.allowIdPaths {
            let idPattern = config.reels.idPathPattern
            patterns.removeAll { $0 == idPattern }
        }
        if config.explore.mode == .blockAll {
            let banned = Set(config.explore.alwaysAllowPathPatterns)
            patterns.removeAll { banned.contains($0) }
        }
        return patterns
    }

    private func matchesAny(_ patterns: [String], _ path: String) -> Bool {
        for pattern in patterns where matches(pattern, path) {
            return true
        }
        return false
    }

    private func matches(_ pattern: String, _ path: String) -> Bool {
        guard !pattern.isEmpty, let regex = cache[pattern] else {
            return false
        }
        let range = NSRange(location: 0, length: (path as NSString).length)
        guard let match = regex.firstMatch(in: path, options: [], range: range) else {
            return false
        }
        return match.range.location == 0 && match.range.length == range.length
    }
}
