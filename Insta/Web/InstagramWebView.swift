import os
import SwiftUI
import UIKit
import WebKit

struct InstagramWebView: UIViewRepresentable {
    @ObservedObject var store: ConfigStore
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    var reloadToken: Int
    var backToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView()
        context.coordinator.attach(webView)
        context.coordinator.pushConfigIfNeeded(webView)
        context.coordinator.loadInitialIfNeeded(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(webView)
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.processRestarts = 0
            if webView.url != nil {
                webView.reload()
            } else if let home = URL(string: AppConstants.homeURLString) {
                webView.load(URLRequest(url: home))
            }
        }
        if context.coordinator.lastBackToken != backToken {
            context.coordinator.lastBackToken = backToken
            context.coordinator.goBackOrHome(webView)
        }
        context.coordinator.pushConfigIfNeeded(webView)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: AppConstants.scriptHandlerName)
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: InstagramWebView
        var lastReloadToken: Int
        var lastBackToken: Int
        var processRestarts = 0

        private weak var webView: WKWebView?
        private var didStartInitialLoad = false
        private var hasCommittedFirstPage = false
        private var didAddHandler = false
        private var bridgeSource: String?
        private var cachedJSON: String?
        private var lastPushedConfig: AppConfig?
        private var lastPushedEnabled: Bool?
        private var policy: PathPolicy
        private var lastSyntheticKey = ""
        private var lastSyntheticAt = Date.distantPast
        private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "webview")

        init(parent: InstagramWebView) {
            self.parent = parent
            self.lastReloadToken = parent.reloadToken
            self.lastBackToken = parent.backToken
            self.policy = PathPolicy(config: parent.store.config)
            super.init()
        }

        func makeWebView() -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = WKWebsiteDataStore.default()
            configuration.allowsInlineMediaPlayback = true
            configuration.mediaTypesRequiringUserActionForPlayback = []
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.customUserAgent = AppConstants.defaultUserAgent
            webView.allowsBackForwardNavigationGestures = true
            #if DEBUG
            webView.isInspectable = true
            #endif
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.isOpaque = false
            webView.backgroundColor = .systemBackground
            webView.scrollView.backgroundColor = .systemBackground
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            return webView
        }

        func attach(_ webView: WKWebView) {
            let isNewWebView: Bool
            if let existing = self.webView {
                isNewWebView = existing !== webView
            } else {
                isNewWebView = true
            }
            self.webView = webView
            if webView.navigationDelegate == nil {
                webView.navigationDelegate = self
            }
            if webView.uiDelegate == nil {
                webView.uiDelegate = self
            }
            if isNewWebView {
                didAddHandler = false
            }
            guard !didAddHandler else { return }
            let proxy = ScriptMessageProxy(delegate: self)
            webView.configuration.userContentController.add(proxy, name: AppConstants.scriptHandlerName)
            didAddHandler = true
        }

        func loadInitialIfNeeded(_ webView: WKWebView) {
            guard !didStartInitialLoad else { return }
            didStartInitialLoad = true
            guard let url = URL(string: AppConstants.homeURLString) else {
                parent.isLoading = false
                parent.errorMessage = "The home URL is invalid."
                return
            }
            webView.load(URLRequest(url: url))
        }

        func goBackOrHome(_ webView: WKWebView) {
            if webView.canGoBack {
                webView.goBack()
                return
            }
            if let home = URL(string: AppConstants.homeURLString) {
                webView.load(URLRequest(url: home))
            }
        }

        func pushConfigIfNeeded(_ webView: WKWebView, forceApply: Bool = false) {
            let enabled = parent.store.rulesEnabled
            let configChanged = lastPushedConfig != parent.store.config
            if configChanged || cachedJSON == nil {
                policy = PathPolicy(config: parent.store.config)
                guard let payload = try? parent.store.config.javascriptPayload(),
                      let json = String(data: payload, encoding: .utf8) else {
                    logger.error("Could not encode rules for the page")
                    return
                }
                cachedJSON = json
            }
            guard let json = cachedJSON else { return }
            let unchanged = !configChanged && lastPushedEnabled == enabled && bridgeSource != nil
            if !unchanged {
                let loaded = bridgeSource ?? loadBridge()
                guard let source = loaded, source.isEmpty == false else {
                    logger.error("bridge.js is missing from the app bundle")
                    return
                }
                bridgeSource = source
                lastPushedConfig = parent.store.config
                lastPushedEnabled = enabled
                installScripts(on: webView, json: json, bridge: source, enabled: enabled)
            }
            if unchanged && !forceApply {
                return
            }
            let script = applyScript(json: json, enabled: enabled)
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    self.logger.debug("Page has not installed rules yet: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let frame = navigationAction.targetFrame, frame.isMainFrame == false {
                decisionHandler(.allow)
                return
            }
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let result = outcome(for: url)
            if navigationAction.targetFrame == nil {
                decisionHandler(.cancel)
                performSynthetic(result, url: url, webView: webView)
                return
            }
            switch result {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            case .load(let destination):
                decisionHandler(.cancel)
                webView.load(URLRequest(url: destination))
            case .open(let destination):
                decisionHandler(.cancel)
                UIApplication.shared.open(destination, options: [:], completionHandler: nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else {
                return nil
            }
            performSynthetic(outcome(for: url), url: url, webView: webView)
            return nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            if !hasCommittedFirstPage {
                parent.errorMessage = nil
                parent.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasCommittedFirstPage = true
            processRestarts = 0
            parent.isLoading = false
            parent.errorMessage = nil
            pushConfigIfNeeded(webView, forceApply: true)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleFailure(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            processRestarts += 1
            if processRestarts <= 3 {
                logger.error("Web content process ended; reloading")
                if webView.url != nil {
                    webView.reload()
                } else if let home = URL(string: AppConstants.homeURLString) {
                    webView.load(URLRequest(url: home))
                }
            } else {
                parent.isLoading = false
                parent.errorMessage = "Instagram's page process stopped repeatedly. Tap Retry."
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == AppConstants.scriptHandlerName else { return }
            guard let body = message.body as? [String: Any] else { return }
            let text = body["message"] as? String ?? ""
            let clipped = String(text.prefix(180))
            logger.info("\(clipped, privacy: .public)")
        }

        private func handleFailure(_ error: Error) {
            if isBenign(error) {
                return
            }
            parent.isLoading = false
            parent.errorMessage = error.localizedDescription
            logger.error("Navigation failed: \(error.localizedDescription, privacy: .public)")
        }

        private func isBenign(_ error: Error) -> Bool {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return true
            }
            // WKError.Code.frameLoadInterruptedByPolicyChange is 102.
            // The Swift case is not in the Xcode 26 overlay, so compare the code.
            if nsError.domain == WKErrorDomain && nsError.code == 102 {
                return true
            }
            return false
        }

        private enum Outcome {
            case allow
            case cancel
            case load(URL)
            case open(URL)
        }

        private func outcome(for url: URL) -> Outcome {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "about" || scheme == "blob" || scheme == "data" {
                return .allow
            }
            if scheme == "javascript" {
                return .cancel
            }
            if scheme != "http" && scheme != "https" {
                if scheme == "mailto" || scheme == "tel" || scheme == "sms" {
                    return .open(url)
                }
                return .cancel
            }
            if !HostAllowlist.isAllowed(url.host) {
                return .open(url)
            }
            if !HostAllowlist.isInstagramSite(url.host) {
                return .allow
            }
            if !parent.store.rulesEnabled {
                return .allow
            }
            switch policy.decision(forPath: url.path) {
            case .allow:
                return .allow
            case .redirectHome:
                if let home = policy.redirectURL() {
                    return .load(home)
                }
                return .allow
            }
        }

        private func performSynthetic(_ outcome: Outcome, url: URL, webView: WKWebView) {
            let key: String
            switch outcome {
            case .allow:
                key = "allow:" + url.absoluteString
            case .cancel:
                return
            case .load(let destination):
                key = "load:" + destination.absoluteString
            case .open(let destination):
                key = "open:" + destination.absoluteString
            }
            let now = Date()
            if key == lastSyntheticKey && now.timeIntervalSince(lastSyntheticAt) < 0.8 {
                return
            }
            lastSyntheticKey = key
            lastSyntheticAt = now
            switch outcome {
            case .allow:
                webView.load(URLRequest(url: url))
            case .load(let destination):
                webView.load(URLRequest(url: destination))
            case .open(let destination):
                UIApplication.shared.open(destination, options: [:], completionHandler: nil)
            case .cancel:
                break
            }
        }

        private func loadBridge() -> String? {
            guard let url = Bundle.main.url(forResource: AppConstants.bridgeResourceName, withExtension: "js") else {
                return nil
            }
            return try? String(contentsOf: url, encoding: .utf8)
        }

        private func installScripts(on webView: WKWebView, json: String, bridge: String, enabled: Bool) {
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            // forMainFrameOnly is true: captcha and login widgets live in iframes.
            // Redirecting those frames would break sign-in. Instagram's UI is the top frame.
            let configScript = WKUserScript(
                source: configSource(json: json, enabled: enabled),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            let bridgeScript = WKUserScript(
                source: bridge,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            controller.addUserScript(configScript)
            controller.addUserScript(bridgeScript)
        }

        private func configSource(json: String, enabled: Bool) -> String {
            let literal = JavaScriptLiteral.string(json)
            let flag = enabled ? "true" : "false"
            var source = "window.__INSTA_ENABLED=\(flag);window.__INSTA_CONFIG=JSON.parse(\(literal));"
            if enabled {
                source += "try{var p=location.pathname||\"/\";if(p.length>1&&p.charAt(p.length-1)===\"/\"){p=p.slice(0,-1);}if(p===\"\"||p===\"/\"){document.documentElement.classList.add(\"insta-home\");}}catch(e){}"
            }
            return source
        }

        private func applyScript(json: String, enabled: Bool) -> String {
            let literal = JavaScriptLiteral.string(json)
            let flag = enabled ? "true" : "false"
            return "try{if(window.__instaApplyConfig){window.__instaApplyConfig(JSON.parse(\(literal)));}if(window.__instaSetEnabled){window.__instaSetEnabled(\(flag));}}catch(e){}"
        }
    }
}
