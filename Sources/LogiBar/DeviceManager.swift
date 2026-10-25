import AppKit
import Foundation
import IOKit.hid

/// Settings the user changed, re-applied whenever the device reconnects or wakes
/// (many Logitech devices forget host-set values after a power cycle).
struct DevicePrefs: Codable {
    var dpi: Int?
    var reportRate: Int?
    var ratchet: Bool?
    var smartShift: Int?
    var hiRes: Bool?
    var invert: Bool?
    var fnSwap: Bool?
    var onboard: Bool?
}

enum PrefStore {
    static func load(_ key: String) -> DevicePrefs {
        guard let data = UserDefaults.standard.data(forKey: "prefs.\(key)"),
              let prefs = try? JSONDecoder().decode(DevicePrefs.self, from: data) else { return DevicePrefs() }
        return prefs
    }

    static func update(_ key: String, _ change: (inout DevicePrefs) -> Void) {
        var prefs = load(key)
        change(&prefs)
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: "prefs.\(key)")
        }
    }
}

/// UI-facing model for one device.
final class LogiDevice: ObservableObject, Identifiable {
    let id: String
    @Published var state: DeviceState
    @Published var online = true
    @Published var busy = false
    @Published var lastError: String?
    var hw: HIDPPDevice
    weak var manager: DeviceManager?

    init(id: String, hw: HIDPPDevice, state: DeviceState, manager: DeviceManager) {
        self.id = id
        self.hw = hw
        self.state = state
        self.manager = manager
    }

    func setDPI(_ v: Int) { run("DPI", save: { $0.dpi = v }) { try $0.setDPI(v) } }
    func setReportRate(_ hz: Int) { run("Polling rate", save: { $0.reportRate = hz }) { try $0.setReportRate(hz) } }
    func setOnboardProfiles(_ on: Bool) { run("Onboard profiles", save: { $0.onboard = on }) { try $0.setOnboardProfiles(on) } }
    func setFnSwap(_ on: Bool) { run("Fn keys", save: { $0.fnSwap = on }) { try $0.setFnSwap(on) } }

    func setSmartShift(ratchet: Bool, threshold: Int) {
        run("SmartShift", save: { $0.ratchet = ratchet; $0.smartShift = threshold }) {
            try $0.setSmartShift(ratchet: ratchet, threshold: threshold)
        }
    }

    func setWheel(hiRes: Bool, invert: Bool) {
        run("Scroll wheel", save: { $0.hiRes = hiRes; $0.invert = invert }) { try $0.setWheel(hiRes: hiRes, invert: invert) }
    }

    func changeHost(_ host: Int) {
        guard let manager else { return }
        let hw = self.hw
        online = false
        manager.queue.async { hw.changeHost(host) }
    }

    private func run(_ what: String, save: @escaping (inout DevicePrefs) -> Void,
                     _ operation: @escaping (HIDPPDevice) throws -> Void) {
        guard let manager else { return }
        let hw = self.hw, key = id, connection = state.connection
        busy = true
        manager.queue.async { [weak self] in
            let result = Result { try operation(hw) }
            if case .success = result { PrefStore.update(key, save) }
            let newState = hw.readState(connection: connection)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.state = newState
                if case .failure(let error) = result {
                    self.lastError = "\(what): \(error)"
                } else {
                    self.lastError = nil
                }
            }
        }
    }
}

private final class HIDRunLoopThread: Thread {
    private let setup: () -> Void

    init(setup: @escaping () -> Void) {
        self.setup = setup
        super.init()
        name = "LogiBar.HID"
    }

    override func main() {
        setup()
        RunLoop.current.add(Port(), forMode: .default)
        RunLoop.current.run()
    }
}

final class DeviceManager: ObservableObject {
    static let shared = DeviceManager()

    @Published private(set) var devices: [LogiDevice] = []
    @Published private(set) var scanning = false

    /// All HID++ traffic happens on this queue; IOKit callbacks arrive on the HID thread.
    let queue = DispatchQueue(label: "LogiBar.work")
    var applySavedPrefs = true

    private var hidManager: IOHIDManager?
    private var thread: HIDRunLoopThread?
    private var timer: Timer?

    // Work-queue state.
    private var transports: [UInt64: HIDPPTransport] = [:]
    private var slots: [String: (hw: HIDPPDevice, key: String)] = [:]
    private var scheduledScans = Set<UInt64>()
    private var activeScans = 0

    var menuSymbol: String {
        let low = devices.contains { d in
            guard d.online, let b = d.state.battery, let p = b.percent else { return false }
            return p <= 15 && !b.charging
        }
        return low ? "battery.25" : "computermouse"
    }

    func start() {
        let thread = HIDRunLoopThread { [weak self] in self?.setupHID() }
        self.thread = thread
        thread.start()

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.rescan() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 3) { self?.scanAll() }
        }
    }

    func rescan() {
        queue.async { self.scanAll() }
    }

    // MARK: HID thread

    private func setupHID() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = [
            [kIOHIDVendorIDKey: 0x046D, kIOHIDDeviceUsagePageKey: 0xFF00],
            [kIOHIDVendorIDKey: 0x046D, kIOHIDDeviceUsagePageKey: 0xFF43],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<DeviceManager>.fromOpaque(context!).takeUnretainedValue().deviceAdded(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<DeviceManager>.fromOpaque(context!).takeUnretainedValue().deviceRemoved(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        let transport = HIDPPTransport(device: device)
        transport.onNotification = { [weak self, weak transport] report in
            guard let self, let transport else { return }
            self.queue.async { self.handleNotification(transport, report) }
        }
        transport.startListening()
        debugLog("matched \(transport.product) pid=\(String(transport.productID, radix: 16)) transport=\(transport.transportName)")
        queue.async {
            self.transports[transport.id] = transport
            self.scan(transport)
        }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entryID)
        queue.async {
            guard let transport = self.transports.removeValue(forKey: entryID) else { return }
            for (slot, value) in self.slots where value.hw.transport === transport {
                self.markOffline(slot)
            }
        }
    }

    // MARK: Work queue

    private func slotID(_ t: HIDPPTransport, _ index: UInt8) -> String { "\(t.id)-\(index)" }

    private func handleNotification(_ t: HIDPPTransport, _ r: [UInt8]) {
        // HID++ 1.0 "device connection" notification from a receiver.
        guard r.count >= 5, r[2] == 0x41 else { return }
        if r[4] & 0x40 != 0 {
            markOffline(slotID(t, r[1]))
        } else if scheduledScans.insert(t.id).inserted {
            queue.asyncAfter(deadline: .now() + 1) {
                self.scheduledScans.remove(t.id)
                self.scan(t)
            }
        }
    }

    private func scanAll() {
        for t in transports.values { scan(t) }
    }

    private func setScanning(_ delta: Int) {
        activeScans += delta
        let scanning = activeScans > 0
        DispatchQueue.main.async { self.scanning = scanning }
    }

    private func scan(_ t: HIDPPTransport) {
        setScanning(1)
        defer { setScanning(-1) }

        if t.mode == .unknown {
            do {
                if try HIDPPDevice(transport: t, index: 0xFF).ping().major >= 2 { t.mode = .direct }
            } catch HIDPPError.hidpp10 {
                t.mode = .receiver
            } catch {
                if t.product.localizedCaseInsensitiveContains("receiver") { t.mode = .receiver }
            }
            if t.mode == .receiver { t.enableReceiverNotifications() }
        }

        debugLog("\(t.product): mode \(t.mode)")
        let indices: [UInt8]
        switch t.mode {
        case .direct: indices = [0xFF]
        case .receiver: indices = Array(1...6)
        case .unknown: indices = []
        }

        for index in indices {
            let sid = slotID(t, index)
            if let slot = slots[sid] {
                if (try? slot.hw.ping()) != nil {
                    let battery = try? slot.hw.readBattery()
                    update(slot.key) { $0.state.battery = battery }
                } else {
                    markOffline(sid)
                }
                continue
            }

            let hw = HIDPPDevice(transport: t, index: index)
            let version: (major: UInt8, minor: UInt8)
            do { version = try hw.ping() } catch { debugLog("  index \(index): \(error)"); continue }
            guard version.major >= 2 else { continue }
            let connection = connectionLabel(t, index)
            var state = hw.readState(connection: connection)
            let key = ((try? hw.readUnitKey()) ?? nil) ?? "\(t.productID)-\(index)-\(state.name)"
            // Same physical device seen through a second HID interface.
            if slots.values.contains(where: { $0.key == key }) { continue }

            if applySavedPrefs, applyPrefs(hw, state: state, key: key) {
                state = hw.readState(connection: connection)
            }
            slots[sid] = (hw, key)
            publish(key: key, hw: hw, state: state)
        }
    }

    private func applyPrefs(_ hw: HIDPPDevice, state s: DeviceState, key: String) -> Bool {
        let p = PrefStore.load(key)
        var applied = false
        func apply(_ body: () throws -> Void) { if (try? body()) != nil { applied = true } }

        if let v = p.onboard, s.onboardProfiles != nil { apply { try hw.setOnboardProfiles(v) } }
        if let v = p.dpi, s.dpi != nil { apply { try hw.setDPI(v) } }
        if let v = p.reportRate, s.reportRates.contains(v) { apply { try hw.setReportRate(v) } }
        if let r = p.ratchet, s.wheelRatchet != nil {
            apply { try hw.setSmartShift(ratchet: r, threshold: p.smartShift ?? s.smartShiftThreshold ?? 10) }
        }
        if let hiRes = s.hiRes, let invert = s.invertWheel, p.hiRes != nil || p.invert != nil {
            apply { try hw.setWheel(hiRes: p.hiRes ?? hiRes, invert: p.invert ?? invert) }
        }
        if let v = p.fnSwap, s.fnSwap != nil { apply { try hw.setFnSwap(v) } }
        return applied
    }

    private func connectionLabel(_ t: HIDPPTransport, _ index: UInt8) -> String {
        if index == 0xFF {
            return t.transportName.localizedCaseInsensitiveContains("bluetooth") ? "Bluetooth" : "USB cable"
        }
        switch t.productID {
        case 0xC548: return "Bolt receiver"
        case 0xC52B, 0xC532: return "Unifying receiver"
        case 0xC539, 0xC53A, 0xC53D, 0xC53F, 0xC541, 0xC545, 0xC547, 0xC54D: return "Lightspeed receiver"
        default: return t.product
        }
    }

    private func markOffline(_ sid: String) {
        guard let slot = slots.removeValue(forKey: sid) else { return }
        update(slot.key) { $0.online = false }
    }

    private func update(_ key: String, _ change: @escaping (LogiDevice) -> Void) {
        DispatchQueue.main.async {
            if let device = self.devices.first(where: { $0.id == key }) { change(device) }
        }
    }

    private func publish(key: String, hw: HIDPPDevice, state: DeviceState) {
        DispatchQueue.main.async {
            if let device = self.devices.first(where: { $0.id == key }) {
                device.hw = hw
                device.state = state
                device.online = true
            } else {
                self.devices.append(LogiDevice(id: key, hw: hw, state: state, manager: self))
            }
        }
    }
}

func debugLog(_ message: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["LOGIBAR_DEBUG"] != nil { print("[LogiBar] " + message()) }
}
