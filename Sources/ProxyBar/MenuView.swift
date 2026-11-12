import SwiftUI

/// The panel that opens from the menu bar icon.
struct MenuView: View {
    @Bindable var store: AppStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProxyHeader(store: store)

            RegionSection(store: store)

            Divider()

            if store.apps.isEmpty {
                Text("No apps yet. Add some in Settings.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.apps) { app in
                    AppRow(store: store, app: app)
                }
            }

            if let message = store.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                TerminalMenu(store: store)
                Spacer()
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit ProxyBar")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 380)
        .task { await store.refreshApps() }
    }
}

// MARK: - Terminal menu

private struct TerminalMenu: View {
    @Bindable var store: AppStore

    var body: some View {
        Menu {
            Button("New window in home folder") {
                Task { await store.openTerminal(at: URL(fileURLWithPath: NSHomeDirectory())) }
            }
            Button("Choose folder…") {
                Task { await store.chooseFolderForTerminal() }
            }
            let recents = store.recentTerminalFolders
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents, id: \.self) { folder in
                        Button(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                            Task { await store.openTerminal(at: folder) }
                        }
                    }
                }
            }
            Divider()
            Button("Copy shell exports") { store.copyShellExports() }
        } label: {
            Label("Terminal with proxy", systemImage: "terminal")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Open \(store.settings.terminalApp.name) with the proxy variables set")
    }
}

// MARK: - Proxy header

private struct ProxyHeader: View {
    @Bindable var store: AppStore

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.settings.url)
                    .font(.system(.body, design: .monospaced))
                Text(stateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.checking {
                ProgressView().controlSize(.small)
            } else {
                Button("Check") { Task { await store.runRegionCheck() } }
                    .help("Check Google, your exit IP and country, and every service in the region list")
            }
        }
    }

    private var dotColor: Color {
        switch store.proxyState {
        case .checking: return .gray
        case .up: return .green
        case .down: return .red
        }
    }

    private var stateText: String {
        switch store.proxyState {
        case .checking: return "Checking…"
        case .up(let ms): return "Proxy port reachable · \(max(1, Int(ms))) ms"
        case .down: return "Proxy not reachable"
        }
    }
}

// MARK: - Region check

private struct RegionSection: View {
    @Bindable var store: AppStore

    var body: some View {
        if let report = store.report {
            VStack(alignment: .leading, spacing: 6) {
                exitLine(report)

                DisclosureGroup(isExpanded: $store.regionExpanded) {
                    serviceGrid(report)
                        .padding(.top, 4)
                } label: {
                    summaryLabel(report)
                }

                ForEach(report.errors, id: \.self) { error in
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } else if store.checking {
            Text("Checking services…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func exitLine(_ report: RegionReport) -> some View {
        HStack(spacing: 10) {
            if let exit = report.proxyExit {
                Text("Exit \(countryText(exit.country)) · \(exit.ip ?? "?")")
                    .textSelection(.enabled)
            }
            if let direct = report.directExit {
                Text("Direct \(countryText(direct.country))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let ms = report.googleMs {
                Text("Google \(Int(ms)) ms")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func summaryLabel(_ report: RegionReport) -> some View {
        let enabled = store.services.filter(\.enabled)
        let blocked = enabled.filter { report.result(for: $0.id)?.viaProxy?.isBlocked == true }
        let unreachable = enabled.filter {
            if case .unreachable = report.result(for: $0.id)?.viaProxy { return true }
            return false
        }
        var text = blocked.isEmpty && unreachable.isEmpty
            ? "All \(enabled.count) services available through the proxy"
            : "\(blocked.count) blocked, \(unreachable.count) unreachable through the proxy"
        text += " · " + report.date.formatted(.relative(presentation: .named))
        return Text(text)
            .font(.caption)
            .foregroundStyle(blocked.isEmpty && unreachable.isEmpty ? Color.secondary : Color.orange)
    }

    private func serviceGrid(_ report: RegionReport) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            GridRow {
                Text("Service")
                Text("Proxy")
                if store.settings.checkDirectToo { Text("Direct") }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            ForEach(store.services.filter(\.enabled)) { service in
                let result = report.result(for: service.id)
                GridRow {
                    Text(service.name)
                        .lineLimit(1)
                    VerdictBadge(verdict: result?.viaProxy)
                    if store.settings.checkDirectToo {
                        VerdictBadge(verdict: result?.direct)
                    }
                }
                .font(.caption)
            }
        }
    }

    private func countryText(_ code: String?) -> String {
        guard let code else { return "?" }
        return "\(RegionChecker.flag(for: code)) \(code)"
    }
}

private struct VerdictBadge: View {
    let verdict: ServiceVerdict?

    var body: some View {
        Group {
            switch verdict {
            case .available?:
                Label("OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .blocked?:
                Label("Blocked", systemImage: "hand.raised.fill").foregroundStyle(.red)
            case .unreachable?:
                Label("No reply", systemImage: "questionmark.circle").foregroundStyle(.orange)
            case nil:
                Text("–").foregroundStyle(.secondary)
            }
        }
        .labelStyle(.titleAndIcon)
        .help(verdict?.detail ?? "Not checked")
    }
}

// MARK: - App rows

private struct AppRow: View {
    @Bindable var store: AppStore
    let app: ManagedApp

    var body: some View {
        let status = store.status(for: app)
        let blocked = store.blockedServices(for: app)
        HStack(spacing: 10) {
            Image(nsImage: store.icon(for: app))
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                Text(statusText(status))
                    .font(.caption)
                    .foregroundStyle(statusColor(status))
                    .help(leftoverHelp(status))
                if !blocked.isEmpty {
                    Label("Blocked through proxy: " + blocked.map(\.name).joined(separator: ", "),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .help("Your proxy's exit IP is blocked by these services. Try another proxy server or country.")
                }
            }
            Spacer()
            if store.busy.contains(app.id) {
                ProgressView().controlSize(.small)
            } else {
                buttons(status)
            }
        }
    }

    @ViewBuilder
    private func buttons(_ status: AppStatus) -> some View {
        HStack(spacing: 6) {
            if status.running {
                iconButton("arrow.clockwise", help: "Quit and relaunch through the proxy") {
                    await store.relaunch(app)
                }
                iconButton("stop.fill", help: "Quit (right-click to force quit)") {
                    await store.stop(app)
                }
                .contextMenu {
                    Button("Force Quit") { Task { await store.stop(app, force: true) } }
                }
            } else {
                if !status.leftovers.isEmpty {
                    iconButton("trash", help: "Kill leftover processes") {
                        await store.cleanup(app)
                    }
                }
                iconButton("play.fill", help: "Launch through the proxy") {
                    await store.launch(app)
                }
            }
        }
        .buttonStyle(.borderless)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol).frame(width: 18, height: 18)
        }
        .help(help)
    }

    private func statusText(_ s: AppStatus) -> String {
        if !s.running {
            let n = s.leftovers.count
            return n == 0 ? "Not running" : "Not running · \(n) leftover process\(n == 1 ? "" : "es")"
        }
        guard s.envReadable else { return "Running · proxy status unknown" }
        guard let value = s.proxyValue else { return "Running · not through the proxy" }
        return value == store.settings.url ? "Running · through the proxy" : "Running · through \(value)"
    }

    private func statusColor(_ s: AppStatus) -> Color {
        if !s.running { return s.leftovers.isEmpty ? .secondary : .orange }
        guard s.envReadable else { return .secondary }
        return s.proxyValue == store.settings.url ? .green : .orange
    }

    private func leftoverHelp(_ s: AppStatus) -> String {
        guard !s.leftovers.isEmpty else { return "" }
        return s.leftovers.map { "\($0.name) (pid \($0.pid))" }.joined(separator: "\n")
    }
}
