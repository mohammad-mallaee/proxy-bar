import Observation

/// Keeps a single app operation active per bundle, including across suspension points.
@MainActor
@Observable
final class AppOperations {
    private(set) var active: Set<String> = []

    func run<Result>(for bundleID: String, _ action: () async -> Result) async -> Result? {
        guard active.insert(bundleID).inserted else { return nil }
        defer { active.remove(bundleID) }
        return await action()
    }
}
