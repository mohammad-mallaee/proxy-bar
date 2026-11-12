import Foundation
import Network
import os

/// Checks whether something is listening on host:port.
enum TCPProbe {
    /// Returns the connect time in milliseconds, or nil if the port isn't reachable.
    static func connect(host: String, port: Int, timeout: TimeInterval = 2) async -> Double? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), !host.isEmpty else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let start = Date()
        let done = OSAllocatedUnfairLock(initialState: false)

        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ value: Double?) {
                let first = done.withLock { finished -> Bool in
                    defer { finished = true }
                    return !finished
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(Date().timeIntervalSince(start) * 1000)
                case .failed, .waiting: finish(nil) // .waiting = refused / unreachable
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}

struct ExitInfo: Equatable {
    var ip: String?
    var country: String?
}

/// Result of a full region check.
struct RegionReport: Equatable {
    var date = Date()
    var googleMs: Double?
    var proxyExit: ExitInfo?
    var directExit: ExitInfo?
    /// Keyed by ServiceCheck.id.
    var results: [String: ServiceResult] = [:]
    var errors: [String] = []

    func result(for id: String) -> ServiceResult? { results[id] }
}

/// Runs the region check: Google reachability, exit IP/country, and every
/// enabled service, through the proxy and (optionally) directly.
enum RegionChecker {
    static let userAgent = "ProxyBar/0.2 (macOS)"

    static func run(settings: ProxySettings, services: [ServiceCheck], includeDirect: Bool) async -> RegionReport {
        let proxied = URLSession(configuration: settings.urlSessionConfiguration())
        let direct = URLSession(configuration: ProxySettings.directSessionConfiguration())
        defer {
            proxied.invalidateAndCancel()
            direct.invalidateAndCancel()
        }

        async let google = googleCheck(proxied)
        async let proxyExit = exitInfo(proxied)
        async let directExit: ExitInfo? = includeDirect ? exitInfo(direct) : nil

        let results = await withTaskGroup(of: (String, Bool, ServiceVerdict).self) { group in
            for service in services {
                group.addTask { (service.id, true, await judge(service, session: proxied)) }
                if includeDirect {
                    group.addTask { (service.id, false, await judge(service, session: direct)) }
                }
            }
            var dict: [String: ServiceResult] = [:]
            for await (id, viaProxy, verdict) in group {
                if viaProxy { dict[id, default: ServiceResult()].viaProxy = verdict }
                else { dict[id, default: ServiceResult()].direct = verdict }
            }
            return dict
        }

        var report = RegionReport()
        let (googleMs, googleError) = await google
        report.googleMs = googleMs
        if let googleError { report.errors.append(googleError) }
        report.proxyExit = await proxyExit
        report.directExit = await directExit
        if report.proxyExit == nil { report.errors.append("Couldn't get the exit IP through the proxy") }
        report.results = results
        report.date = Date()
        return report
    }

    static func judge(_ service: ServiceCheck, session: URLSession) async -> ServiceVerdict {
        guard let url = URL(string: service.url), url.scheme?.hasPrefix("http") == true else {
            return .unreachable(reason: "invalid URL")
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            let finalURL = http?.url?.absoluteString ?? ""
            let body = String(decoding: data.prefix(64_000), as: UTF8.self)

            let statuses = service.statusList
            let markers = service.markerList
            let marker = markers.first {
                body.localizedCaseInsensitiveContains($0) || finalURL.localizedCaseInsensitiveContains($0)
            }
            let statusHit = statuses.contains(code)
            let blocked: Bool
            switch (statuses.isEmpty, markers.isEmpty) {
            case (true, true): blocked = false
            case (false, true): blocked = statusHit
            case (true, false): blocked = marker != nil
            case (false, false): blocked = statusHit && marker != nil
            }

            if blocked { return .blocked(reason: reason(code: code, body: body, marker: marker)) }
            return .available(status: code, ms: Date().timeIntervalSince(start) * 1000)
        } catch {
            return .unreachable(reason: (error as NSError).localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func googleCheck(_ session: URLSession) async -> (Double?, String?) {
        let start = Date()
        do {
            let (_, response) = try await session.data(from: URL(string: "https://www.google.com/generate_204")!)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 204 { return (Date().timeIntervalSince(start) * 1000, nil) }
            return (nil, "Google answered HTTP \(code)")
        } catch {
            return (nil, "Google: \(error.localizedDescription)")
        }
    }

    private static func exitInfo(_ session: URLSession) async -> ExitInfo? {
        guard let (data, _) = try? await session.data(from: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!) else {
            return nil
        }
        var info = ExitInfo()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "ip" { info.ip = parts[1] }
            if parts[0] == "loc" { info.country = parts[1] }
        }
        return info
    }

    /// A short, human-readable reason: the JSON "message", the matched marker, or the HTML title.
    private static func reason(code: Int, body: String, marker: String?) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let message = findMessage(in: json) {
            return "HTTP \(code): \(message.prefix(140))"
        }
        if let marker { return "HTTP \(code): “\(marker)”" }
        if let open = body.range(of: "<title>", options: .caseInsensitive),
           let close = body.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<body.endIndex) {
            let title = body[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return "HTTP \(code): \(title.prefix(100))" }
        }
        return "HTTP \(code)"
    }

    private static func findMessage(in json: Any) -> String? {
        if let dict = json as? [String: Any] {
            for key in ["message", "error", "detail", "code"] {
                if let s = dict[key] as? String, !s.isEmpty { return s }
            }
            for value in dict.values {
                if let found = findMessage(in: value) { return found }
            }
        }
        if let array = json as? [Any] {
            for value in array {
                if let found = findMessage(in: value) { return found }
            }
        }
        return nil
    }

    static func flag(for countryCode: String) -> String {
        var s = ""
        for u in countryCode.uppercased().unicodeScalars {
            if let f = UnicodeScalar(127397 + u.value) { s.unicodeScalars.append(f) }
        }
        return s
    }
}
