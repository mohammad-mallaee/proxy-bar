import AppKit
import Observation
import SwiftUI

/// Shows the first-run setup window. It appears once on first launch; closing
/// it at any step counts as done. "Run setup again" in Settings reopens it.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let shared = OnboardingController()
    static let doneKey = "onboardingDone.v1"

    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    private var window: NSWindow?
    private var model: OnboardingModel?

    func show(store: AppStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = OnboardingModel(store: store)
        let view = OnboardingView(model: model, store: store) { [weak self] in self?.window?.close() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: view)
        window.title = "Welcome to ProxyBar"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        self.model = model
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window = nil
        model = nil
    }
}

@MainActor
@Observable
final class OnboardingModel {
    struct Candidate: Identifiable {
        var id: String { app.path }
        var app: ManagedApp
        var selected: Bool
    }

    static let stepCount = 4

    var step = 0
    var candidates: [Candidate]
    var openAtLogin: Bool
    var notifications: Bool

    init(store: AppStore) {
        var list = store.apps.map { Candidate(app: $0, selected: true) }
        for url in KnownApps.installed() where !list.contains(where: { $0.app.path == url.path }) {
            if let app = ManagedApp.make(from: url) { list.append(Candidate(app: app, selected: false)) }
        }
        candidates = list
        openAtLogin = store.opensAtLogin
        notifications = store.settings.notifyProxyDown
    }

    func addOtherApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let index = candidates.firstIndex(where: { $0.app.path == url.path }) {
                candidates[index].selected = true
            } else if let app = ManagedApp.make(from: url) {
                candidates.append(Candidate(app: app, selected: true))
            }
        }
    }

    /// Applies the choices to the store.
    func apply(to store: AppStore) {
        store.apps = candidates.filter(\.selected).map(\.app)
        if openAtLogin != store.opensAtLogin { store.setOpensAtLogin(openAtLogin) }
        store.settings.notifyProxyDown = notifications
        store.settings.notifyProxyUp = notifications
        store.settings.notifyServiceBlocked = notifications
        if notifications { Task { await Notifier.shared.requestPermission() } }
    }
}

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @Bindable var store: AppStore
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.step {
                case 0: ProxyStep(store: store)
                case 1: AppsStep(model: model, store: store)
                case 2: StartupStep(model: model, store: store)
                default: DoneStep(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 600, height: 540)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(titles[model.step]).font(.title2.bold())
                Text(subtitles[model.step]).foregroundStyle(.secondary)
            }
            Spacer()
            if model.step < OnboardingModel.stepCount - 1 {
                Text("Step \(model.step + 1) of \(OnboardingModel.stepCount - 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack {
            if model.step > 0 && model.step < OnboardingModel.stepCount - 1 {
                Button("Back") { model.step -= 1 }
            }
            Spacer()
            if model.step < OnboardingModel.stepCount - 1 {
                Button("Skip setup") { close() }
                Button(model.step == OnboardingModel.stepCount - 2 ? "Finish" : "Continue") {
                    if model.step == OnboardingModel.stepCount - 2 { model.apply(to: store) }
                    model.step += 1
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private let titles = ["Welcome to ProxyBar", "Choose your apps", "Startup and alerts", "You're all set"]
    private let subtitles = [
        "Launch apps through your proxy and see which services work.",
        "These apps will be launched with the proxy set.",
        "Decide what happens at login and when the proxy drops.",
        "ProxyBar lives in your menu bar.",
    ]
}

// MARK: - Steps

private struct ProxyStep: View {
    @Bindable var store: AppStore

    var body: some View {
        Form {
            Section("Your proxy") {
                Picker("Type", selection: $store.settings.scheme) {
                    ForEach(ProxyScheme.allCases) { Text($0.label).tag($0) }
                }
                TextField("Host", text: $store.settings.host)
                TextField("Port", value: $store.settings.port, format: .number.grouping(.never))
                Text("Use the local port your proxy app (V2Ray, Xray, Clash, sing-box…) listens on for HTTP or SOCKS5.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Connection") {
                HStack {
                    Circle().fill(store.proxyState.isUp ? .green : store.proxyState == .down ? .red : .gray)
                        .frame(width: 9, height: 9)
                    Text(store.proxyState.isUp ? "The proxy port is answering"
                         : store.proxyState == .down ? "Nothing is answering on this port" : "Checking…")
                    Spacer()
                    if store.checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Check services") { Task { await store.runRegionCheck() } }
                    }
                }
                if let report = store.report {
                    let enabled = store.services.filter(\.enabled)
                    let ok = enabled.filter { report.result(for: $0.id)?.viaProxy?.isAvailable == true }
                    let blocked = enabled.filter { report.result(for: $0.id)?.viaProxy?.isBlocked == true }
                    VStack(alignment: .leading, spacing: 3) {
                        if let exit = report.proxyExit {
                            Text("Exit: \(exit.country.map { RegionChecker.flag(for: $0) + " " + $0 } ?? "?") · \(exit.ip ?? "?")")
                        }
                        Text("\(ok.count) of \(enabled.count) services available through the proxy")
                            .foregroundStyle(blocked.isEmpty ? .green : .orange)
                        if !blocked.isEmpty {
                            Text("Blocked: " + blocked.map(\.name).joined(separator: ", "))
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppsStep: View {
    @Bindable var model: OnboardingModel
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach($model.candidates) { $candidate in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $candidate.selected).labelsHidden()
                        Image(nsImage: store.icon(for: candidate.app))
                            .resizable()
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.app.name)
                            if !candidate.app.serviceIDs.isEmpty {
                                Text("Uses " + candidate.app.serviceIDs.compactMap { id in
                                    store.services.first { $0.id == id }?.name
                                }.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle("Start with ProxyBar", isOn: $candidate.app.launchOnStart)
                            .toggleStyle(.checkbox)
                            .disabled(!candidate.selected)
                    }
                    .padding(.vertical, 2)
                }
            }
            HStack {
                Button("Add another app…") { model.addOtherApps() }
                Spacer()
                Text("You can change this later in Settings → Apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }
}

private struct StartupStep: View {
    @Bindable var model: OnboardingModel
    @Bindable var store: AppStore

    var body: some View {
        Form {
            Section {
                Toggle("Open ProxyBar at login", isOn: $model.openAtLogin)
                Text("Together with “Start with ProxyBar” on your apps, they start through the proxy automatically after you log in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Notify me when the proxy drops or a service gets blocked", isOn: $model.notifications)
                Text("macOS will ask for permission once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Terminal app", selection: $store.settings.terminalApp) {
                    ForEach(TerminalApp.installed) { Text($0.name).tag($0) }
                }
                Text("“Terminal with proxy” in the menu opens it with the proxy variables set.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DoneStep: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            tip("network", "Click the globe in the menu bar to open ProxyBar.")
            tip("play.fill", "Launch apps with ▶. Running apps can be relaunched through the proxy with ↻.")
            tip("checkmark.shield", "“Check” shows your exit country and which services work through the proxy.")
            tip("terminal", "“Terminal with proxy” opens a shell with the proxy variables already set.")
            tip("gearshape", "Settings has your proxy, apps, region checks and notifications.")
        }
        .padding(24)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(.tint)
            Text(text)
        }
    }
}
