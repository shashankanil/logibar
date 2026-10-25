import Foundation

/// HID++ 2.0 feature IDs used by LogiBar.
enum Feature {
    static let root: UInt16 = 0x0000
    static let deviceInfo: UInt16 = 0x0003
    static let deviceName: UInt16 = 0x0005
    static let batteryStatus: UInt16 = 0x1000
    static let batteryVoltage: UInt16 = 0x1001
    static let unifiedBattery: UInt16 = 0x1004
    static let changeHost: UInt16 = 0x1814
    static let smartShift: UInt16 = 0x2110
    static let smartShiftEnhanced: UInt16 = 0x2111
    static let hiResWheel: UInt16 = 0x2121
    static let adjustableDPI: UInt16 = 0x2201
    static let fnInversion: UInt16 = 0x40A0
    static let newFnInversion: UInt16 = 0x40A2
    static let k375sFnInversion: UInt16 = 0x40A3
    static let reportRate: UInt16 = 0x8060
    static let extendedReportRate: UInt16 = 0x8061
    static let onboardProfiles: UInt16 = 0x8100
}

enum DeviceKind: Int {
    case keyboard = 0, remote, numpad, mouse, trackpad, trackball, presenter, receiver,
         headset, webcam, steeringWheel, joystick, gamepad, dock, speaker, microphone
    case unknown = 255

    var symbol: String {
        switch self {
        case .keyboard, .numpad: return "keyboard"
        case .mouse, .trackball: return "computermouse"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .presenter, .remote: return "av.remote"
        case .receiver, .dock: return "dot.radiowaves.left.and.right"
        case .headset: return "headphones"
        case .webcam: return "web.camera"
        case .steeringWheel, .joystick, .gamepad: return "gamecontroller"
        case .speaker: return "hifispeaker"
        case .microphone: return "mic"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct Battery: Equatable {
    var percent: Int?
    var charging = false
    var millivolts: Int?
}

struct DPIChoices: Equatable {
    var values: [Int]
    /// Set when the values form a single evenly spaced range (shown as a slider).
    var step: Int?
    var min: Int { values.first ?? 0 }
    var max: Int { values.last ?? 0 }
}

struct DeviceState: Equatable {
    var name = "Logitech device"
    var kind: DeviceKind = .unknown
    var connection = ""
    var battery: Battery?
    var dpi: Int?
    var dpiChoices: DPIChoices?
    var reportRate: Int?
    var reportRates: [Int] = []
    var wheelRatchet: Bool?
    var smartShiftThreshold: Int?
    var hiRes: Bool?
    var invertWheel: Bool?
    var fnSwap: Bool?
    var hostCount = 0
    var currentHost = 0
    var onboardProfiles: Bool?
}

/// A single HID++ 2.0 device behind a transport (device index 1–6 on a receiver, 0xFF when direct).
/// Not thread safe: only use it from DeviceManager's work queue.
final class HIDPPDevice {
    let transport: HIDPPTransport
    let index: UInt8
    private var featureIndices: [UInt16: UInt8?] = [:]

    private static let extendedRates = [125, 250, 500, 1000, 2000, 4000, 8000]

    init(transport: HIDPPTransport, index: UInt8) {
        self.transport = transport
        self.index = index
    }

    /// Returns the HID++ protocol version (major, minor).
    func ping() throws -> (major: UInt8, minor: UInt8) {
        let r = try transport.request(device: index, feature: 0, function: 1, params: [0, 0, 0xAA], timeout: 0.6)
        return (r[0], r[1])
    }

    func featureIndex(_ feature: UInt16) throws -> UInt8? {
        if let cached = featureIndices[feature] { return cached }
        let r = try transport.request(device: index, feature: 0, function: 0,
                                      params: [UInt8(feature >> 8), UInt8(feature & 0xFF)])
        let idx: UInt8? = r[0] == 0 ? nil : r[0]
        featureIndices[feature] = idx
        return idx
    }

    func has(_ feature: UInt16) -> Bool {
        ((try? featureIndex(feature)) ?? nil) != nil
    }

    @discardableResult
    func call(_ feature: UInt16, _ function: UInt8, _ params: [UInt8] = [], timeout: TimeInterval = 1.0) throws -> [UInt8] {
        guard let idx = try featureIndex(feature) else { throw HIDPPError.unsupported(feature) }
        return try transport.request(device: index, feature: idx, function: function, params: params, timeout: timeout)
    }

    // MARK: Reading

    func readName() throws -> String {
        let length = Int(try call(Feature.deviceName, 0)[0])
        var bytes: [UInt8] = []
        while bytes.count < length {
            bytes += try call(Feature.deviceName, 1, [UInt8(bytes.count)]).prefix(length - bytes.count)
        }
        return String(decoding: bytes.filter { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// Stable identity for saving preferences: the unit ID when the device reports one.
    func readUnitKey() throws -> String? {
        let r = try call(Feature.deviceInfo, 0)
        let unit = r[1..<5]
        guard unit.contains(where: { $0 != 0 }) else { return nil }
        return "unit-" + unit.map { String(format: "%02x", $0) }.joined()
    }

    func readBattery() throws -> Battery? {
        if has(Feature.unifiedBattery) {
            let r = try call(Feature.unifiedBattery, 1)
            let levelPercent: Int? = r[1] & 8 != 0 ? 90 : r[1] & 4 != 0 ? 50 : r[1] & 2 != 0 ? 20 : r[1] & 1 != 0 ? 5 : nil
            return Battery(percent: r[0] > 0 ? Int(r[0]) : levelPercent, charging: r[2] == 1 || r[2] == 2)
        }
        if has(Feature.batteryStatus) {
            let r = try call(Feature.batteryStatus, 0)
            return Battery(percent: r[0] > 0 ? Int(r[0]) : nil, charging: (1...4).contains(r[2]))
        }
        if has(Feature.batteryVoltage) {
            let r = try call(Feature.batteryVoltage, 0)
            let mv = Int(r[0]) << 8 | Int(r[1])
            return Battery(percent: Self.estimatePercent(millivolts: mv), charging: r[2] & 0x80 != 0, millivolts: mv)
        }
        return nil
    }

    private static func estimatePercent(millivolts mv: Int) -> Int {
        if mv < 2500 {
            // Single AA/AAA cell (e.g. G304, G305): roughly 1.0 V empty to 1.5 V full.
            return Swift.max(0, Swift.min(100, (mv - 1000) / 5))
        }
        // Li-ion discharge curve.
        let table: [(Int, Int)] = [(4186, 100), (4067, 90), (3989, 80), (3922, 70), (3859, 60), (3811, 50),
                                   (3778, 40), (3751, 30), (3717, 20), (3671, 10), (3646, 5), (3579, 2), (3500, 0)]
        for (i, (v, p)) in table.enumerated() where mv >= v {
            guard i > 0 else { return 100 }
            let (hv, hp) = table[i - 1]
            return p + (mv - v) * (hp - p) / (hv - v)
        }
        return 0
    }

    func readState(connection: String) -> DeviceState {
        var s = DeviceState()
        s.connection = connection
        func attempt(_ body: () throws -> Void) { do { try body() } catch {} }

        attempt { let n = try readName(); if !n.isEmpty { s.name = n } }
        attempt { s.kind = DeviceKind(rawValue: Int(try call(Feature.deviceName, 2)[0])) ?? .unknown }
        attempt { s.battery = try readBattery() }

        if has(Feature.adjustableDPI) {
            attempt { s.dpiChoices = Self.parseDPIList(try call(Feature.adjustableDPI, 1, [0])) }
            attempt {
                let r = try call(Feature.adjustableDPI, 2, [0])
                s.dpi = Int(r[1]) << 8 | Int(r[2])
            }
        }

        if has(Feature.extendedReportRate) {
            attempt {
                let r = try call(Feature.extendedReportRate, 1)
                let mask = Int(r[0]) << 8 | Int(r[1])
                s.reportRates = Self.extendedRates.indices.filter { mask & (1 << $0) != 0 }.map { Self.extendedRates[$0] }
                let cur = Int(try call(Feature.extendedReportRate, 2)[0])
                if cur < Self.extendedRates.count { s.reportRate = Self.extendedRates[cur] }
            }
        } else if has(Feature.reportRate) {
            attempt {
                let mask = try call(Feature.reportRate, 0)[0]
                s.reportRates = (0..<8).filter { mask & (1 << $0) != 0 }.map { 1000 / ($0 + 1) }.sorted()
                let ms = Int(try call(Feature.reportRate, 1)[0])
                if ms > 0 { s.reportRate = 1000 / ms }
            }
        }

        if has(Feature.smartShiftEnhanced) {
            attempt {
                let r = try call(Feature.smartShiftEnhanced, 1)
                s.wheelRatchet = r[0] == 2
                s.smartShiftThreshold = Int(r[1])
            }
        } else if has(Feature.smartShift) {
            attempt {
                let r = try call(Feature.smartShift, 0)
                s.wheelRatchet = r[0] == 2
                s.smartShiftThreshold = Int(r[1])
            }
        }

        if has(Feature.hiResWheel) {
            attempt {
                let flags = try call(Feature.hiResWheel, 1)[0]
                s.hiRes = flags & 0x02 != 0
                s.invertWheel = flags & 0x04 != 0
            }
        }

        attempt { s.fnSwap = try readFnSwap() }

        if has(Feature.changeHost) {
            attempt {
                let r = try call(Feature.changeHost, 0)
                s.hostCount = Int(r[0])
                s.currentHost = Int(r[1])
            }
        }

        if has(Feature.onboardProfiles) {
            attempt { s.onboardProfiles = try call(Feature.onboardProfiles, 2)[0] == 1 }
        }
        return s
    }

    private func readFnSwap() throws -> Bool? {
        if has(Feature.fnInversion) { return try call(Feature.fnInversion, 0)[0] & 1 != 0 }
        if has(Feature.newFnInversion) { return try call(Feature.newFnInversion, 0)[0] & 1 != 0 }
        if has(Feature.k375sFnInversion) { return try call(Feature.k375sFnInversion, 0, [0xFF])[1] & 1 != 0 }
        return nil
    }

    /// Expands the 0x2201 DPI list: plain values, or `start, 0xE000|step, end` ranges.
    static func parseDPIList(_ r: [UInt8]) -> DPIChoices? {
        var raw: [Int] = []
        var i = 1
        while i + 1 < r.count {
            let v = Int(r[i]) << 8 | Int(r[i + 1])
            if v == 0 { break }
            raw.append(v)
            i += 2
        }
        var values: [Int] = []
        var steps = Set<Int>()
        var j = 0
        while j < raw.count {
            let v = raw[j]
            if v >> 13 == 0b111, let start = values.last, j + 1 < raw.count {
                let step = v & 0x1FFF
                if step > 0 {
                    steps.insert(step)
                    values += Array(stride(from: start + step, through: raw[j + 1], by: step))
                }
                j += 2
            } else {
                values.append(v)
                j += 1
            }
        }
        guard !values.isEmpty else { return nil }
        return DPIChoices(values: values, step: steps.count == 1 && raw.count == 3 ? steps.first : nil)
    }

    // MARK: Writing

    func setDPI(_ dpi: Int) throws {
        try call(Feature.adjustableDPI, 3, [0, UInt8(dpi >> 8), UInt8(dpi & 0xFF)])
    }

    func setReportRate(_ hz: Int) throws {
        if has(Feature.extendedReportRate), let idx = Self.extendedRates.firstIndex(of: hz) {
            try call(Feature.extendedReportRate, 3, [UInt8(idx)])
        } else {
            try call(Feature.reportRate, 2, [UInt8(1000 / hz)])
        }
    }

    func setSmartShift(ratchet: Bool, threshold: Int) throws {
        let params: [UInt8] = [ratchet ? 2 : 1, UInt8(max(1, min(255, threshold))), 0]
        if has(Feature.smartShiftEnhanced) {
            try call(Feature.smartShiftEnhanced, 2, params)
        } else {
            try call(Feature.smartShift, 1, params)
        }
    }

    func setWheel(hiRes: Bool, invert: Bool) throws {
        // Bit 0 (divert to HID++) stays clear so scrolling keeps working normally.
        try call(Feature.hiResWheel, 2, [(hiRes ? 0x02 : 0) | (invert ? 0x04 : 0)])
    }

    func setFnSwap(_ on: Bool) throws {
        let v: UInt8 = on ? 1 : 0
        if has(Feature.fnInversion) { try call(Feature.fnInversion, 1, [v]) }
        else if has(Feature.newFnInversion) { try call(Feature.newFnInversion, 1, [v]) }
        else { try call(Feature.k375sFnInversion, 1, [0xFF, v]) }
    }

    func setOnboardProfiles(_ on: Bool) throws {
        try call(Feature.onboardProfiles, 1, [on ? 1 : 2])
    }

    /// Switches the device to another Easy-Switch channel. It disconnects immediately, so no reply is expected.
    func changeHost(_ host: Int) {
        _ = try? call(Feature.changeHost, 1, [UInt8(host)], timeout: 0.3)
    }
}
