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
            MenuBarLabel(manager: manager)
        }
        .menuBarExtraStyle(.window)

        Window("LogiBar", id: "settings") {
            SettingsView(manager: manager)
        }
        .defaultSize(width: 860, height: 680)
        .windowResizability(.contentMinSize)
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
        if let o = s.onboardProfiles { print("  onboard profiles: \(o) stages=\(s.onboardStages) current=\(s.onboardStage.map(String.init) ?? "?")") }
        if let m = d.memory {
            print("  memory: format \(m.descriptor.profileFormat), \(m.descriptor.profileCount) profile(s), \(m.descriptor.buttonCount) buttons, sector size \(m.descriptor.sectorSize), active sector \(m.activeSector)")
            for p in m.profiles {
                let roundTrip = m.rawSectors[p.sector].map { $0 == p.encoded } ?? false
                print("    sector \(p.sector): \(p.reportRateHz) Hz, stages \(p.stages) default #\(p.defaultStage + 1), name '\(p.name)', round-trip ok=\(roundTrip)")
                for (i, b) in p.buttons.enumerated() {
                    let factory = m.factoryProfiles.first?.buttons[i] ?? b
                    print("      \(factory.physicalName(index: i)): \(b.title)")
                }
            }
        }
        if let r = s.wheelRatchet { print("  smartshift: ratchet=\(r) threshold=\(s.smartShiftThreshold ?? -1)") }
        if let h = s.hiRes { print("  wheel: hiRes=\(h) invert=\(s.invertWheel ?? false)") }
        if let f = s.fnSwap { print("  fn swap: \(f)") }
        if s.hostCount > 0 { print("  hosts: \(s.currentHost + 1)/\(s.hostCount)") }
    }
}

/// `LogiBar --snapshot out.png [--light] [--tab overview|memory|apps]` renders the menu panel, or with
/// `--tab` the settings window, using the live devices (used for the README screenshots).
func snapshot(to path: String, dark: Bool, tab: String?) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let manager = DeviceManager.shared
    manager.applySavedPrefs = false
    manager.start()
    RunLoop.main.run(until: Date().addingTimeInterval(5))

    let content: AnyView
    if let tab, let device = manager.devices.first {
        content = AnyView(DeviceDetail(device: device, tab: tab).frame(width: 640, height: 820))
    } else {
        content = AnyView(MenuView(manager: manager))
    }
    let view = content
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, dark ? .dark : .light)
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10_000, y: 0))
    window.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))

    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path)")
}

let arguments = CommandLine.arguments
if arguments.contains("--dump") {
    dumpDevices()
} else if let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count {
    let tab = arguments.firstIndex(of: "--tab").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    snapshot(to: arguments[i + 1], dark: !arguments.contains("--light"), tab: tab)
} else {
    LogiBarApp.main()
}
