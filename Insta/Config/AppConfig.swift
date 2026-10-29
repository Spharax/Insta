import Foundation

enum ConfigError: LocalizedError, Equatable {
    case malformedJSON
    case unsupportedSchema(Int)
    case invalidRegex(String)
    case invalidEnum(String)
    case invalidRedirectTarget
    case invalidSelector(String)

    var errorDescription: String? { userFacing }

    var userFacing: String {
        switch self {
        case .malformedJSON:
            return "The config JSON could not be read."
        case .unsupportedSchema(let version):
            return "Unsupported schemaVersion \(version)."
        case .invalidRegex(let pattern):
            return "Invalid regex: \(Self.truncate(pattern))"
        case .invalidEnum(let value):
            return "Unsupported config value: \(Self.truncate(value))"
        case .invalidRedirectTarget:
            return "Redirect target must be a path and must not be the Reels feed."
        case .invalidSelector(let selector):
            return "Unsafe selector: \(Self.truncate(selector))"
        }
    }

    private static func truncate(_ text: String) -> String {
        if text.count <= 80 {
            return text
        }
        return String(text.prefix(80))
    }
}

enum ReelsNavMode: String, Codable, Equatable, Sendable {
    case disabledVisible = "disabled-visible"
    case hidden = "hidden"
}

enum ExploreMode: String, Codable, Equatable, Sendable {
    case hideGridKeepSearch
    case blockAll
}

enum RedirectMethod: String, Codable, Equatable, Sendable {
    case replace
}

struct FeedConfig: Codable, Equatable, Sendable {
    var homePath: String
    var hideSelectors: [String]
    var storiesSelectors: [String]
    var storiesTrayAncestorDepth: Int
    var hideTextSnippets: [String]
    var keepSelectors: [String]
}

struct ReelsNavConfig: Codable, Equatable, Sendable {
    var mode: ReelsNavMode
    var navRootSelectors: [String]
    var selectors: [String]
    var labelMatchers: [String]
    var dimOpacity: Double
    var interceptEvents: [String]
}

struct ExploreConfig: Codable, Equatable, Sendable {
    var mode: ExploreMode
    var navSelectors: [String]
    var gridSelectors: [String]
    var searchKeepSelectors: [String]
    var alwaysAllowPathPatterns: [String]
    var blockBrowsePathPatterns: [String]
}

struct ProfileConfig: Codable, Equatable, Sendable {
    var hideReelsTab: Bool
    var reelsTabSelectors: [String]
    var reelsTabPathPattern: String
}

struct RedirectConfig: Codable, Equatable, Sendable {
    var targetPath: String
    var method: RedirectMethod
    var maxRedirects: Int
    var windowMs: Int
}

struct ReelsRules: Codable, Equatable, Sendable {
    var blockFeed: Bool
    var feedPathPattern: String
    var allowReelPathPattern: String
    var allowUserReelPathPattern: String
    var allowIdPaths: Bool
    var idPathPattern: String
    var postPathPattern: String
}

struct ReelLockConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var viewerSelectors: [String]
    var scrollContainerSelectors: [String]
    var swipeThresholdPx: Int
    var lockWheel: Bool
    var hideNextPrev: Bool
    var nextPrevSelectors: [String]
    var forceReelIdBack: Bool
    var restoreScrollOnClose: Bool
    var allowScrollSelectors: [String]
    var videoSelectors: [String]
}

struct AppConfig: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var configVersion: String
    var feed: FeedConfig
    var reelsNav: ReelsNavConfig
    var explore: ExploreConfig
    var profile: ProfileConfig
    var redirect: RedirectConfig
    var blockedPaths: [String]
    var allowedPaths: [String]
    var reels: ReelsRules
    var reelLock: ReelLockConfig

    func javascriptPayload() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let base = try encoder.encode(self)
        guard var object = try JSONSerialization.jsonObject(with: base, options: []) as? [String: Any] else {
            throw ConfigError.malformedJSON
        }
        object["safetyAllowPaths"] = PathPolicy.safetyAllowPatterns
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

enum ConfigValidator {
    static func validate(_ config: AppConfig) throws {
        var seen = Set<String>()
        for pattern in PathPolicy.allPatterns(in: config) {
            if seen.contains(pattern) {
                continue
            }
            seen.insert(pattern)
            if pattern.isEmpty {
                throw ConfigError.invalidRegex(pattern)
            }
            do {
                _ = try NSRegularExpression(pattern: pattern, options: [])
            } catch {
                throw ConfigError.invalidRegex(pattern)
            }
        }

        let target = PathNormalizer.normalize(config.redirect.targetPath)
        if !target.hasPrefix("/") {
            throw ConfigError.invalidRedirectTarget
        }
        if config.reels.blockFeed {
            let feed = try NSRegularExpression(pattern: config.reels.feedPathPattern, options: [])
            let range = NSRange(location: 0, length: (target as NSString).length)
            if let match = feed.firstMatch(in: target, options: [], range: range),
               match.range.location == 0,
               match.range.length == range.length {
                throw ConfigError.invalidRedirectTarget
            }
        }

        let groups = [
            config.feed.hideSelectors,
            config.feed.storiesSelectors,
            config.feed.keepSelectors,
            config.reelsNav.navRootSelectors,
            config.reelsNav.selectors,
            config.explore.navSelectors,
            config.explore.gridSelectors,
            config.explore.searchKeepSelectors,
            config.profile.reelsTabSelectors,
            config.reelLock.viewerSelectors,
            config.reelLock.scrollContainerSelectors,
            config.reelLock.nextPrevSelectors,
            config.reelLock.allowScrollSelectors,
            config.reelLock.videoSelectors
        ]
        for group in groups {
            for selector in group {
                try validateSelector(selector)
            }
        }
    }

    static func validateSelector(_ selector: String) throws {
        if selector.isEmpty || selector.count > 300 {
            throw ConfigError.invalidSelector(selector)
        }
        let lowered = selector.lowercased()
        if selector.contains("{") || selector.contains("}") || selector.contains("<") || selector.contains(">") {
            throw ConfigError.invalidSelector(selector)
        }
        if lowered.contains("expression(")
            || lowered.contains("url(")
            || lowered.contains("@import")
            || lowered.contains("javascript:") {
            throw ConfigError.invalidSelector(selector)
        }
    }
}

extension AppConfig {
    static func decodeAndValidate(from data: Data) throws -> AppConfig {
        let dto: RootDTO
        do {
            dto = try JSONDecoder().decode(RootDTO.self, from: data)
        } catch {
            throw ConfigError.malformedJSON
        }
        guard let schema = dto.schemaVersion else {
            throw ConfigError.malformedJSON
        }
        guard schema == AppConstants.supportedSchemaVersion else {
            throw ConfigError.unsupportedSchema(schema)
        }
        let config = try AppConfig(dto: dto)
        try ConfigValidator.validate(config)
        return config
    }

    /// Used only when the bundled file is missing or unreadable.
    /// Path rules match fallback-config.json. Selectors match too.
    static let fallback = AppConfig(
        schemaVersion: 1,
        configVersion: "hardcoded",
        feed: FeedConfig(
            homePath: "/",
            hideSelectors: ["article"],
            storiesSelectors: ["a[href^='/stories/']", "a[href*='/stories/']"],
            storiesTrayAncestorDepth: 4,
            hideTextSnippets: ["Suggested for you", "You're all caught up", "Suggested accounts"],
            keepSelectors: ["nav", "header", "[role='tablist']"]
        ),
        reelsNav: ReelsNavConfig(
            mode: .disabledVisible,
            navRootSelectors: ["nav", "[role='tablist']", "[role='navigation']"],
            selectors: ["a[href='/reels/']", "a[href='/reels']"],
            labelMatchers: ["Reels"],
            dimOpacity: 0.4,
            interceptEvents: ["click", "pointerdown", "pointerup", "touchstart", "touchend", "auxclick"]
        ),
        explore: ExploreConfig(
            mode: .hideGridKeepSearch,
            navSelectors: ["a[aria-label='Explore']", "[aria-label='Explore']"],
            gridSelectors: ["main article"],
            searchKeepSelectors: [
                "input[type='search']",
                "input[aria-label='Search']",
                "input[aria-label='Search input']",
                "input[placeholder='Search']",
                "[role='search']"
            ],
            alwaysAllowPathPatterns: ["^/explore$", "^/explore/search(?:/.*)?$"],
            blockBrowsePathPatterns: ["^/explore/tags(?:/.*)?$", "^/explore/locations(?:/.*)?$"]
        ),
        profile: ProfileConfig(
            hideReelsTab: true,
            reelsTabSelectors: ["a[href$='/reels/']", "a[href$='/reels']"],
            reelsTabPathPattern: "^/[^/]+/reels$"
        ),
        redirect: RedirectConfig(targetPath: "/", method: .replace, maxRedirects: 6, windowMs: 10000),
        blockedPaths: ["^/reels$"],
        allowedPaths: [
            "^/$",
            "^/accounts(?:/.*)?$",
            "^/challenge(?:/.*)?$",
            "^/consent(?:/.*)?$",
            "^/direct(?:/.*)?$",
            "^/stories(?:/.*)?$",
            "^/reel/[^/]+$",
            "^/[^/]+/reel/[^/]+$",
            "^/reels/[^/]+$",
            "^/p/[^/]+$",
            "^/explore$",
            "^/explore/search(?:/.*)?$",
            "^/emails(?:/.*)?$",
            "^/legal(?:/.*)?$",
            "^/privacy(?:/.*)?$",
            "^/terms(?:/.*)?$",
            "^/about(?:/.*)?$",
            "^/oauth(?:/.*)?$"
        ],
        reels: ReelsRules(
            blockFeed: true,
            feedPathPattern: "^/reels$",
            allowReelPathPattern: "^/reel/[^/]+$",
            allowUserReelPathPattern: "^/[^/]+/reel/[^/]+$",
            allowIdPaths: true,
            idPathPattern: "^/reels/[^/]+$",
            postPathPattern: "^/p/[^/]+$"
        ),
        reelLock: ReelLockConfig(
            enabled: true,
            viewerSelectors: ["[role='dialog']"],
            scrollContainerSelectors: ["[role='dialog']", "[role='presentation']"],
            swipeThresholdPx: 10,
            lockWheel: true,
            hideNextPrev: true,
            nextPrevSelectors: [
                "[aria-label='Next']",
                "[aria-label='Previous']",
                "[aria-label='Next Reel']",
                "[aria-label='Previous Reel']",
                "[aria-label='Up Next']",
                "[aria-label='Next video']",
                "[aria-label='Previous video']"
            ],
            forceReelIdBack: true,
            restoreScrollOnClose: true,
            allowScrollSelectors: [
                "textarea",
                "input",
                "form",
                "[aria-label='Comment']",
                "[aria-label='Comments']",
                "[aria-label*='comment']",
                "[aria-label*='Comment']"
            ],
            videoSelectors: ["video"]
        )
    )
}

private struct RootDTO: Decodable {
    var schemaVersion: Int?
    var configVersion: String?
    var feed: FeedDTO?
    var reelsNav: ReelsNavDTO?
    var explore: ExploreDTO?
    var profile: ProfileDTO?
    var redirect: RedirectDTO?
    var blockedPaths: [String]?
    var allowedPaths: [String]?
    var reels: ReelsDTO?
    var reelLock: ReelLockDTO?
}

private struct FeedDTO: Decodable {
    var homePath: String?
    var hideSelectors: [String]?
    var storiesSelectors: [String]?
    var storiesTrayAncestorDepth: Int?
    var hideTextSnippets: [String]?
    var keepSelectors: [String]?
}

private struct ReelsNavDTO: Decodable {
    var mode: String?
    var navRootSelectors: [String]?
    var selectors: [String]?
    var labelMatchers: [String]?
    var dimOpacity: Double?
    var interceptEvents: [String]?
}

private struct ExploreDTO: Decodable {
    var mode: String?
    var navSelectors: [String]?
    var gridSelectors: [String]?
    var searchKeepSelectors: [String]?
    var alwaysAllowPathPatterns: [String]?
    var blockBrowsePathPatterns: [String]?
}

private struct ProfileDTO: Decodable {
    var hideReelsTab: Bool?
    var reelsTabSelectors: [String]?
    var reelsTabPathPattern: String?
}

private struct RedirectDTO: Decodable {
    var targetPath: String?
    var method: String?
    var maxRedirects: Int?
    var windowMs: Int?
}

private struct ReelsDTO: Decodable {
    var blockFeed: Bool?
    var feedPathPattern: String?
    var allowReelPathPattern: String?
    var allowUserReelPathPattern: String?
    var allowIdPaths: Bool?
    var idPathPattern: String?
    var postPathPattern: String?
}

private struct ReelLockDTO: Decodable {
    var enabled: Bool?
    var viewerSelectors: [String]?
    var scrollContainerSelectors: [String]?
    var swipeThresholdPx: Int?
    var lockWheel: Bool?
    var hideNextPrev: Bool?
    var nextPrevSelectors: [String]?
    var forceReelIdBack: Bool?
    var restoreScrollOnClose: Bool?
    var allowScrollSelectors: [String]?
    var videoSelectors: [String]?
}

extension AppConfig {
    private init(dto: RootDTO) throws {
        let fallback = AppConfig.fallback
        let trimmedVersion = dto.configVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(
            schemaVersion: AppConstants.supportedSchemaVersion,
            configVersion: trimmedVersion.isEmpty ? fallback.configVersion : trimmedVersion,
            feed: FeedConfig(dto: dto.feed, fallback: fallback.feed),
            reelsNav: try ReelsNavConfig(dto: dto.reelsNav, fallback: fallback.reelsNav),
            explore: try ExploreConfig(dto: dto.explore, fallback: fallback.explore),
            profile: ProfileConfig(dto: dto.profile, fallback: fallback.profile),
            redirect: try RedirectConfig(dto: dto.redirect, fallback: fallback.redirect),
            blockedPaths: dto.blockedPaths ?? fallback.blockedPaths,
            allowedPaths: dto.allowedPaths ?? fallback.allowedPaths,
            reels: ReelsRules(dto: dto.reels, fallback: fallback.reels),
            reelLock: ReelLockConfig(dto: dto.reelLock, fallback: fallback.reelLock)
        )
    }
}

private extension FeedConfig {
    init(dto: FeedDTO?, fallback: FeedConfig) {
        let depth = dto?.storiesTrayAncestorDepth ?? fallback.storiesTrayAncestorDepth
        self.init(
            homePath: nonempty(dto?.homePath) ?? fallback.homePath,
            hideSelectors: dto?.hideSelectors ?? fallback.hideSelectors,
            storiesSelectors: dto?.storiesSelectors ?? fallback.storiesSelectors,
            storiesTrayAncestorDepth: min(max(depth, 1), 8),
            hideTextSnippets: dto?.hideTextSnippets ?? fallback.hideTextSnippets,
            keepSelectors: dto?.keepSelectors ?? fallback.keepSelectors
        )
    }
}

private extension ReelsNavConfig {
    init(dto: ReelsNavDTO?, fallback: ReelsNavConfig) throws {
        let mode = try parseEnum(dto?.mode, as: ReelsNavMode.self, fallback: fallback.mode)
        let opacity = dto?.dimOpacity ?? fallback.dimOpacity
        let known: Set<String> = ["click", "pointerdown", "pointerup", "touchstart", "touchend", "auxclick"]
        let requested = dto?.interceptEvents ?? fallback.interceptEvents
        let filtered = requested.filter { known.contains($0) }
        self.init(
            mode: mode,
            navRootSelectors: dto?.navRootSelectors ?? fallback.navRootSelectors,
            selectors: dto?.selectors ?? fallback.selectors,
            labelMatchers: dto?.labelMatchers ?? fallback.labelMatchers,
            dimOpacity: (opacity.isNaN || opacity < 0 || opacity > 1) ? fallback.dimOpacity : opacity,
            interceptEvents: filtered.isEmpty ? fallback.interceptEvents : filtered
        )
    }
}

private extension ExploreConfig {
    init(dto: ExploreDTO?, fallback: ExploreConfig) throws {
        let mode = try parseEnum(dto?.mode, as: ExploreMode.self, fallback: fallback.mode)
        self.init(
            mode: mode,
            navSelectors: dto?.navSelectors ?? fallback.navSelectors,
            gridSelectors: dto?.gridSelectors ?? fallback.gridSelectors,
            searchKeepSelectors: dto?.searchKeepSelectors ?? fallback.searchKeepSelectors,
            alwaysAllowPathPatterns: dto?.alwaysAllowPathPatterns ?? fallback.alwaysAllowPathPatterns,
            blockBrowsePathPatterns: dto?.blockBrowsePathPatterns ?? fallback.blockBrowsePathPatterns
        )
    }
}

private extension ProfileConfig {
    init(dto: ProfileDTO?, fallback: ProfileConfig) {
        self.init(
            hideReelsTab: dto?.hideReelsTab ?? fallback.hideReelsTab,
            reelsTabSelectors: dto?.reelsTabSelectors ?? fallback.reelsTabSelectors,
            reelsTabPathPattern: nonempty(dto?.reelsTabPathPattern) ?? fallback.reelsTabPathPattern
        )
    }
}

private extension RedirectConfig {
    init(dto: RedirectDTO?, fallback: RedirectConfig) throws {
        let method = try parseEnum(dto?.method, as: RedirectMethod.self, fallback: fallback.method)
        var target = nonempty(dto?.targetPath) ?? fallback.targetPath
        if !target.hasPrefix("/") {
            target = "/" + target
        }
        target = PathNormalizer.normalize(target)
        let maxRedirects = dto?.maxRedirects ?? fallback.maxRedirects
        let windowMs = dto?.windowMs ?? fallback.windowMs
        self.init(
            targetPath: target,
            method: method,
            maxRedirects: max(1, maxRedirects),
            windowMs: max(500, windowMs)
        )
    }
}

private extension ReelsRules {
    init(dto: ReelsDTO?, fallback: ReelsRules) {
        self.init(
            blockFeed: dto?.blockFeed ?? fallback.blockFeed,
            feedPathPattern: nonempty(dto?.feedPathPattern) ?? fallback.feedPathPattern,
            allowReelPathPattern: nonempty(dto?.allowReelPathPattern) ?? fallback.allowReelPathPattern,
            allowUserReelPathPattern: nonempty(dto?.allowUserReelPathPattern) ?? fallback.allowUserReelPathPattern,
            allowIdPaths: dto?.allowIdPaths ?? fallback.allowIdPaths,
            idPathPattern: nonempty(dto?.idPathPattern) ?? fallback.idPathPattern,
            postPathPattern: nonempty(dto?.postPathPattern) ?? fallback.postPathPattern
        )
    }
}

private extension ReelLockConfig {
    init(dto: ReelLockDTO?, fallback: ReelLockConfig) {
        let threshold = dto?.swipeThresholdPx ?? fallback.swipeThresholdPx
        self.init(
            enabled: dto?.enabled ?? fallback.enabled,
            viewerSelectors: dto?.viewerSelectors ?? fallback.viewerSelectors,
            scrollContainerSelectors: dto?.scrollContainerSelectors ?? fallback.scrollContainerSelectors,
            swipeThresholdPx: (threshold < 0 || threshold > 400) ? fallback.swipeThresholdPx : threshold,
            lockWheel: dto?.lockWheel ?? fallback.lockWheel,
            hideNextPrev: dto?.hideNextPrev ?? fallback.hideNextPrev,
            nextPrevSelectors: dto?.nextPrevSelectors ?? fallback.nextPrevSelectors,
            forceReelIdBack: dto?.forceReelIdBack ?? fallback.forceReelIdBack,
            restoreScrollOnClose: dto?.restoreScrollOnClose ?? fallback.restoreScrollOnClose,
            allowScrollSelectors: dto?.allowScrollSelectors ?? fallback.allowScrollSelectors,
            videoSelectors: dto?.videoSelectors ?? fallback.videoSelectors
        )
    }
}

private func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func parseEnum<T: RawRepresentable>(_ raw: String?, as type: T.Type, fallback: T) throws -> T where T.RawValue == String {
    guard let raw else { return fallback }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return fallback
    }
    guard let value = T(rawValue: trimmed) else {
        throw ConfigError.invalidEnum(trimmed)
    }
    return value
}
