import AppKit
import Observation
import ServiceManagement

enum ProxyState: Equatable {
    case checking
    case up(ms: Double)
    case down

    var isUp: Bool {
        if case .up = self { return true }
        return false
    }
}

struct AppStatus: Equatable {
    var running = false
    /// Whether macOS let us read the running app's environment.
    var envReadable = false
    /// HTTPS_PROXY (or ALL_PROXY) the running app was started with, if any.
    var proxyValue: String?
    /// Processes left behind after the app quit.
    var leftovers: [ProcInfo] = []
}

@MainActor
@Observable
final class AppStore {
    var settings: ProxySettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
            if settings.host != oldValue.host || settings.port != oldValue.port || settings.scheme != oldValue.scheme {
                proxyState = .checking
                proxyProbeGeneration += 1
                consecutiveProxyFailures = 0
                proxyDownNotified = false
                Task { await checkProxy() }
            }
            if regionInputs != RegionInputs(settings: oldValue, services: services) {
                invalidateRegionReport()
            } else if settings.regionCheckIntervalSeconds != oldValue.regionCheckIntervalSeconds {
                scheduleNextRegionCheck()
            }
        }
    }

    var apps: [ManagedApp] {
        didSet {
            guard apps != oldValue else { return }
            persist()
            Task { await refreshApps() }
        }
    }

    var services: [ServiceCheck] {
        didSet {
            guard services != oldValue else { return }
            persist()
            if regionInputs != RegionInputs(settings: settings, services: oldValue) {
                invalidateRegionReport()
            }
        }
    }

    var proxyState: ProxyState = .checking
    var statuses: [UUID: AppStatus] = [:]
    private let appOperations = AppOperations()
    /// Status line under the app list. Clears itself after a few seconds.
    var message: String? {
        didSet {
            messageClearTask?.cancel()
            guard let current = message else { return }
            messageClearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, let self, self.message == current else { return }
                self.message = nil
            }
        }
    }
    @ObservationIgnored private var messageClearTask: Task<Void, Never>?
    /// A region check is running.
    var checking = false
    var report: RegionReport?

    // UI state for the Settings window (kept here because @State isn't available without Xcode).
    var selectedAppID: UUID?
    var selectedServiceID: String?
    var loginStatus: SMAppService.Status = SMAppService.mainApp.status
    var loginError: String?

    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var regionTimer: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var consecutiveProxyFailures = 0
    @ObservationIgnored private var proxyDownNotified = false
    @ObservationIgnored private var proxyProbeGeneration = 0
    @ObservationIgnored private var regionGeneration = 0

    private struct RegionInputs: Equatable {
        let host: String
        let port: Int
        let scheme: ProxyScheme
        let includeDirect: Bool
        let enabledServices: [ServiceCheck]

        init(settings: ProxySettings, services: [ServiceCheck]) {
            host = settings.host
            port = settings.port
            scheme = settings.scheme
            includeDirect = settings.checkDirectToo
            enabledServices = services.filter(\.enabled)
        }
    }

    private var regionInputs: RegionInputs { RegionInputs(settings: settings, services: services) }

    private enum Keys {
        static let settings = "settings.v1"
        static let apps = "apps.v1"
        static let services = "services.v1"
    }

    init() {
        let defaults = UserDefaults.standard
        settings = defaults.data(forKey: Keys.settings)
            .flatMap { try? JSONDecoder().decode(ProxySettings.self, from: $0) } ?? ProxySettings()
        apps = defaults.data(forKey: Keys.apps)
            .flatMap { try? JSONDecoder().decode([ManagedApp].self, from: $0) } ?? ManagedApp.defaults()
        services = defaults.data(forKey: Keys.services)
            .flatMap { try? JSONDecoder().decode([ServiceCheck].self, from: $0) } ?? ServiceCheck.presets
        start()
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Keys.settings) }
        if let data = try? JSONEncoder().encode(apps) { defaults.set(data, forKey: Keys.apps) }
        if let data = try? JSONEncoder().encode(services) { defaults.set(data, forKey: Keys.services) }
    }

    // MARK: - Background refresh

    private func start() {
        Notifier.shared.setUp()
        if !OnboardingController.isDone {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard let self else { return }
                OnboardingController.shared.show(store: self)
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refreshApps() }
            })
        }

        loopTask = Task { [weak self] in
            await self?.checkProxy()
            await self?.refreshApps()
            await self?.launchStartupApps()
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                tick += 1
                await self.refreshApps()
                if tick % 3 == 0 { await self.checkProxy() }
            }
        }
    }

    func checkProxy() async {
        proxyProbeGeneration += 1
        let generation = proxyProbeGeneration
        let ms = await TCPProbe.connect(host: settings.host, port: settings.port)
        guard generation == proxyProbeGeneration else { return }
        let newState: ProxyState = ms.map { .up(ms: $0) } ?? .down
        let wasUp = proxyState.isUp
        if newState != proxyState { proxyState = newState }
        // Check when the proxy first answers and whenever it comes back.
        if !wasUp && newState.isUp && !checking {
            Task { await runRegionCheck(automatic: true) }
        } else if wasUp && !newState.isUp {
            scheduleNextRegionCheck()
        }
        handleProxyNotifications(isUp: newState.isUp)
    }

    /// Notifies after two failed checks in a row (so a quick proxy restart stays quiet),
    /// and again when the proxy answers after a "down" notification.
    private func handleProxyNotifications(isUp: Bool) {
        let endpoint = "\(settings.host):\(settings.port)"
        if isUp {
            consecutiveProxyFailures = 0
            if proxyDownNotified {
                proxyDownNotified = false
                if settings.notifyProxyUp {
                    Notifier.shared.post(title: "Proxy is back", body: "\(endpoint) is answering again.")
                }
            }
            return
        }

        consecutiveProxyFailures += 1
        guard consecutiveProxyFailures == 2, !proxyDownNotified, settings.notifyProxyDown else { return }
        let users = appsUsingProxy().map(\.name)
        if settings.notifyOnlyWhenAppsUseProxy && users.isEmpty { return }
        proxyDownNotified = true
        let affected = users.isEmpty ? "" : " \(users.joined(separator: ", ")) can't connect until it's back."
        Notifier.shared.post(title: "Proxy is down", body: "Nothing is answering on \(endpoint).\(affected)")
    }

    /// Managed apps that are running with a proxy in their environment.
    func appsUsingProxy() -> [ManagedApp] {
        apps.filter { app in
            let status = status(for: app)
            return status.running && status.proxyValue != nil
        }
    }

    func refreshApps() async {
        let snapshot = apps
        let processes = await Task.detached(priority: .utility) { ProcessInspector.userProcesses() }.value
        var result: [UUID: AppStatus] = [:]
        for app in snapshot {
            var status = AppStatus()
            let running = runningInstances(of: app)
            status.running = !running.isEmpty
            if let pid = running.first?.processIdentifier {
                if let env = ProcessInspector.environment(of: pid) {
                    status.envReadable = true
                    status.proxyValue = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
                        .compactMap { env[$0] }
                        .first { !$0.isEmpty }
                }
            } else {
                status.leftovers = processes.filter { app.isLeftover($0) }
            }
            result[app.id] = status
        }
        if result != statuses { statuses = result }
    }

    private func runningInstances(of app: ManagedApp) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).filter { !$0.isTerminated }
    }

    func status(for app: ManagedApp) -> AppStatus { statuses[app.id] ?? AppStatus() }

    func isBusy(_ app: ManagedApp) -> Bool { appOperations.active.contains(app.bundleID) }

    // MARK: - Launch / stop / cleanup

    func launch(_ app: ManagedApp, interactive: Bool = true) async {
        _ = await appOperations.run(for: app.bundleID) {
            await launchApp(app, interactive: interactive)
        }
    }

    private func launchApp(_ app: ManagedApp, interactive: Bool) async {
        if !runningInstances(of: app).isEmpty {
            message = "\(app.name) is already running. Use Relaunch to restart it through the proxy."
            return
        }
        await checkProxy()
        if !proxyState.isUp {
            if !interactive {
                message = "Skipped \(app.name): the proxy at \(settings.host):\(settings.port) isn't reachable."
                return
            }
            if settings.warnWhenProxyDown && !confirmLaunchWithProxyDown(app) { return }
        }

        // The app may have been opened from the Dock while the probe was running.
        guard runningInstances(of: app).isEmpty else {
            message = "\(app.name) is already running. Use Relaunch to restart it through the proxy."
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.environment = settings.environment.merging(app.extraEnvironmentDict) { _, new in new }
        if app.useChromiumProxyFlag { config.arguments = settings.chromiumArguments }
        config.activates = interactive

        do {
            _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: config)
            message = "Launched \(app.name) with proxy settings"
        } catch {
            message = "Couldn't launch \(app.name): \(error.localizedDescription)"
        }
        try? await Task.sleep(for: .seconds(1))
        await refreshApps()
    }

    @discardableResult
    func stop(_ app: ManagedApp, force: Bool = false) async -> Bool {
        await appOperations.run(for: app.bundleID) {
            await stopApp(app, force: force)
        } ?? false
    }

    private func stopApp(_ app: ManagedApp, force: Bool = false) async -> Bool {
        let running = runningInstances(of: app)
        guard !running.isEmpty else { return true }

        for instance in running {
            if force { instance.forceTerminate() } else { instance.terminate() }
        }
        // Give the app up to 20 s (it may ask to save something).
        for _ in 0..<80 {
            if running.allSatisfy({ $0.isTerminated }) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard running.allSatisfy({ $0.isTerminated }) else {
            message = "\(app.name) didn't quit. Right-click the stop button to force quit."
            return false
        }

        message = "Quit \(app.name)"
        if settings.cleanupAfterQuit {
            try? await Task.sleep(for: .seconds(1.5))
            await cleanLeftovers(app, allowNameMatches: false)
        } else {
            await refreshApps()
        }
        return true
    }

    func relaunch(_ app: ManagedApp) async {
        _ = await appOperations.run(for: app.bundleID) {
            guard await stopApp(app) else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await launchApp(app, interactive: true)
        }
    }

    /// Terminates leftover processes (SIGTERM, then SIGKILL after 2 s).
    func cleanup(_ app: ManagedApp) async {
        _ = await appOperations.run(for: app.bundleID) {
            await cleanLeftovers(app, allowNameMatches: true)
        }
    }

    private func cleanLeftovers(_ app: ManagedApp, allowNameMatches: Bool) async {
        guard runningInstances(of: app).isEmpty else { return }
        let processes = await Task.detached { ProcessInspector.userProcesses() }.value
        var targets = processes.filter { app.isBundleLeftover($0) }
        if allowNameMatches {
            let nameMatches = processes.filter { app.isNameOnlyLeftover($0) }
            if !nameMatches.isEmpty && confirmNameOnlyCleanup(nameMatches, app: app) {
                targets += nameMatches
            }
        }
        guard !targets.isEmpty, runningInstances(of: app).isEmpty, !Task.isCancelled else {
            await refreshApps()
            return
        }

        let signaled = targets.filter { ProcessInspector.signal(SIGTERM, to: $0) }
        if !signaled.isEmpty {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled && runningInstances(of: app).isEmpty {
                for target in signaled { _ = ProcessInspector.signal(SIGKILL, to: target) }
            }
            message = "Sent cleanup signals for \(app.name)"
        }
        await refreshApps()
    }

    private func confirmNameOnlyCleanup(_ processes: [ProcInfo], app: ManagedApp) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Include processes matched by name?"
        let names = processes.map { "\($0.name) (PID \($0.pid))" }.joined(separator: ", ")
        alert.informativeText = "These processes are outside \(app.name)’s bundle and may belong to another app.\n\n\(names)"
        alert.addButton(withTitle: "Skip Name Matches")
        alert.addButton(withTitle: "Include Name Matches")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func launchStartupApps() async {
        let startup = apps.filter(\.launchOnStart)
        guard !startup.isEmpty else { return }
        // At login the proxy app may still be starting: wait up to 60 s for it.
        for _ in 0..<30 where !proxyState.isUp {
            try? await Task.sleep(for: .seconds(2))
            await checkProxy()
        }
        for app in startup where runningInstances(of: app).isEmpty {
            await launch(app, interactive: false)
        }
    }

    private func confirmLaunchWithProxyDown(_ app: ManagedApp) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "The proxy isn't reachable"
        alert.informativeText = "Nothing is listening on \(settings.host):\(settings.port). Launch \(app.name) anyway? Its connections will fail until the proxy is running."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Launch Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: - Region check

    private func invalidateRegionReport() {
        regionGeneration += 1
        report = nil
        scheduleNextRegionCheck()
    }

    private func scheduleNextRegionCheck() {
        regionTimer?.cancel()
        regionTimer = nil
        let interval = settings.regionCheckIntervalSeconds
        guard interval > 0, !checking, proxyState.isUp else { return }
        let delay = report.map { max(0, Double(interval) - Date().timeIntervalSince($0.date)) } ?? 1
        regionTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.regionTimer = nil
            await self.runRegionCheck(automatic: true)
        }
    }

    /// Checks every enabled service through the proxy (and directly, if enabled).
    func runRegionCheck(automatic: Bool = false) async {
        guard !checking else { return }
        if automatic && !proxyState.isUp { return }
        let generation = regionGeneration
        checking = true
        scheduleNextRegionCheck()
        defer {
            checking = false
            scheduleNextRegionCheck()
        }
        if !automatic { await checkProxy() }
        guard generation == regionGeneration else { return }
        let inputs = regionInputs
        let newReport = await RegionChecker.run(settings: settings,
                                                services: inputs.enabledServices,
                                                includeDirect: inputs.includeDirect)
        guard generation == regionGeneration else { return }
        let previous = report
        report = newReport
        if automatic { notifyNewlyBlocked(previous: previous, current: newReport) }
    }

    /// Services that went from available to blocked through the proxy since the last check.
    private func notifyNewlyBlocked(previous: RegionReport?, current: RegionReport) {
        guard settings.notifyServiceBlocked, let previous else { return }
        let newlyBlocked = services.filter { service in
            service.enabled
                && previous.result(for: service.id)?.viaProxy?.isAvailable == true
                && current.result(for: service.id)?.viaProxy?.isBlocked == true
        }
        guard !newlyBlocked.isEmpty else { return }
        let names = newlyBlocked.map(\.name).joined(separator: ", ")
        let exit = current.proxyExit?.country.map { " (exit: \($0))" } ?? ""
        Notifier.shared.post(
            title: newlyBlocked.count == 1 ? "\(names) is blocked" : "Services blocked",
            body: "\(names) now refuse\(newlyBlocked.count == 1 ? "s" : "") connections through your proxy\(exit)."
        )
    }

    /// Services this app depends on that are blocked through the proxy in the latest report.
    func blockedServices(for app: ManagedApp) -> [ServiceCheck] {
        guard let report else { return [] }
        return services.filter { service in
            service.enabled && app.serviceIDs.contains(service.id)
                && report.result(for: service.id)?.viaProxy?.isBlocked == true
        }
    }

    func restoreDefaultServices() {
        for preset in ServiceCheck.presets where !services.contains(where: { $0.id == preset.id }) {
            services.append(preset)
        }
    }

    // MARK: - Misc

    // MARK: - Terminal

    func openTerminal(at folder: URL) async {
        var terminal = settings.terminalApp
        if terminal.appURL == nil { terminal = .terminal }
        do {
            try await TerminalLauncher.open(folder: folder, settings: settings, terminal: terminal)
            var recents = settings.recentTerminalFolders.filter { $0 != folder.path }
            recents.insert(folder.path, at: 0)
            settings.recentTerminalFolders = Array(recents.prefix(6))
            message = "Opened \(terminal.name) in \(folder.lastPathComponent) with the proxy set"
        } catch {
            message = "Couldn't open \(terminal.name): \(error.localizedDescription)"
        }
    }

    func chooseFolderForTerminal() async {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Terminal"
        panel.directoryURL = URL(fileURLWithPath: settings.recentTerminalFolders.first ?? NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await openTerminal(at: url)
    }

    /// Recent folders that still exist.
    var recentTerminalFolders: [URL] {
        settings.recentTerminalFolders
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func copyShellExports() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(settings.shellExports, forType: .string)
        message = "Copied proxy exports. Paste them into a terminal."
    }

    func icon(for app: ManagedApp) -> NSImage {
        if let cached = iconCache[app.path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: app.path)
        iconCache[app.path] = image
        return image
    }

    // MARK: - Editing the app list

    func addAppsWithPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        add(urls: panel.urls)
    }

    func add(urls: [URL]) {
        for url in urls {
            guard let app = ManagedApp.make(from: url) else {
                message = "\(url.lastPathComponent) isn't an app."
                continue
            }
            if apps.contains(where: { $0.bundleID == app.bundleID }) { continue }
            apps.append(app)
        }
    }

    func remove(id: UUID) {
        if selectedAppID == id { selectedAppID = nil }
        apps.removeAll { $0.id == id }
    }

    // MARK: - Open at login

    var opensAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    func refreshLoginStatus() { loginStatus = SMAppService.mainApp.status }

    func setOpensAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        refreshLoginStatus()
    }
}
