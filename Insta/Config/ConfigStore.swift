import Combine
import Foundation
import os

/// Loads rules from cache, then the bundled file, then refreshes from the remote URL.
/// Call `refreshFromRemote()` on the main thread. The URLSession callback hops back to main.
final class ConfigStore: ObservableObject {
    @Published private(set) var config: AppConfig
    @Published private(set) var sourceDescription: String
    @Published private(set) var statusMessage: String
    @Published var rulesEnabled: Bool

    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "config")
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)

        let bundled = ConfigStore.loadBundled()
        var initialConfig = bundled.config
        var initialSource = bundled.source
        var initialStatus = bundled.status
        ConfigStore.applyCache(config: &initialConfig, source: &initialSource, status: &initialStatus)
        config = initialConfig
        sourceDescription = initialSource
        statusMessage = initialStatus

        let stored = UserDefaults.standard.object(forKey: AppConstants.rulesEnabledDefaultsKey) as? Bool
        rulesEnabled = stored ?? true
    }

    func refreshFromRemote() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.refreshFromRemote()
            }
            return
        }
        guard let url = validatedRemoteURL() else { return }
        statusMessage = "Refreshing rules…"
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let outcome = ConfigStore.interpret(data: data, response: response, error: error)
            DispatchQueue.main.async {
                self?.apply(outcome)
            }
        }
        task.resume()
    }

    private func validatedRemoteURL() -> URL? {
        let raw = AppConstants.remoteConfigURLString
        if raw.contains("YOUR_USER") || raw.contains("YOUR_REPO") {
            statusMessage = "Remote URL is still the placeholder in AppConstants.swift. Using \(sourceDescription) rules."
            logger.info("Remote config URL is the placeholder; fetch skipped")
            return nil
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" else {
            statusMessage = "Remote config URL must be https. Kept \(sourceDescription) rules."
            logger.error("Remote config URL rejected")
            return nil
        }
        return url
    }

    private func apply(_ outcome: FetchOutcome) {
        switch outcome {
        case .loaded(let remote):
            config = remote
            sourceDescription = "remote"
            statusMessage = "Loaded remote config \(remote.configVersion)."
            saveCache(remote)
            logger.info("Applied remote config \(remote.configVersion, privacy: .public)")
        case .failed(let message):
            statusMessage = message
            logger.error("\(message, privacy: .public)")
        }
    }

    private func saveCache(_ config: AppConfig) {
        guard let url = ConfigStore.cacheFileURL() else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: url, options: [.atomic])
        } catch {
            logger.error("Could not write the config cache")
        }
    }

    private static func loadBundled() -> (config: AppConfig, source: String, status: String) {
        let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "config")
        guard let url = Bundle.main.url(forResource: AppConstants.bundledConfigName, withExtension: "json") else {
            logger.error("Bundled fallback-config.json is missing")
            return (AppConfig.fallback, "hardcoded", "Bundled config missing. Using built-in rules.")
        }
        do {
            let data = try Data(contentsOf: url)
            let config = try AppConfig.decodeAndValidate(from: data)
            return (config, "bundled", "Using bundled config \(config.configVersion).")
        } catch {
            logger.error("Bundled config invalid: \(error.localizedDescription, privacy: .public)")
            return (AppConfig.fallback, "hardcoded", "Bundled config invalid. Using built-in rules.")
        }
    }

    private static func applyCache(config: inout AppConfig, source: inout String, status: inout String) {
        guard let url = cacheFileURL() else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let cached = try AppConfig.decodeAndValidate(from: data)
            config = cached
            source = "cache"
            status = "Loaded cached config \(cached.configVersion)."
        } catch {
            Logger(subsystem: AppConstants.bundleIdentifier, category: "config")
                .error("Ignored unreadable config cache")
        }
    }

    private static func cacheFileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = base.appendingPathComponent("Insta", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return folder.appendingPathComponent("config-cache.json")
    }

    private enum FetchOutcome {
        case loaded(AppConfig)
        case failed(String)
    }

    private static func interpret(data: Data?, response: URLResponse?, error: Error?) -> FetchOutcome {
        if let error {
            return .failed("Remote config fetch failed (\(error.localizedDescription)). Kept the current rules.")
        }
        guard let data, let http = response as? HTTPURLResponse else {
            return .failed("Remote config response was empty. Kept the current rules.")
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failed("Remote config HTTP \(http.statusCode). Kept the current rules.")
        }
        do {
            let config = try AppConfig.decodeAndValidate(from: data)
            return .loaded(config)
        } catch let configError as ConfigError {
            return .failed("Remote config rejected (\(configError.userFacing)). Kept the current rules.")
        } catch {
            return .failed("Remote config rejected. Kept the current rules.")
        }
    }
}
