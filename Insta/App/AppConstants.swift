import Foundation

enum AppConstants {
    static let appName = "Insta"
    static let bundleIdentifier = "com.personal.insta"

    /// First page loaded. Home, not the DM inbox.
    static let homeURLString = "https://www.instagram.com/"

    /// Public raw URL. The repo must stay public or this fetch will 404.
    /// After this URL is real, edit Config/remote-config.example.json and push;
    /// the running app picks it up without another rebuild.
    static let remoteConfigURLString = "https://raw.githubusercontent.com/Spharax/Insta/main/Config/remote-config.example.json"

    /// Mobile Safari user agent so Instagram serves its phone layout.
    /// Update this constant when Safari's iPhone UA changes. Instagram may
    /// otherwise send the desktop site, and the selectors in the config will miss.
    static let defaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    static let supportedSchemaVersion = 1
    static let scriptHandlerName = "instaBridge"
    static let bundledConfigName = "fallback-config"
    static let bridgeResourceName = "bridge"
    static let rulesEnabledDefaultsKey = "insta.rulesEnabled"
}
