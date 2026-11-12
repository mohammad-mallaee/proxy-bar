import Foundation

// MARK: - Proxy settings

enum ProxyScheme: String, Codable, CaseIterable, Identifiable {
    case http
    case socks5

    var id: String { rawValue }
    var label: String {
        switch self {
        case .http: return "HTTP"
        case .socks5: return "SOCKS5"
        }
    }
}

struct ProxySettings: Codable, Equatable {
    var scheme: ProxyScheme = .http
    var host: String = "localhost"
    var port: Int = 10808
    /// Comma-separated hosts that should bypass the proxy.
    var noProxy: String = "localhost,127.0.0.1,::1"
    /// Also set http_proxy / https_proxy / no_proxy (some tools only read lowercase).
    var lowercaseVariables = true
    /// Makes Node.js 24+ honor the proxy variables for fetch().
    var nodeUseEnvProxy = true
    /// Ask before launching an app while the proxy port isn't reachable.
    var warnWhenProxyDown = true
    /// After quitting an app from ProxyBar, kill its leftover processes automatically.
    var cleanupAfterQuit = false

    init() {}

    // Decode field by field so settings saved by older versions keep loading
    // when new fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProxySettings()
        scheme = try c.decodeIfPresent(ProxyScheme.self, forKey: .scheme) ?? d.scheme
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        noProxy = try c.decodeIfPresent(String.self, forKey: .noProxy) ?? d.noProxy
        lowercaseVariables = try c.decodeIfPresent(Bool.self, forKey: .lowercaseVariables) ?? d.lowercaseVariables
        nodeUseEnvProxy = try c.decodeIfPresent(Bool.self, forKey: .nodeUseEnvProxy) ?? d.nodeUseEnvProxy
        warnWhenProxyDown = try c.decodeIfPresent(Bool.self, forKey: .warnWhenProxyDown) ?? d.warnWhenProxyDown
        cleanupAfterQuit = try c.decodeIfPresent(Bool.self, forKey: .cleanupAfterQuit) ?? d.cleanupAfterQuit
    }

    var url: String { "\(scheme.rawValue)://\(host):\(port)" }

    var noProxyList: [String] {
        noProxy.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Environment variables passed to every launched app.
    var environment: [String: String] {
        var env = ["HTTP_PROXY": url, "HTTPS_PROXY": url, "NO_PROXY": noProxyList.joined(separator: ",")]
        if scheme == .socks5 { env["ALL_PROXY"] = url }
        if lowercaseVariables {
            for (key, value) in env { env[key.lowercased()] = value }
        }
        if nodeUseEnvProxy { env["NODE_USE_ENV_PROXY"] = "1" }
        return env
    }

    /// Chromium switches. Electron apps ignore HTTP(S)_PROXY for their own web traffic.
    var chromiumArguments: [String] {
        ["--proxy-server=\(url)", "--proxy-bypass-list=" + noProxyList.joined(separator: ";")]
    }

    /// One line to paste into a terminal.
    var shellExports: String {
        "export " + environment.sorted { $0.key < $1.key }
            .map { "\($0.key)='\($0.value)'" }
            .joined(separator: " ")
    }

    /// A URLSession configuration that routes through this proxy (for the connection test).
    func urlSessionConfiguration() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        switch scheme {
        case .http:
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        case .socks5:
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: host,
                kCFNetworkProxiesSOCKSPort as String: port,
            ]
        }
        return cfg
    }
}

// MARK: - Managed apps

struct ManagedApp: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var bundleID: String
    var name: String
    /// Pass --proxy-server to Chromium/Electron apps.
    var useChromiumProxyFlag = false
    /// Launch this app through the proxy when ProxyBar starts.
    var launchOnStart = false
    /// Comma-separated executable names that count as leftovers once the app has quit.
    var cleanupPatterns = ""
    /// Extra KEY=VALUE lines added to the environment for this app only.
    var extraEnvironment = ""

    init(path: String, bundleID: String, name: String) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try c.decode(String.self, forKey: .path)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        name = try c.decode(String.self, forKey: .name)
        useChromiumProxyFlag = try c.decodeIfPresent(Bool.self, forKey: .useChromiumProxyFlag) ?? false
        launchOnStart = try c.decodeIfPresent(Bool.self, forKey: .launchOnStart) ?? false
        cleanupPatterns = try c.decodeIfPresent(String.self, forKey: .cleanupPatterns) ?? ""
        extraEnvironment = try c.decodeIfPresent(String.self, forKey: .extraEnvironment) ?? ""
    }

    /// Builds an entry from an .app bundle on disk.
    static func make(from url: URL) -> ManagedApp? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        var app = ManagedApp(path: url.path, bundleID: bundleID, name: name)
        app.useChromiumProxyFlag = isElectron(path: url.path)
        return app
    }

    static func isElectron(path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/Contents/Frameworks/Electron Framework.framework")
    }

    /// Apps added on first run, if they're installed.
    static func defaults() -> [ManagedApp] {
        let candidates: [(String, String)] = [
            ("/Applications/T3 Code (Beta).app", "agy_acp_server, localharness_external"),
            ("/Applications/Claude.app", ""),
        ]
        return candidates.compactMap { path, cleanup in
            guard FileManager.default.fileExists(atPath: path),
                  var app = make(from: URL(fileURLWithPath: path)) else { return nil }
            app.cleanupPatterns = cleanup
            return app
        }
    }

    var cleanupPatternList: [String] {
        cleanupPatterns.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var extraEnvironmentDict: [String: String] {
        var env: [String: String] = [:]
        for line in extraEnvironment.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { env[key] = String(trimmed[trimmed.index(after: eq)...]) }
        }
        return env
    }

    /// A process left behind after the app quit: re-parented to launchd (ppid 1)
    /// and either living inside the app bundle or matching a cleanup pattern.
    func isLeftover(_ p: ProcInfo) -> Bool {
        guard p.ppid == 1 else { return false }
        if p.path.hasPrefix(path + "/") { return true }
        return cleanupPatternList.contains { p.name.localizedCaseInsensitiveContains($0) }
    }
}
