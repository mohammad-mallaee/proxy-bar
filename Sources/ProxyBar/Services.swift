import Foundation

/// A web service whose availability depends on where your connection exits.
///
/// A check sends an unauthenticated GET to `url` and decides:
/// - **blocked** if the response matches the block signature:
///   - statuses only: the HTTP status is one of `blockedStatuses`
///   - markers only: the final URL or body contains one of `blockedMarkers`
///   - both: the status matches *and* a marker is found
/// - **available** for any other HTTP response (401 "missing API key" is the normal answer)
/// - **unreachable** if no HTTP response arrives (timeout, DNS, TLS, refused…)
struct ServiceCheck: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var url: String
    /// Comma-separated HTTP status codes, e.g. "403, 451".
    var blockedStatuses: String
    /// Comma-separated, case-insensitive substrings searched in the final URL and the body.
    var blockedMarkers: String
    var enabled = true

    init(id: String, name: String, url: String, blockedStatuses: String, blockedMarkers: String = "") {
        self.id = id
        self.name = name
        self.url = url
        self.blockedStatuses = blockedStatuses
        self.blockedMarkers = blockedMarkers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        blockedStatuses = try c.decodeIfPresent(String.self, forKey: .blockedStatuses) ?? ""
        blockedMarkers = try c.decodeIfPresent(String.self, forKey: .blockedMarkers) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    var statusList: [Int] {
        blockedStatuses.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    var markerList: [String] {
        blockedMarkers.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func custom() -> ServiceCheck {
        ServiceCheck(id: UUID().uuidString, name: "New service", url: "https://", blockedStatuses: "403")
    }

    /// Built-in checks. Signatures were taken from real responses: a direct
    /// connection from a blocked region vs. the same request through a proxy.
    ///
    /// | Service | Blocked region | Allowed region |
    /// |---|---|---|
    /// | Google (Gemini, Antigravity, Firebase) | 403 HTML "Error 403 (Forbidden)" | 200/404, or JSON 403 "unregistered callers" |
    /// | Anthropic API | 403 "Request not allowed" | 401 "x-api-key header is required" |
    /// | OpenAI API | 403 unsupported_country_region_territory | 401 |
    /// | xAI API | 403 "not available in your region" | 401 |
    /// | OpenRouter | 403 "Access denied by security policy" | 401 |
    /// | Groq | 403 "Forbidden" / "Access denied" (also blocks many VPN IPs) | 401 |
    /// | Docker Hub registry | 403 "RBAC: access denied" | 401 |
    static let presets: [ServiceCheck] = [
        ServiceCheck(id: "gemini", name: "Gemini API",
                     url: "https://generativelanguage.googleapis.com/v1beta/models",
                     blockedStatuses: "403", blockedMarkers: "Error 403 (Forbidden)"),
        ServiceCheck(id: "antigravity", name: "Antigravity / Code Assist",
                     url: "https://cloudcode-pa.googleapis.com/",
                     blockedStatuses: "403", blockedMarkers: "Error 403 (Forbidden)"),
        ServiceCheck(id: "google-dev", name: "Google developer sites",
                     url: "https://firebase.google.com/",
                     blockedStatuses: "403", blockedMarkers: "Error 403 (Forbidden)"),
        ServiceCheck(id: "claude", name: "Claude (Anthropic)",
                     url: "https://api.anthropic.com/v1/models",
                     blockedStatuses: "403"),
        ServiceCheck(id: "openai", name: "OpenAI / ChatGPT / Codex",
                     url: "https://api.openai.com/v1/models",
                     blockedStatuses: "403"),
        ServiceCheck(id: "xai", name: "Grok (xAI)",
                     url: "https://api.x.ai/v1/models",
                     blockedStatuses: "403"),
        ServiceCheck(id: "openrouter", name: "OpenRouter",
                     url: "https://openrouter.ai/api/v1/auth/key",
                     blockedStatuses: "403"),
        ServiceCheck(id: "groq", name: "Groq",
                     url: "https://api.groq.com/openai/v1/models",
                     blockedStatuses: "403"),
        ServiceCheck(id: "docker", name: "Docker Hub",
                     url: "https://registry-1.docker.io/v2/",
                     blockedStatuses: "403"),
    ]
}

enum ServiceVerdict: Equatable {
    case available(status: Int, ms: Double)
    case blocked(reason: String)
    case unreachable(reason: String)

    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var detail: String {
        switch self {
        case .available(let status, let ms): return "Available (HTTP \(status), \(Int(ms)) ms)"
        case .blocked(let reason): return "Blocked: \(reason)"
        case .unreachable(let reason): return "Unreachable: \(reason)"
        }
    }
}

struct ServiceResult: Equatable {
    var viaProxy: ServiceVerdict?
    var direct: ServiceVerdict?
}

/// Known apps: suggested in first-run setup, with the services they depend on.
enum KnownApps {
    static let catalog: [(file: String, services: [String], cleanup: String)] = [
        ("T3 Code (Beta).app", ["claude", "gemini", "antigravity", "openai"], "agy_acp_server, localharness_external"),
        ("T3 Code.app", ["claude", "gemini", "antigravity", "openai"], "agy_acp_server, localharness_external"),
        ("Claude.app", ["claude"], ""),
        ("ChatGPT.app", ["openai"], ""),
        ("Codex.app", ["openai"], ""),
        ("Visual Studio Code.app", ["openai", "claude"], ""),
        ("Cursor.app", ["openai", "claude"], ""),
        ("Windsurf.app", ["openai", "claude"], ""),
        ("Zed.app", ["claude", "openai", "gemini"], ""),
        ("Antigravity.app", ["gemini", "antigravity"], ""),
        ("Antigravity Tools.app", ["gemini", "antigravity"], ""),
        ("Kiro.app", ["claude"], ""),
        ("Android Studio.app", ["google-dev", "gemini"], ""),
        ("Docker.app", ["docker"], ""),
        ("OrbStack.app", ["docker"], ""),
    ]

    static func entry(forPath path: String) -> (file: String, services: [String], cleanup: String)? {
        let file = (path as NSString).lastPathComponent
        return catalog.first { $0.file == file }
    }

    /// Installed apps from the catalog, in catalog order.
    static func installed() -> [URL] {
        let dirs = ["/Applications", NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var urls: [URL] = []
        for entry in catalog {
            for dir in dirs {
                let path = dir + "/" + entry.file
                if FileManager.default.fileExists(atPath: path), seen.insert(entry.file).inserted {
                    urls.append(URL(fileURLWithPath: path))
                }
            }
        }
        return urls
    }
}
