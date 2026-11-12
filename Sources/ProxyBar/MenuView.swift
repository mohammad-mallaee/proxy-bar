import SwiftUI

/// The panel that opens from the menu bar icon.
struct MenuView: View {
    @Bindable var store: AppStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProxyHeader(store: store)

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
                Button("Copy shell exports") { store.copyShellExports() }
                    .help("Copy export commands so a terminal uses the same proxy")
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
        .frame(width: 360)
        .task { await store.refreshApps() }
    }
}

private struct ProxyHeader: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                if store.testing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Test") { Task { await store.testConnection() } }
                        .help("Check that Google is reachable through the proxy and show the exit IP and country")
                }
            }

            if let test = store.lastTest {
                VStack(alignment: .leading, spacing: 2) {
                    if let ms = test.googleMs {
                        Label("Google reachable · \(Int(ms)) ms", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if let ip = test.exitIP {
                        let country = test.country.map { " · \(ConnectionTester.flag(for: $0)) \($0)" } ?? ""
                        Label("Exit IP \(ip)\(country)", systemImage: "globe")
                            .textSelection(.enabled)
                    }
                    ForEach(test.errors, id: \.self) { error in
                        Label(error, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
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

private struct AppRow: View {
    @Bindable var store: AppStore
    let app: ManagedApp

    var body: some View {
        let status = store.status(for: app)
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
