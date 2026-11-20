import Foundation

@main
struct RegressionChecks {
    static func main() async throws {
        checkCleanupCandidates()
        try checkProcessIdentity()
        try checkDirectComparisonPreference()
        await checkOverlappingOperations()
        print("Passed all ProxyBar regression checks.")
    }

    static func checkCleanupCandidates() {
        var app = ManagedApp(path: "/Applications/Example.app", bundleID: "example.app", name: "Example")
        app.cleanupPatterns = "worker"
        let bundled = ProcInfo(pid: 10, ppid: 1, path: "\(app.path)/Contents/MacOS/helper",
                               startedAtSeconds: 1, startedAtMicroseconds: 0)
        let external = ProcInfo(pid: 11, ppid: 1, path: "\(app.path)-other/worker",
                                startedAtSeconds: 1, startedAtMicroseconds: 0)
        let child = ProcInfo(pid: 12, ppid: 10, path: "\(app.path)/Contents/MacOS/worker",
                             startedAtSeconds: 1, startedAtMicroseconds: 0)

        precondition(app.isBundleLeftover(bundled))
        precondition(!app.isNameOnlyLeftover(bundled))
        precondition(!app.isBundleLeftover(external) && app.isNameOnlyLeftover(external))
        precondition(!app.isLeftover(child))
    }

    static func checkProcessIdentity() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["20"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }

        guard let observed = ProcessInspector.userProcesses().first(where: { $0.pid == child.processIdentifier }) else {
            preconditionFailure("Could not inspect the test child")
        }
        // Signal 0 performs a live existence and permission check without delivering a signal.
        precondition(ProcessInspector.signal(0, to: observed))
        let stale = ProcInfo(pid: observed.pid, ppid: observed.ppid, path: observed.path,
                             startedAtSeconds: observed.startedAtSeconds - 1,
                             startedAtMicroseconds: observed.startedAtMicroseconds)
        precondition(!ProcessInspector.signal(0, to: stale), "A different start time must reject a reused PID")
    }

    static func checkDirectComparisonPreference() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(ProxySettings.self, from: Data("{}".utf8))
        let enabled = try decoder.decode(ProxySettings.self, from: Data(#"{"checkDirectToo":true}"#.utf8))
        let disabled = try decoder.decode(ProxySettings.self, from: Data(#"{"checkDirectToo":false}"#.utf8))
        precondition(!ProxySettings().checkDirectToo && !legacy.checkDirectToo)
        precondition(enabled.checkDirectToo && !disabled.checkDirectToo)
    }

    @MainActor
    static func checkOverlappingOperations() async {
        let operations = AppOperations()
        let bundleID = "example.app"
        let (started, startSignal) = AsyncStream<Void>.makeStream()
        var resumeFirst: CheckedContinuation<Void, Never>?
        let first = Task {
            await operations.run(for: bundleID) {
                await withCheckedContinuation { continuation in
                    resumeFirst = continuation
                    startSignal.yield(())
                    startSignal.finish()
                }
                return true
            }
        }

        for await _ in started {
            precondition(operations.active.contains(bundleID))
            let overlapping = await operations.run(for: bundleID) { false }
            precondition(overlapping == nil)
            let unrelated = await operations.run(for: "other.app") { true }
            precondition(unrelated == true)
        }
        resumeFirst?.resume()

        let result = await first.value
        precondition(result == true && operations.active.isEmpty)
        let next = await operations.run(for: bundleID) { true }
        precondition(next == true)
    }
}
