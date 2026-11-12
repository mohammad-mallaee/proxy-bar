import SwiftUI

/// The panel that opens from the menu bar icon.
///
/// Layout, top to bottom:
///   proxy (one line) · region summary (one line, click to expand) · apps · footer icons
struct MenuView: View {
    @Bindable var store: AppStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProxyHeader(store: store)
                .padding(.bottom, 8)

            RegionSummary(store: store)

            Divider().padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 8) {
                if store.apps.isEmpty {
                    Text("No apps yet. Add some in Settings.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.apps) { app in
                        AppRow(store: store, app: app)
                    }
                }
            }

            if let message = store.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .transition(.opacity)
            }

            Divider().padding(.vertical, 8)

            HStack(spacing: 12) {
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
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 340)
        .animation(.easeInOut(duration: 0.15), value: store.regionExpanded)
        .animation(.easeInOut(duration: 0.2), value: store.message)
        .task { await store.refreshApps() }
    }
}

// MARK: - Proxy header

private struct ProxyHeader: View {
    @Bindable var store: AppStore

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(store.settings.url)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(stateText)
                .font(.caption)
                .foregroundStyle(store.proxyState == .down ? .red : .secondary)
        }
        .help(store.proxyState == .down
              ? "Nothing is answering on \(store.settings.host):\(store.settings.port)"
              : "Proxy port connect time")
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
        case .checking: return "…"
        case .up(let ms): return "\(max(1, Int(ms))) ms"
        case .down: return "Not reachable"
        }
    }
}

// MARK: - Region summary (collapsed by default)

private struct RegionSummary: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    store.regionExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(store.regionExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                        summary
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.report == nil)

                if store.checking {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        Task { await store.runRegionCheck() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Check your exit country and the services you use")
                }
            }

            if store.regionExpanded, let report = store.report {
                RegionDetails(store: store, report: report)
                    .padding(.leading, 14)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let report = store.report {
            let enabled = store.services.filter(\.enabled)
            let blocked = enabled.filter { report.result(for: $0.id)?.viaProxy?.isBlocked == true }
            let failed = enabled.filter {
                if case .unreachable = report.result(for: $0.id)?.viaProxy { return true }
                return false
            }
            let ok = enabled.count - blocked.count - failed.count
            HStack(spacing: 4) {
                if let country = report.proxyExit?.country {
                    Text("\(RegionChecker.flag(for: country)) \(country)")
                    Text("·").foregroundStyle(.tertiary)
                }
                if blocked.isEmpty && failed.isEmpty {
                    Text("All \(enabled.count) services OK").foregroundStyle(.secondary)
                } else {
                    Text("\(ok)/\(enabled.count) OK").foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(problemText(blocked: blocked, failed: failed))
                        .foregroundStyle(blocked.isEmpty ? .orange : .red)
                        .lineLimit(1)
                }
            }
            .font(.caption)
        } else {
            Text(store.checking ? "Checking services…" : "Services not checked yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func problemText(blocked: [ServiceCheck], failed: [ServiceCheck]) -> String {
        if blocked.count == 1 && failed.isEmpty { return "\(blocked[0].name) blocked" }
        if failed.count == 1 && blocked.isEmpty { return "\(failed[0].name) no reply" }
        var parts: [String] = []
        if !blocked.isEmpty { parts.append("\(blocked.count) blocked") }
        if !failed.isEmpty { parts.append("\(failed.count) no reply") }
        return parts.joined(separator: ", ")
    }
}

private struct RegionDetails: View {
    @Bindable var store: AppStore
    let report: RegionReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("")
                    Text("Proxy")
                    if store.settings.checkDirectToo { Text("Direct") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                ForEach(store.services.filter(\.enabled)) { service in
                    let result = report.result(for: service.id)
                    GridRow {
                        Text(service.name).lineLimit(1)
                        VerdictIcon(verdict: result?.viaProxy)
                        if store.settings.checkDirectToo {
                            VerdictIcon(verdict: result?.direct)
                        }
                    }
                    .font(.caption)
                }
            }

            Text(footerText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            ForEach(report.errors, id: \.self) { error in
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var footerText: String {
        var parts: [String] = []
        if let ip = report.proxyExit?.ip { parts.append("Exit IP \(ip)") }
        if let direct = report.directExit?.country { parts.append("direct \(RegionChecker.flag(for: direct)) \(direct)") }
        if let ms = report.googleMs { parts.append("Google \(Int(ms)) ms") }
        parts.append(report.date.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

private struct VerdictIcon: View {
    let verdict: ServiceVerdict?

    var body: some View {
        Group {
            switch verdict {
            case .available?:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .blocked?:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .unreachable?:
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
            case nil:
                Text("–").foregroundStyle(.secondary)
            }
        }
        .help(verdict?.detail ?? "Not checked")
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
            Image(systemName: "terminal")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Terminal with proxy")
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
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(statusText(status))
                        .foregroundStyle(statusColor(status))
                        .help(leftoverHelp(status))
                    if !blocked.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(blocked.count == 1 ? "\(blocked[0].name) blocked" : "\(blocked.count) services blocked")
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .help("Blocked through the proxy: " + blocked.map(\.name).joined(separator: ", ")
                                  + ". Try another proxy server or country.")
                    }
                }
                .font(.caption)
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
        HStack(spacing: 4) {
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
            Image(systemName: symbol).frame(width: 20, height: 20)
        }
        .help(help)
    }

    private func statusText(_ s: AppStatus) -> String {
        if !s.running {
            let n = s.leftovers.count
            return n == 0 ? "Not running" : "\(n) leftover process\(n == 1 ? "" : "es")"
        }
        guard s.envReadable else { return "Running" }
        guard let value = s.proxyValue else { return "Running without proxy" }
        return value == store.settings.url ? "Through proxy" : "Through \(value)"
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
