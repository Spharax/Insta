import Foundation

/// Hosts that may load inside the web view. Everything else http(s) opens in Safari.
/// Non-http schemes other than mailto, tel, and sms are cancelled so `instagram://`
/// cannot launch the real Instagram app.
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

    /// Google and Apple sign-in stay in this web view so the session can return.
    /// A link to these hosts from a bio also stays in the web view.
    static let signInDomains: [String] = [
        "google.com",
        "googleapis.com",
        "gstatic.com",
        "googleusercontent.com",
        "apple.com",
        "icloud.com"
    ]

    static func isAllowed(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        for domain in inAppDomains + signInDomains {
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
