import AppKit
import ServiceManagement
import SwiftUI

let brandGradient = LinearGradient(colors: [Color(red: 0.18, green: 0.06, blue: 0.40), Color(red: 0.26, green: 0.22, blue: 0.79), Color(red: 0.02, green: 0.71, blue: 0.83)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)

struct SettingsView: View {
    @ObservedObject var manager: DeviceManager

    var body: some View {
        NavigationSplitView {
            List(selection: $manager.selection) {
                Section("Devices") {
                    ForEach(manager.devices) { device in
                        SidebarDeviceRow(device: device).tag(device.id)
                    }
                    if manager.devices.isEmpty {
                        Text("No devices found").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Label("General", systemImage: "gearshape").tag("general")
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if manager.selection == "general" {
                GeneralSettings()
            } else if let device = manager.devices.first(where: { $0.id == manager.selection }) {
                DeviceDetail(device: device).id(device.id)
            } else {
                ContentUnavailableView("Select a device", systemImage: "computermouse")
            }
        }
        .frame(minWidth: 780, minHeight: 600)
        .onAppear {
            if manager.selection == nil { manager.selection = manager.devices.first?.id ?? "general" }
        }
    }
}

private struct SidebarDeviceRow: View {
    @ObservedObject var device: LogiDevice

    var body: some View {
        HStack {
            Label(device.state.name, systemImage: device.state.kind.symbol)
                .lineLimit(1)
            Spacer()
            if let p = device.state.battery?.percent {
                Text("\(p)%").font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(device.online ? 1 : 0.5)
    }
}

struct DeviceDetail: View {
    @ObservedObject var device: LogiDevice
    @State private var tab: String

    init(device: LogiDevice, tab: String = "overview") {
        self.device = device
        _tab = State(initialValue: tab)
    }

    var body: some View {
        let s = device.state
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: s.kind.symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(brandGradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.title2.bold())
                    Text(device.online ? s.connection : "\(s.connection) · asleep or off — move it to wake it")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let battery = s.battery {
                    BatteryLabel(battery: battery).font(.title3)
                }
            }
            .padding(20)

            Picker("", selection: $tab) {
                Text("Overview").tag("overview")
                if s.onboardProfiles != nil { Text("Onboard Memory").tag("memory") }
                if s.dpi != nil { Text("App DPI").tag("apps") }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            switch tab {
            case "memory": OnboardEditor(device: device)
            case "apps": AppRulesView(device: device)
            default:
                Form {
                    Section {
                        DeviceControls(device: device)
                            .controlSize(.regular)
                    } footer: {
                        if let error = device.lastError { Text(error).foregroundStyle(.red) }
                    }
                }
                .formStyle(.grouped)
                .disabled(!device.online)
            }
        }
    }
}

// MARK: Per-app DPI

struct AppRulesView: View {
    @ObservedObject var device: LogiDevice
    @State private var rules: [Rule] = []

    struct Rule: Identifiable, Equatable {
        var id: String { bundleID }
        let bundleID: String
        var dpi: Int
    }

    var body: some View {
        Form {
            Section {
                if rules.isEmpty {
                    Text("No app rules yet.").foregroundStyle(.secondary)
                }
                ForEach($rules) { $rule in
                    HStack(spacing: 10) {
                        AppIcon(bundleID: rule.bundleID)
                        Text(Self.appName(rule.bundleID))
                        Spacer()
                        TextField("", value: $rule.dpi, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("DPI").foregroundStyle(.secondary).font(.caption)
                        Button { rules.removeAll { $0.bundleID == rule.bundleID } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button { addApp() } label: { Label("Add App…", systemImage: "plus.circle.fill") }
                    .buttonStyle(.borderless)
            } header: {
                Text("Per-app DPI")
            } footer: {
                Text("While one of these apps is in front, LogiBar switches the mouse to its DPI, then switches back when you leave it.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            rules = AppRules.load(device.id).map { Rule(bundleID: $0.key, dpi: $0.value) }
                .sorted { Self.appName($0.bundleID) < Self.appName($1.bundleID) }
        }
        .onChange(of: rules) { _, rules in
            let range = device.state.dpiChoices.map { $0.min...$0.max } ?? 100...25600
            AppRules.save(device.id, Dictionary(uniqueKeysWithValues: rules.map {
                ($0.bundleID, min(range.upperBound, max(range.lowerBound, $0.dpi)))
            }))
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !rules.contains(where: { $0.bundleID == id }) else { continue }
            rules.append(Rule(bundleID: id, dpi: device.state.dpi ?? 800))
        }
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
        } else {
            Image(systemName: "app.dashed").frame(width: 22, height: 22)
        }
    }
}

// MARK: General

struct GeneralSettings: View {
    @AppStorage("showBatteryInMenuBar") private var showBattery = false
    @AppStorage("lowBatteryAlerts") private var lowBatteryAlerts = true

    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("Show battery percentage next to the icon", isOn: $showBattery)
            }
            Section("Notifications") {
                Toggle("Alert me when a device drops to 15% battery", isOn: $lowBatteryAlerts)
            }
            Section("Startup") {
                LoginItemToggle().toggleStyle(.switch)
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                Link("LogiBar on GitHub", destination: URL(string: "https://github.com/shashankanil/logibar")!)
                Button("Open Backups Folder") { NSWorkspace.shared.open(OnboardBackups.directory) }
            }
        }
        .formStyle(.grouped)
    }
}

struct LoginItemToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at login", isOn: Binding(get: { enabled }) { on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {}
            enabled = SMAppService.mainApp.status == .enabled
        })
    }
}
