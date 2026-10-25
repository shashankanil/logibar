import Foundation

// Onboard profile memory (HID++ feature 0x8100), as used by Logitech G mice.
// Layout reverse-engineered by Solaar and libratbag; LogiBar edits known fields in place
// and preserves every other byte (lighting, G-shift, macros) exactly as read.

enum ButtonFunction: UInt8, CaseIterable {
    case none = 0x00, tiltLeft, tiltRight, nextDPI, previousDPI, cycleDPI, defaultDPI, shiftDPI,
         nextProfile, previousProfile, cycleProfile, gShift, batteryStatus, profileSelect, modeSwitch,
         hostButton, scrollDown, scrollUp

    var title: String {
        switch self {
        case .none: return "No action"
        case .tiltLeft: return "Tilt left"
        case .tiltRight: return "Tilt right"
        case .nextDPI: return "Next DPI stage"
        case .previousDPI: return "Previous DPI stage"
        case .cycleDPI: return "Cycle DPI stages"
        case .defaultDPI: return "Default DPI stage"
        case .shiftDPI: return "DPI Shift (hold)"
        case .nextProfile: return "Next profile"
        case .previousProfile: return "Previous profile"
        case .cycleProfile: return "Cycle profiles"
        case .gShift: return "G-Shift"
        case .batteryStatus: return "Show battery status"
        case .profileSelect: return "Select profile"
        case .modeSwitch: return "Mode switch"
        case .hostButton: return "Host button"
        case .scrollDown: return "Scroll down"
        case .scrollUp: return "Scroll up"
        }
    }
}

enum ButtonAction: Hashable {
    case unassigned
    case disabled
    case mouse(UInt16)
    case key(modifiers: UInt8, usage: UInt8)
    case consumer(UInt16)
    case function(ButtonFunction)
    case other([UInt8])

    static let mouseButtons: [(UInt16, String)] = [
        (0x01, "Left click"), (0x02, "Right click"), (0x04, "Middle click"), (0x08, "Back"), (0x10, "Forward"),
    ]

    static let mediaKeys: [(UInt16, String)] = [
        (0xCD, "Play / Pause"), (0xB5, "Next track"), (0xB6, "Previous track"), (0xE2, "Mute"),
        (0xE9, "Volume up"), (0xEA, "Volume down"), (0x6F, "Brightness up"), (0x70, "Brightness down"),
        (0x224, "Browser back"), (0x225, "Browser forward"),
    ]

    init(_ b: [UInt8]) {
        switch (b[0] >> 4, b[1]) {
        case _ where b == [0xFF, 0xFF, 0xFF, 0xFF]: self = .unassigned
        case (0x8, 0x00): self = .disabled
        case (0x8, 0x01): self = .mouse(UInt16(b[2]) << 8 | UInt16(b[3]))
        case (0x8, 0x02): self = .key(modifiers: b[2], usage: b[3])
        case (0x8, 0x03): self = .consumer(UInt16(b[2]) << 8 | UInt16(b[3]))
        case (0x9, _):
            if let f = ButtonFunction(rawValue: b[1]), b[3] == 0 { self = .function(f) } else { self = .other(b) }
        default: self = .other(b)
        }
    }

    var bytes: [UInt8] {
        switch self {
        case .unassigned: return [0xFF, 0xFF, 0xFF, 0xFF]
        case .disabled: return [0x80, 0x00, 0x00, 0x00]
        case .mouse(let m): return [0x80, 0x01, UInt8(m >> 8), UInt8(m & 0xFF)]
        case .key(let mods, let usage): return [0x80, 0x02, mods, usage]
        case .consumer(let c): return [0x80, 0x03, UInt8(c >> 8), UInt8(c & 0xFF)]
        case .function(let f): return [0x90, f.rawValue, 0x00, 0x00]
        case .other(let b): return b
        }
    }

    var title: String {
        switch self {
        case .unassigned: return "Default"
        case .disabled: return "Disabled"
        case .mouse(let m):
            return Self.mouseButtons.first { $0.0 == m }?.1 ?? "Mouse button \(m.trailingZeroBitCount + 1)"
        case .key(let mods, let usage): return KeyCodes.shortcutTitle(modifiers: mods, usage: usage)
        case .consumer(let c): return Self.mediaKeys.first { $0.0 == c }?.1 ?? "Media key 0x\(String(c, radix: 16))"
        case .function(let f): return f.title
        case .other: return "Macro / custom"
        }
    }

    /// Name for a physical button, derived from what it does out of the box.
    func physicalName(index: Int) -> String {
        switch self {
        case .mouse(0x01): return "Left button"
        case .mouse(0x02): return "Right button"
        case .mouse(0x04): return "Wheel click"
        case .mouse(0x08): return "Back side button"
        case .mouse(0x10): return "Forward side button"
        case .function(.cycleDPI), .function(.nextDPI): return "DPI button"
        case .function(.tiltLeft): return "Wheel tilt left"
        case .function(.tiltRight): return "Wheel tilt right"
        case .function(.cycleProfile): return "Profile button"
        default: return "Button \(index + 1)"
        }
    }
}

struct OnboardProfile: Equatable {
    static let stageCount = 5
    var sector: UInt16
    var enabled: Bool
    var bytes: [UInt8]
    let buttonCount: Int

    var reportRateHz: Int {
        get { bytes[0] > 0 ? 1000 / Int(bytes[0]) : 1000 }
        set { bytes[0] = UInt8(max(1, 1000 / max(1, newValue))) }
    }

    var defaultStage: Int {
        get { Int(bytes[1]) }
        set { bytes[1] = UInt8(newValue) }
    }

    var shiftStage: Int {
        get { Int(bytes[2]) }
        set { bytes[2] = UInt8(newValue) }
    }

    /// The configured DPI stages (unused trailing slots are omitted).
    var stages: [Int] {
        get {
            (0..<Self.stageCount).map { Int(bytes[3 + $0 * 2]) | Int(bytes[4 + $0 * 2]) << 8 }
                .prefix { $0 != 0 && $0 != 0xFFFF }.map { $0 }
        }
        set {
            for i in 0..<Self.stageCount {
                let v = i < newValue.count ? newValue[i] : 0
                bytes[3 + i * 2] = UInt8(v & 0xFF)
                bytes[4 + i * 2] = UInt8(v >> 8)
            }
            defaultStage = min(defaultStage, max(0, newValue.count - 1))
            shiftStage = min(shiftStage, max(0, newValue.count - 1))
        }
    }

    var buttons: [ButtonAction] {
        get { (0..<buttonCount).map { ButtonAction(Array(bytes[32 + $0 * 4 ..< 36 + $0 * 4])) } }
        set {
            for (i, action) in newValue.prefix(buttonCount).enumerated() {
                bytes.replaceSubrange(32 + i * 4 ..< 36 + i * 4, with: action.bytes)
            }
        }
    }

    var name: String {
        get {
            var units: [UInt16] = []
            for i in stride(from: 160, to: 208, by: 2) {
                let u = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
                if u == 0 || u == 0xFFFF { break }
                units.append(u)
            }
            return String(decoding: units, as: UTF16.self)
        }
        set {
            let units = Array(newValue.utf16.prefix(24))
            if units.isEmpty, bytes[160..<208].allSatisfy({ $0 == 0xFF }) { return }
            for i in 0..<24 {
                let u = i < units.count ? units[i] : 0
                bytes[160 + i * 2] = UInt8(u & 0xFF)
                bytes[161 + i * 2] = UInt8(u >> 8)
            }
        }
    }

    /// Bytes ready to write: same layout with a fresh CRC in the last two bytes.
    var encoded: [UInt8] {
        var out = bytes
        let crc = crc16(out.dropLast(2))
        out[out.count - 2] = UInt8(crc >> 8)
        out[out.count - 1] = UInt8(crc & 0xFF)
        return out
    }
}

struct OnboardDescriptor: Equatable {
    var profileFormat: Int
    var profileCount: Int
    var buttonCount: Int
    var sectorCount: Int
    var sectorSize: Int

    /// Formats whose layout is known; others are shown read-only.
    var editable: Bool { (1...4).contains(profileFormat) && sectorSize >= 255 }
}

struct OnboardMemory: Equatable {
    var descriptor: OnboardDescriptor
    var profiles: [OnboardProfile]
    var factoryProfiles: [OnboardProfile]
    var activeSector: UInt16
    /// Raw sectors exactly as read from flash, kept for backups.
    var rawSectors: [UInt16: [UInt8]]

    /// Flash sector a profile is written to. ROM profiles (sector >= 0x100) get copied to flash first.
    func flashSector(forProfileAt index: Int) -> UInt16 {
        let s = profiles[index].sector
        return s > 0 && Int(s) < descriptor.sectorCount ? s : UInt16(index + 1)
    }
}

func crc16<C: Collection>(_ data: C) -> UInt16 where C.Element == UInt8 {
    var crc: UInt16 = 0xFFFF
    for byte in data {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
    }
    return crc
}

extension HIDPPDevice {
    func readOnboardDescriptor() throws -> OnboardDescriptor {
        let d = try call(Feature.onboardProfiles, 0)
        return OnboardDescriptor(profileFormat: Int(d[1]), profileCount: Int(d[3]), buttonCount: Int(d[5]),
                                 sectorCount: Int(d[6]), sectorSize: Int(d[7]) << 8 | Int(d[8]))
    }

    func readSector(_ sector: UInt16, size: Int) throws -> [UInt8] {
        func chunk(_ offset: Int) throws -> [UInt8] {
            try call(Feature.onboardProfiles, 5, [UInt8(sector >> 8), UInt8(sector & 0xFF), UInt8(offset >> 8), UInt8(offset & 0xFF)])
        }
        var out: [UInt8] = []
        var offset = 0
        while offset <= size - 16 {
            out += try chunk(offset).prefix(16)
            offset += 16
        }
        if out.count < size {
            // Reads can't run past the end of a sector, so the tail is read from (size - 16).
            out += try chunk(size - 16).suffix(size - out.count)
        }
        return out
    }

    func writeSector(_ sector: UInt16, _ bytes: [UInt8]) throws {
        try call(Feature.onboardProfiles, 6, [UInt8(sector >> 8), UInt8(sector & 0xFF), 0, 0,
                                              UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
        var offset = 0
        while offset < bytes.count {
            var chunk = Array(bytes[offset..<min(offset + 16, bytes.count)])
            chunk += [UInt8](repeating: 0, count: 16 - chunk.count)
            try call(Feature.onboardProfiles, 7, chunk)
            offset += 16
        }
        try call(Feature.onboardProfiles, 8)
    }

    private func headerEntries(_ bytes: [UInt8]) -> [(sector: UInt16, enabled: Bool)] {
        var entries: [(UInt16, Bool)] = []
        var i = 0
        while i + 3 < bytes.count - 2 {
            let sector = UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
            if sector == 0xFFFF || sector == 0 { break }
            entries.append((sector, bytes[i + 2] != 0))
            i += 4
        }
        return entries
    }

    func readOnboardMemory() throws -> OnboardMemory {
        let d = try readOnboardDescriptor()
        let size = d.sectorSize
        var raw: [UInt16: [UInt8]] = [:]

        func profiles(from entries: [(sector: UInt16, enabled: Bool)]) throws -> [OnboardProfile] {
            try entries.prefix(d.profileCount).map { e in
                let bytes = try readSector(e.sector, size: size)
                if e.sector < 0x100 { raw[e.sector] = bytes }
                return OnboardProfile(sector: e.sector, enabled: e.enabled, bytes: bytes, buttonCount: d.buttonCount)
            }
        }

        let romHeader = try readSector(0x0100, size: size)
        let factory = try profiles(from: headerEntries(romHeader))

        let flashHeader = try readSector(0x0000, size: size)
        raw[0] = flashHeader
        let flashValid = crc16(flashHeader.dropLast(2)) == (UInt16(flashHeader[size - 2]) << 8 | UInt16(flashHeader[size - 1]))
        var current = flashValid ? try profiles(from: headerEntries(flashHeader)) : []
        if current.isEmpty { current = factory }

        let active = try call(Feature.onboardProfiles, 4)
        return OnboardMemory(descriptor: d, profiles: current, factoryProfiles: factory,
                             activeSector: UInt16(active[0]) << 8 | UInt16(active[1]), rawSectors: raw)
    }

    /// Writes edited profiles to flash (profiles first, then the header that points at them),
    /// verifies each sector by reading it back, and reloads the active profile.
    func writeOnboard(_ memory: OnboardMemory, profiles edited: [OnboardProfile], activeIndex: Int) throws {
        let size = memory.descriptor.sectorSize
        var header: [UInt8] = []
        for (i, profile) in edited.enumerated() {
            let target = memory.flashSector(forProfileAt: i)
            let bytes = profile.encoded
            if memory.rawSectors[target] != bytes {
                try writeSector(target, bytes)
                guard try readSector(target, size: size) == bytes else {
                    throw OnboardError.verifyFailed(target)
                }
            }
            header += [UInt8(target >> 8), UInt8(target & 0xFF), profile.enabled ? 1 : 0, 0]
        }
        header += [UInt8](repeating: 0xFF, count: size - 2 - header.count)
        header += [0, 0]
        let crc = crc16(header.dropLast(2))
        header[size - 2] = UInt8(crc >> 8)
        header[size - 1] = UInt8(crc & 0xFF)
        if memory.rawSectors[0] != header {
            try writeSector(0, header)
            guard try readSector(0, size: size) == header else { throw OnboardError.verifyFailed(0) }
        }

        let active = memory.flashSector(forProfileAt: activeIndex)
        try call(Feature.onboardProfiles, 3, [UInt8(active >> 8), UInt8(active & 0xFF)])
        memoryCache = nil
    }

    /// Writes raw sectors from a backup back to flash.
    func restoreSectors(_ sectors: [UInt16: [UInt8]], descriptor: OnboardDescriptor) throws {
        for (sector, bytes) in sectors.sorted(by: { $0.key > $1.key }) {
            guard Int(sector) < descriptor.sectorCount, bytes.count == descriptor.sectorSize,
                  crc16(bytes.dropLast(2)) == (UInt16(bytes[bytes.count - 2]) << 8 | UInt16(bytes[bytes.count - 1]))
            else { continue }
            try writeSector(sector, bytes)
        }
        let active = try call(Feature.onboardProfiles, 4)
        try call(Feature.onboardProfiles, 3, [active[0], active[1]])
        memoryCache = nil
    }

    func currentDPIStage() throws -> Int { Int(try call(Feature.onboardProfiles, 0xB)[0]) }
    func setDPIStage(_ index: Int) throws { try call(Feature.onboardProfiles, 0xC, [UInt8(index)]) }
}

enum OnboardError: Error, CustomStringConvertible {
    case verifyFailed(UInt16)
    case noLeftClick

    var description: String {
        switch self {
        case .verifyFailed(let s): return "sector \(s) did not read back correctly; restore from the automatic backup"
        case .noLeftClick: return "at least one button must stay mapped to Left click"
        }
    }
}

/// Automatic and manual backups of raw onboard memory, stored as JSON.
enum OnboardBackups {
    struct File: Codable {
        var device: String
        var created: Date
        var sectors: [String: String]
    }

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LogiBar/Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func encode(_ memory: OnboardMemory, device: String) throws -> Data {
        let sectors = Dictionary(uniqueKeysWithValues: memory.rawSectors.map {
            (String($0.key), $0.value.map { String(format: "%02x", $0) }.joined())
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(File(device: device, created: Date(), sectors: sectors))
    }

    @discardableResult
    static func saveAutomatic(_ memory: OnboardMemory, device: String) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safeName = device.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(safeName) \(stamp).json")
        try encode(memory, device: device).write(to: url)
        return url
    }

    static func load(_ url: URL) throws -> [UInt16: [UInt8]] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(File.self, from: Data(contentsOf: url))
        var out: [UInt16: [UInt8]] = [:]
        for (key, hex) in file.sectors {
            guard let sector = UInt16(key) else { continue }
            var bytes: [UInt8] = []
            var i = hex.startIndex
            while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex),
                  let b = UInt8(hex[i..<j], radix: 16) {
                bytes.append(b)
                i = j
            }
            out[sector] = bytes
        }
        return out
    }
}
