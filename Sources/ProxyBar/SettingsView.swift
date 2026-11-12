import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var store: AppStore

    var body: some View {
        TabView {
            GeneralSettings(store: store)
                .tabItem { Label("Proxy", systemImage: "network") }
            AppsSettings(store: store)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            RegionSettings(store: store)
                .tabItem { Label("Region", systemImage: "globe") }
        }
        .frame(width: 660, height: 520)
    }
}

// MARK: - Proxy tab

private struct GeneralSettings: View {
    @Bindable var store: AppStore

    var body: some View {
        Form {
            Section("Proxy") {
                Picker("Type", selection: $store.settings.scheme) {
                    ForEach(ProxyScheme.allCases) { Text($0.label).tag($0) }
                }
                TextField("Host", text: $store.settings.host)
                TextField("Port", value: $store.settings.port, format: .number.grouping(.never))
                TextField("Don't proxy", text: $store.settings.noProxy)
                Text("Comma-separated hosts that connect directly (NO_PROXY).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Environment") {
                Toggle("Also set lowercase variables (http_proxy, https_proxy, no_proxy)", isOn: $store.settings.lowercaseVariables)
                Toggle("Set NODE_USE_ENV_PROXY=1 (Node.js 24+ fetch)", isOn: $store.settings.nodeUseEnvProxy)
                LabeledContent("Passed to apps") {
                    Text(store.settings.shellExports)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }

            Section("Notifications") {
                Toggle("When the proxy stops answering", isOn: $store.settings.notifyProxyDown)
                Toggle("Only while an app is running through it", isOn: $store.settings.notifyOnlyWhenAppsUseProxy)
                    .disabled(!store.settings.notifyProxyDown)
                    .padding(.leading, 16)
                Toggle("When the proxy is back", isOn: $store.settings.notifyProxyUp)
                Toggle("When a service becomes blocked through the proxy", isOn: $store.settings.notifyServiceBlocked)
                Button("Send a test notification") {
                    Notifier.shared.post(title: "ProxyBar", body: "Notifications are working.")
                }
            }

            Section("Behavior") {
                Toggle("Ask before launching when the proxy isn't reachable", isOn: $store.settings.warnWhenProxyDown)
                Toggle("Clean up leftover processes after quitting an app", isOn: $store.settings.cleanupAfterQuit)
                Toggle("Open ProxyBar at login", isOn: Binding(
                    get: { store.opensAtLogin },
                    set: { store.setOpensAtLogin($0) }
                ))
                if store.loginStatus == .requiresApproval {
                    HStack {
                        Text("Needs approval in System Settings → Login Items.")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = store.loginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refreshLoginStatus() }
    }
}

// MARK: - Apps tab

private struct AppsSettings: View {
    @Bindable var store: AppStore

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $store.selectedAppID) {
                    ForEach(store.apps) { app in
                        Label {
                            Text(app.name)
                        } icon: {
                            Image(nsImage: store.icon(for: app)).resizable().frame(width: 16, height: 16)
                        }
                        .tag(app.id)
                    }
                    .onMove { store.apps.move(fromOffsets: $0, toOffset: $1) }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    store.add(urls: urls.filter { $0.pathExtension == "app" })
                    return true
                }
                Divider()
                HStack(spacing: 2) {
                    Button { store.addAppsWithPanel() } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
                        .help("Add apps (you can also drag apps into the list)")
                    Button {
                        if let id = store.selectedAppID { store.remove(id: id) }
                    } label: { Image(systemName: "minus").frame(width: 20, height: 20) }
                        .disabled(store.selectedAppID == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 200)

            Divider()

            if let index = store.apps.firstIndex(where: { $0.id == store.selectedAppID }) {
                AppDetail(app: $store.apps[index], services: store.services)
            } else {
                Text("Select an app, or add one with +")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if store.selectedAppID == nil { store.selectedAppID = store.apps.first?.id } }
    }
}

private struct AppDetail: View {
    @Binding var app: ManagedApp
    let services: [ServiceCheck]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $app.name)
                LabeledContent("Location") {
                    Text(app.path).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
                LabeledContent("Bundle ID") { Text(app.bundleID).textSelection(.enabled) }
            }

            Section {
                Toggle("Pass Chromium proxy flags", isOn: $app.useChromiumProxyFlag)
                Text("Needed for Electron apps (T3 Code, Claude, VS Code…): their windows ignore proxy variables. Only applies when ProxyBar starts the app.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Launch when ProxyBar starts", isOn: $app.launchOnStart)
            }

            Section("Services this app needs") {
                ForEach(services) { service in
                    Toggle(service.name, isOn: Binding(
                        get: { app.serviceIDs.contains(service.id) },
                        set: { on in
                            app.serviceIDs.removeAll { $0 == service.id }
                            if on { app.serviceIDs.append(service.id) }
                        }
                    ))
                }
                Text("The menu warns on this app's row when one of these is blocked through the proxy.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Leftover processes") {
                TextField("Process names", text: $app.cleanupPatterns, prompt: Text("e.g. agy_acp_server, localharness_external"))
                Text("After the app quits, processes still running from inside the app, or whose name contains one of these (comma-separated), can be cleaned up.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Extra environment") {
                TextField("", text: $app.extraEnvironment, prompt: Text("KEY=value, one per line"), axis: .vertical)
                    .lineLimit(3...6)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Region tab

private struct RegionSettings: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Region check") {
                    Toggle("Also check each service without the proxy", isOn: $store.settings.checkDirectToo)
                    Picker("Re-check automatically", selection: $store.settings.regionCheckIntervalMinutes) {
                        Text("Only at start and when the proxy reconnects").tag(0)
                        Text("Every 15 minutes").tag(15)
                        Text("Every 30 minutes").tag(30)
                        Text("Every hour").tag(60)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 140)

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $store.selectedServiceID) {
                        ForEach($store.services) { $service in
                            HStack {
                                Toggle("", isOn: $service.enabled).labelsHidden()
                                Text(service.name)
                                Spacer()
                                if let result = store.report?.result(for: service.id)?.viaProxy {
                                    Image(systemName: result.isBlocked ? "hand.raised.fill"
                                          : result.isAvailable ? "checkmark.circle.fill" : "questionmark.circle")
                                        .foregroundStyle(result.isBlocked ? .red : result.isAvailable ? .green : .orange)
                                        .help(result.detail)
                                }
                            }
                            .tag(service.id)
                        }
                    }
                    Divider()
                    HStack(spacing: 2) {
                        Button {
                            let service = ServiceCheck.custom()
                            store.services.append(service)
                            store.selectedServiceID = service.id
                        } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
                            .help("Add a custom service check")
                        Button {
                            if let id = store.selectedServiceID {
                                store.selectedServiceID = nil
                                store.services.removeAll { $0.id == id }
                            }
                        } label: { Image(systemName: "minus").frame(width: 20, height: 20) }
                            .disabled(store.selectedServiceID == nil)
                        Spacer()
                        Button("Restore defaults") { store.restoreDefaultServices() }
                            .help("Re-add any built-in checks you removed")
                    }
                    .buttonStyle(.borderless)
                    .padding(6)
                }
                .frame(width: 250)

                Divider()

                if let index = store.services.firstIndex(where: { $0.id == store.selectedServiceID }) {
                    ServiceDetail(service: $store.services[index],
                                  result: store.report?.result(for: store.services[index].id))
                } else {
                    Text("Select a service to edit its check")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

private struct ServiceDetail: View {
    @Binding var service: ServiceCheck
    let result: ServiceResult?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $service.name)
                TextField("URL", text: $service.url)
                    .font(.system(.body, design: .monospaced))
            }
            Section("Block signature") {
                TextField("HTTP statuses", text: $service.blockedStatuses, prompt: Text("e.g. 403, 451"))
                TextField("Text markers", text: $service.blockedMarkers, prompt: Text("e.g. not available in your region"))
                Text("Blocked when the status matches and, if markers are set, the final URL or the response body contains one of them. Any other response counts as available: a 401 \"missing API key\" is the normal answer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result {
                Section("Last result") {
                    LabeledContent("Through proxy") { Text(result.viaProxy?.detail ?? "–").textSelection(.enabled) }
                    LabeledContent("Direct") { Text(result.direct?.detail ?? "–").textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
