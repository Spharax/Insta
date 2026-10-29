import Foundation

enum RouteDecision: Equatable {
    case allow
    case redirectHome
}

enum PathNormalizer {
    /// Query and fragment are ignored. Repeated slashes collapse, so `//reels`
    /// is `/reels`. Matching is case-insensitive because the result is lowercased.
    /// Trailing slashes are removed except for `/`.
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
        while p.contains("//") {
            p = p.replacingOccurrences(of: "//", with: "/")
        }
        p = p.lowercased()
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    /// Rejects protocol-relative targets (`//evil.com`) before slash collapsing.
    /// `location.replace("//evil.com")` would leave the origin.
    static func isSafeRedirectTarget(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/" {
            return true
        }
        if !trimmed.hasPrefix("/") || trimmed.hasPrefix("//") {
            return false
        }
        if trimmed.contains("//") || trimmed.contains("\\") || trimmed.contains(":") {
            return false
        }
        if trimmed.contains(" ") || trimmed.contains("\t") || trimmed.contains("\n") || trimmed.contains("\r") {
            return false
        }
        return true
    }
}

/// Same order as `classify` in bridge.js and scripts/check_path_rules.py.
/// Hardcoded safety paths are allowed before any configurable block pattern,
/// so a feed or id regex cannot send `/direct` or `/accounts` home.
/// The literal Reels feed (`/reels`) is still blocked when `blockFeed` is on,
/// before the configurable allow list, so a username-style allow cannot permit it.
struct PathPolicy {
    /// KEEP IN SYNC with REELS_BROWSE_FALLBACK in bridge.js.
    static let reelsBrowsePatterns: [String] = [
        "^/reels/audio(?:/.*)?$",
        "^/reels/[^/]+/.+"
    ]

    /// KEEP IN SYNC with EXPLORE_TREE_FALLBACK in bridge.js.
    /// Applied only after the allow list, so `/explore` and `/explore/search` stay open.
    static let exploreTreePatterns: [String] = [
        "^/explore(?:/.*)?$"
    ]

    /// Paths a configurable early pattern must not full-match.
    /// Used only by ConfigValidator, not by decision().
    static let safetySentinels: [String] = [
        "/",
        "/accounts",
        "/accounts/login",
        "/accounts/login/two_factor",
        "/challenge/abc",
        "/consent",
        "/direct",
        "/direct/inbox",
        "/direct/t/123",
        "/stories/someuser/123",
        "/emails/verify",
        "/legal",
        "/privacy",
        "/terms",
        "/about",
        "/oauth/authorize",
        "/reel/abc",
        "/someuser/reel/abc",
        "/p/abc"
    ]
    /// Remote config cannot remove these. They keep login, DMs, Stories, and
    /// individual reels reachable even if `allowedPaths` is emptied or a feed
    /// pattern is pointed at them. Checked before feed and id patterns.
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
        patterns.append(contentsOf: reelsBrowsePatterns)
        patterns.append(contentsOf: exploreTreePatterns)
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

        // 2. Hardcoded safety paths beat a mistyped feed or id pattern.
        if matchesAny(Self.safetyAllowPatterns, path) {
            return .allow
        }

        // 3. Reels feed, before any configurable allow regex.
        if config.reels.blockFeed && (path == "/reels" || matches(config.reels.feedPathPattern, path)) {
            return .redirectHome
        }

        // 4. Reels listings that are not one reel id: /reels/audio/<id>, /reels/<id>/extra.
        if matchesAny(Self.reelsBrowsePatterns, path) {
            return .redirectHome
        }

        // 5. `/reels/<id>` when that form is configured off.
        if !config.reels.allowIdPaths && matches(config.reels.idPathPattern, path) {
            return .redirectHome
        }

        // 6. Safety + configured allows, including individual reel patterns.
        if matchesAny(allowPatterns(), path) {
            return .allow
        }

        // 7. Profile Reels tab.
        if config.profile.hideReelsTab && matches(config.profile.reelsTabPathPattern, path) {
            return .redirectHome
        }

        // 8. Explore hashtag and location browse.
        if matchesAny(config.explore.blockBrowsePathPatterns, path) {
            return .redirectHome
        }

        // 9. Entire Explore tree, only in blockAll mode.
        if config.explore.mode == .blockAll && matchesAny(config.explore.alwaysAllowPathPatterns, path) {
            return .redirectHome
        }

        // 10. Any other /explore path. Search and the bare explore page were allowed in step 6.
        if matchesAny(Self.exploreTreePatterns, path) {
            return .redirectHome
        }

        // 11. Extra block regexes.
        if matchesAny(config.blockedPaths, path) {
            return .redirectHome
        }

        // 12. Profiles and anything unknown stay available.
        return .allow
    }

    func redirectURL() -> URL? {
        let stored = config.redirect.targetPath
        var path = "/"
        if PathNormalizer.isSafeRedirectTarget(stored) {
            path = PathNormalizer.normalize(stored)
        }
        if path == "/reels" || matches(config.reels.feedPathPattern, path) {
            path = "/"
        }
        if !PathNormalizer.isSafeRedirectTarget(path) {
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
