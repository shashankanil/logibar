import AppKit
import SwiftUI

struct LogiBarApp: App {
    @StateObject private var manager = DeviceManager.shared

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        DeviceManager.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(manager: manager)
        } label: {
            Image(systemName: manager.menuSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

/// `LogiBar --dump` prints every detected device and its settings without changing anything.
func dumpDevices() {
    let manager = DeviceManager.shared
    manager.applySavedPrefs = false
    manager.start()
    RunLoop.main.run(until: Date().addingTimeInterval(5))
    if manager.devices.isEmpty { print("No HID++ devices found.") }
    for d in manager.devices {
        let s = d.state
        print("\(s.name) [\(s.kind)] via \(s.connection) id=\(d.id) online=\(d.online)")
        if let b = s.battery { print("  battery: \(b.percent.map { "\($0)%" } ?? "?") charging=\(b.charging) mV=\(b.millivolts.map(String.init) ?? "-")") }
        if let dpi = s.dpi, let c = s.dpiChoices { print("  dpi: \(dpi) (\(c.min)–\(c.max), step \(c.step.map(String.init) ?? "list"))") }
        if let r = s.reportRate { print("  polling: \(r) Hz of \(s.reportRates)") }
        if let o = s.onboardProfiles { print("  onboard profiles: \(o)") }
        if let r = s.wheelRatchet { print("  smartshift: ratchet=\(r) threshold=\(s.smartShiftThreshold ?? -1)") }
        if let h = s.hiRes { print("  wheel: hiRes=\(h) invert=\(s.invertWheel ?? false)") }
        if let f = s.fnSwap { print("  fn swap: \(f)") }
        if s.hostCount > 0 { print("  hosts: \(s.currentHost + 1)/\(s.hostCount)") }
    }
}

if CommandLine.arguments.contains("--dump") {
    dumpDevices()
} else {
    LogiBarApp.main()
}
