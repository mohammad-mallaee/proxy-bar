import AppKit

enum TerminalApp: String, Codable, CaseIterable, Identifiable {
    case terminal
    case iterm

    var id: String { rawValue }

    var name: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm"
        }
    }

    var bundleID: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        }
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    static var installed: [TerminalApp] { allCases.filter { $0.appURL != nil } }
}

/// Opens a terminal window whose shell has the proxy variables set.
///
/// Writes a one-shot `.command` script (cd, export, then `exec` your login
/// shell) and opens it with the chosen terminal. The script deletes itself
/// as soon as it starts. No Apple Events / automation permission needed.
enum TerminalLauncher {
    enum LaunchError: LocalizedError {
        case notInstalled(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let name): return "\(name) isn't installed."
            }
        }
    }

    static func open(folder: URL, settings: ProxySettings, terminal: TerminalApp) async throws {
        guard let appURL = terminal.appURL else { throw LaunchError.notInstalled(terminal.name) }

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProxyBar/terminal", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        removeStaleScripts(in: dir)

        let script = dir.appendingPathComponent("proxybar-\(UUID().uuidString.prefix(8)).command")
        try scriptContents(folder: folder, settings: settings)
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        _ = try await NSWorkspace.shared.open([script], withApplicationAt: appURL,
                                              configuration: NSWorkspace.OpenConfiguration())
    }

    static func scriptContents(folder: URL, settings: ProxySettings) -> String {
        let display = folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        var lines = [
            "#!/bin/sh",
            "rm -f -- \"$0\"",
            "cd -- \(shellQuote(folder.path)) || exit 1",
        ]
        for (key, value) in settings.environment.sorted(by: { $0.key < $1.key }) {
            lines.append("export \(key)=\(shellQuote(value))")
        }
        lines += [
            "clear",
            "printf '\\033[2m[ProxyBar] %s · proxy %s\\033[0m\\n' \(shellQuote(display)) \(shellQuote(settings.url))",
            "exec \"${SHELL:-/bin/zsh}\" -l",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// Scripts normally delete themselves; this catches any that never ran.
    private static func removeStaleScripts(in dir: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-3600)
        for file in files where file.pathExtension == "command" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}
