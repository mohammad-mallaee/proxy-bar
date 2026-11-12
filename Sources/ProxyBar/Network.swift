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

struct ConnectionTest: Equatable {
    var googleMs: Double?
    var exitIP: String?
    var country: String?
    var errors: [String] = []
}

/// Sends real requests through the proxy: Google reachability plus exit IP / country.
enum ConnectionTester {
    static func run(settings: ProxySettings) async -> ConnectionTest {
        var result = ConnectionTest()
        let session = URLSession(configuration: settings.urlSessionConfiguration())
        defer { session.invalidateAndCancel() }

        do {
            let start = Date()
            let (_, response) = try await session.data(from: URL(string: "https://www.google.com/generate_204")!)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 204 {
                result.googleMs = Date().timeIntervalSince(start) * 1000
            } else {
                result.errors.append("Google answered HTTP \(code)")
            }
        } catch {
            result.errors.append("Google: \(error.localizedDescription)")
        }

        do {
            let (data, _) = try await session.data(from: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!)
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                if parts[0] == "ip" { result.exitIP = parts[1] }
                if parts[0] == "loc" { result.country = parts[1] }
            }
        } catch {
            result.errors.append("Exit check: \(error.localizedDescription)")
        }
        return result
    }

    static func flag(for countryCode: String) -> String {
        var s = ""
        for u in countryCode.uppercased().unicodeScalars {
            if let f = UnicodeScalar(127397 + u.value) { s.unicodeScalars.append(f) }
        }
        return s
    }
}
