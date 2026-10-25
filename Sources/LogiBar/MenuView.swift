import ServiceManagement
import SwiftUI

struct MenuView: View {
    @ObservedObject var manager: DeviceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Logitech Devices").font(.headline)
                Spacer()
                if manager.scanning { ProgressView().controlSize(.small) }
                Button { manager.rescan() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Rescan devices")
            }

            if manager.devices.isEmpty {
                Text("No Logitech devices found. Make sure the receiver is plugged in or the device is paired over Bluetooth, then rescan.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(manager.devices) { DeviceCard(device: $0) }

            Divider()
            LoginItemToggle()
            Button("Quit LogiBar") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 340)
    }
}

struct DeviceCard: View {
    @ObservedObject var device: LogiDevice
    @State private var expanded = true

    var body: some View {
        let s = device.state
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: s.kind.symbol).font(.title3).frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).fontWeight(.medium)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Text(device.online ? s.connection : "\(s.connection) · asleep or off")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let battery = s.battery { BatteryLabel(battery: battery) }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded && device.online {
                DeviceControls(device: device)
                if let error = device.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .opacity(device.online ? 1 : 0.55)
    }
}

struct BatteryLabel: View {
    let battery: Battery

    var body: some View {
        HStack(spacing: 3) {
            if let p = battery.percent { Text("\(p)%").font(.caption).monospacedDigit() }
            Image(systemName: symbol).foregroundStyle(color)
        }
        .help(battery.millivolts.map { "\($0) mV" } ?? "")
    }

    private var symbol: String {
        if battery.charging { return "battery.100.bolt" }
        guard let p = battery.percent else { return "battery.50" }
        switch p {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }

    private var color: Color {
        guard !battery.charging, let p = battery.percent else { return .secondary }
        return p <= 15 ? .red : .secondary
    }
}

struct DeviceControls: View {
    @ObservedObject var device: LogiDevice

    var body: some View {
        let s = device.state
        VStack(alignment: .leading, spacing: 10) {
            if let choices = s.dpiChoices, let dpi = s.dpi {
                DPIControl(device: device, choices: choices, current: dpi)
            }

            if s.reportRates.count > 1, let rate = s.reportRate {
                LabeledContent("Polling rate") {
                    Picker("", selection: Binding(get: { rate }, set: device.setReportRate)) {
                        ForEach(s.reportRates, id: \.self) { Text("\($0) Hz").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }

            if let onboard = s.onboardProfiles {
                Toggle(isOn: Binding(get: { onboard }, set: device.setOnboardProfiles)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Onboard profiles")
                        Text("Turn off so the DPI set here isn't overridden by the mouse's built-in presets.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let ratchet = s.wheelRatchet {
                SmartShiftControl(device: device, ratchet: ratchet, threshold: s.smartShiftThreshold ?? 10)
            }

            if let hiRes = s.hiRes, let invert = s.invertWheel {
                Toggle("Invert scroll direction", isOn: Binding(get: { invert }) { device.setWheel(hiRes: hiRes, invert: $0) })
                Toggle(isOn: Binding(get: { hiRes }) { device.setWheel(hiRes: $0, invert: invert) }) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("High-resolution scrolling")
                        Text("Without Logitech software, macOS may scroll much faster with this on.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let fnSwap = s.fnSwap {
                Toggle(isOn: Binding(get: { fnSwap }, set: device.setFnSwap)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Media keys by default")
                        Text("Hold Fn for F1–F12.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if s.hostCount > 1 {
                LabeledContent("Easy-Switch") {
                    Picker("", selection: Binding(get: { s.currentHost }, set: device.changeHost)) {
                        ForEach(0..<s.hostCount, id: \.self) { Text("\($0 + 1)").tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: CGFloat(s.hostCount) * 36)
                }
                .help("Switch this device to another computer channel")
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(device.busy)
    }
}

struct DPIControl: View {
    @ObservedObject var device: LogiDevice
    let choices: DPIChoices
    let current: Int
    @State private var draft: Double?

    private var presets: [Int] {
        [400, 800, 1600, 3200].filter { choices.values.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("DPI")
                Spacer()
                Text("\(Int(draft ?? Double(current)))").monospacedDigit().foregroundStyle(.secondary)
            }
            if let step = choices.step {
                Slider(
                    value: Binding(
                        get: { draft ?? Double(current) },
                        set: { draft = ($0 / Double(step)).rounded() * Double(step) }
                    ),
                    in: Double(choices.min)...Double(choices.max)
                ) { editing in
                    if !editing, let d = draft { device.setDPI(Int(d)) }
                }
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { p in
                        Button("\(p)") { device.setDPI(p) }
                            .buttonStyle(.bordered)
                            .tint(p == current ? .accentColor : nil)
                    }
                }
            } else {
                Picker("", selection: Binding(get: { current }, set: device.setDPI)) {
                    ForEach(choices.values, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
            }
        }
        .onChange(of: device.busy) { _, busy in if !busy { draft = nil } }
    }
}

struct SmartShiftControl: View {
    @ObservedObject var device: LogiDevice
    let ratchet: Bool
    let threshold: Int
    @State private var draft: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Scroll wheel") {
                Picker("", selection: Binding(get: { ratchet }) { device.setSmartShift(ratchet: $0, threshold: threshold) }) {
                    Text("Ratchet").tag(true)
                    Text("Free spin").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            if ratchet {
                Toggle("SmartShift (auto free-spin)", isOn: Binding(get: { threshold < 255 }) {
                    device.setSmartShift(ratchet: true, threshold: $0 ? 10 : 255)
                })
                if threshold < 255 {
                    HStack {
                        Text("Sensitivity").font(.caption)
                        Slider(value: Binding(get: { draft ?? Double(threshold) }, set: { draft = $0.rounded() }),
                               in: 1...50) { editing in
                            if !editing, let d = draft { device.setSmartShift(ratchet: true, threshold: Int(d)) }
                        }
                    }
                    .help("Higher values need a harder flick before the wheel switches to free spin")
                }
            }
        }
        .onChange(of: device.busy) { _, busy in if !busy { draft = nil } }
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
        .toggleStyle(.checkbox)
    }
}
