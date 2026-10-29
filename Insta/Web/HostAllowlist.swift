import Foundation

/// Hosts that may load inside the web view. Everything else opens in Safari.
/// Matching is exact host or a dot-boundary subdomain, so `notinstagram.com` does not match.
enum HostAllowlist {
    static let inAppDomains: [String] = [
        "instagram.com",
        "cdninstagram.com",
        "facebook.com",
        "fbcdn.net",
        "facebook.net",
        "fb.com",
        "fbsbx.com",
        "meta.com",
        "messenger.com",
        "threads.net"
    ]

    static func isAllowed(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        for domain in inAppDomains {
            if host == domain || host.hasSuffix("." + domain) {
                return true
            }
        }
        return false
    }

    /// Path rules apply only on the Instagram site, not on CDNs or Facebook login.
    static func isInstagramSite(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "instagram.com" || host.hasSuffix(".instagram.com")
    }
}
