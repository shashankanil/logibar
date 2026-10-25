import Foundation
import IOKit
import IOKit.hid

enum HIDPPError: Error, CustomStringConvertible {
    case timeout
    case hidpp10(UInt8)
    case hidpp20(UInt8)
    case unsupported(UInt16)
    case io(IOReturn)

    var description: String {
        switch self {
        case .timeout: return "device did not respond"
        case .hidpp10(let e): return "receiver error 0x\(String(e, radix: 16))"
        case .hidpp20(let e): return "device error 0x\(String(e, radix: 16))"
        case .unsupported(let f): return "feature 0x\(String(f, radix: 16)) not supported"
        case .io(let r): return "I/O error 0x\(String(UInt32(bitPattern: r), radix: 16))"
        }
    }
}

/// One HID interface that speaks HID++ (a receiver, or a device connected directly over USB/Bluetooth).
/// Requests are synchronous and must not be issued from the HID run-loop thread.
final class HIDPPTransport {
    enum Mode { case unknown, direct, receiver }

    let device: IOHIDDevice
    let id: UInt64
    let product: String
    let productID: Int
    let transportName: String
    var mode: Mode = .unknown
    var onNotification: (([UInt8]) -> Void)?

    private struct Pending {
        let match: ([UInt8]) -> Result<[UInt8], HIDPPError>?
        let sem: DispatchSemaphore
        var result: Result<[UInt8], HIDPPError>?
    }

    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let requestLock = NSLock()
    private let stateLock = NSLock()
    private var pending: Pending?
    private var notificationsEnabled = false
    private static let swid: UInt8 = 0x0B

    init(device: IOHIDDevice) {
        self.device = device
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entryID)
        id = entryID
        product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Logitech device"
        productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        transportName = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
    }

    deinit {
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
        buffer.deallocate()
    }

    func startListening() {
        let callback: IOHIDReportCallback = { context, _, _, _, _, report, length in
            guard let context else { return }
            let transport = Unmanaged<HIDPPTransport>.fromOpaque(context).takeUnretainedValue()
            transport.handleInput(Array(UnsafeBufferPointer(start: report, count: length)))
        }
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, callback, Unmanaged.passUnretained(self).toOpaque())
    }

    private func handleInput(_ report: [UInt8]) {
        stateLock.lock()
        if var p = pending, case .none = p.result, let result = p.match(report) {
            p.result = result
            pending = p
            stateLock.unlock()
            p.sem.signal()
            return
        }
        stateLock.unlock()
        onNotification?(report)
    }

    private func exchange(_ message: [UInt8], timeout: TimeInterval,
                          match: @escaping ([UInt8]) -> Result<[UInt8], HIDPPError>?) throws -> [UInt8] {
        requestLock.lock()
        defer { requestLock.unlock() }

        let sem = DispatchSemaphore(value: 0)
        stateLock.lock()
        pending = Pending(match: match, sem: sem)
        stateLock.unlock()
        defer {
            stateLock.lock()
            pending = nil
            stateLock.unlock()
        }

        let rc = message.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(message[0]), $0.baseAddress!, $0.count)
        }
        guard rc == kIOReturnSuccess else { throw HIDPPError.io(rc) }
        guard sem.wait(timeout: .now() + timeout) == .success else { throw HIDPPError.timeout }

        stateLock.lock()
        let result = pending?.result
        stateLock.unlock()
        guard let result else { throw HIDPPError.timeout }
        return try result.get()
    }

    /// HID++ 2.0 feature call using a long (20-byte) report. Returns the 16 parameter bytes of the reply.
    func request(device index: UInt8, feature: UInt8, function: UInt8, params: [UInt8] = [],
                 timeout: TimeInterval = 1.0) throws -> [UInt8] {
        let fnByte = (function << 4) | Self.swid
        var message: [UInt8] = [0x11, index, feature, fnByte] + params
        message += [UInt8](repeating: 0, count: max(0, 20 - message.count))

        return try exchange(message, timeout: timeout) { r in
            guard r.count >= 6, r[1] == index else { return nil }
            if r[2] == 0xFF, r[3] == feature, r[4] == fnByte { return .failure(.hidpp20(r[5])) }
            if r[2] == 0x8F, r[3] == feature, r[4] == fnByte { return .failure(.hidpp10(r[5])) }
            if r[2] == feature, r[3] == fnByte { return .success(Array(r[4...])) }
            return nil
        }
    }

    /// Turns on the receiver's device connect/disconnect notifications (HID++ 1.0 register 0x00, wireless flag).
    func enableReceiverNotifications() {
        guard !notificationsEnabled else { return }
        notificationsEnabled = true

        func register(_ subID: UInt8, _ params: [UInt8]) throws -> [UInt8] {
            try exchange([0x10, 0xFF, subID, 0x00] + params, timeout: 0.5) { r in
                guard r.count >= 7, r[1] == 0xFF else { return nil }
                if r[2] == subID, r[3] == 0x00 { return .success(Array(r[4..<7])) }
                if r[2] == 0x8F, r[3] == subID { return .failure(.hidpp10(r[5])) }
                return nil
            }
        }
        let flags = (try? register(0x81, [0, 0, 0])) ?? [0, 0, 0]
        _ = try? register(0x80, [flags[0], flags[1] | 0x01, flags[2]])
    }
}
