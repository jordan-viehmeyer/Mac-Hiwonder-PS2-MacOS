import Foundation
import IOKit
import IOKit.hid

/// Opens the PS2 receiver and streams its raw input reports.
///
/// The adapter packs everything into one 27-byte report with no report ID, so subscribing
/// to the whole report is simpler and cheaper than registering a callback per HID element.
final class HIDReader {
    typealias ReportHandler = ([UInt8]) -> Void
    typealias ConnectionHandler = (Bool, String) -> Void

    private let manager: IOHIDManager
    private var reportBuffer = [UInt8](repeating: 0, count: 64)
    private let onReport: ReportHandler
    private let onConnectionChange: ConnectionHandler
    /// Devices already opened, keyed by a stable identity (see `identity(of:)`).
    private var openedDevices = Set<String>()

    private let vendorID: Int
    private let productID: Int
    private let matchAnyGamepad: Bool

    init(config: Config, onReport: @escaping ReportHandler,
         onConnectionChange: @escaping ConnectionHandler) {
        self.vendorID = config.vendorID
        self.productID = config.productID
        self.matchAnyGamepad = config.matchAnyGamepad
        self.onReport = onReport
        self.onConnectionChange = onConnectionChange
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// A stable identity for a device.
    ///
    /// The matching criteria deliberately overlap — the exact VID/PID *and* the generic
    /// gamepad fallback both match this receiver — so the attach callback fires once per
    /// matching dictionary for the same physical device. Comparing `IOHIDDevice` refs is
    /// not enough to catch that, and opening twice would double every report.
    private static func identity(of device: IOHIDDevice) -> String {
        func number(_ key: String) -> Int {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? -1
        }
        return [
            kIOHIDLocationIDKey, kIOHIDVendorIDKey, kIOHIDProductIDKey,
            kIOHIDPrimaryUsagePageKey, kIOHIDPrimaryUsageKey,
        ].map { String(number($0)) }.joined(separator: ":")
    }

    /// Describes a device for log output.
    static func describe(_ device: IOHIDDevice) -> String {
        func string(_ key: String) -> String? {
            IOHIDDeviceGetProperty(device, key as CFString) as? String
        }
        func number(_ key: String) -> Int? {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
        }
        let name = string(kIOHIDProductKey) ?? "Unknown HID device"
        let vid = number(kIOHIDVendorIDKey) ?? 0
        let pid = number(kIOHIDProductIDKey) ?? 0
        return String(format: "%@ (%04x:%04x)",
                      name.trimmingCharacters(in: .whitespaces), vid, pid)
    }

    /// Begin matching and scheduling on the current thread's run loop.
    /// The caller is expected to run that run loop afterwards.
    func start() throws {
        var criteria: [[String: Any]] = [
            [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID]
        ]
        if matchAnyGamepad {
            // A generic fallback keeps the driver usable with other PS2 adapter clones and
            // with a second receiver whose PID differs.
            criteria.append([
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad,
            ])
            criteria.append([
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick,
            ])
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, criteria as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDReader>.fromOpaque(context).takeUnretainedValue().deviceAttached(device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDReader>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw HIDError.managerOpenFailed(result)
        }
    }

    func stop() {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - Device lifecycle

    private func deviceAttached(_ device: IOHIDDevice) {
        let key = Self.identity(of: device)
        guard !openedDevices.contains(key) else { return }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            onConnectionChange(false,
                "could not open \(Self.describe(device)) — \(HIDError.describe(result))")
            return
        }
        openedDevices.insert(key)

        let context = Unmanaged.passUnretained(self).toOpaque()
        reportBuffer.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceRegisterInputReportCallback(
                device, buffer.baseAddress!, buffer.count,
                { context, _, _, _, _, report, length in
                    guard let context, length > 0 else { return }
                    let reader = Unmanaged<HIDReader>.fromOpaque(context).takeUnretainedValue()
                    reader.onReport(Array(UnsafeBufferPointer(start: report, count: length)))
                }, context)
        }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        onConnectionChange(true, Self.describe(device))
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        guard openedDevices.remove(Self.identity(of: device)) != nil else { return }
        onConnectionChange(false, "\(Self.describe(device)) disconnected")
    }
}

enum HIDError: LocalizedError {
    case managerOpenFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .managerOpenFailed(let code):
            return "could not open the HID manager — \(HIDError.describe(code))"
        }
    }

    /// Turn the handful of IOReturn codes this driver actually provokes into advice.
    static func describe(_ code: IOReturn) -> String {
        switch code {
        case kIOReturnNotPermitted, kIOReturnNotPrivileged:
            return "permission denied. Grant Input Monitoring to your terminal in "
                + "System Settings > Privacy & Security > Input Monitoring, then try again."
        case kIOReturnExclusiveAccess:
            return "another process has exclusive access to the device."
        case kIOReturnNoDevice:
            return "the device went away."
        default:
            return String(format: "IOReturn 0x%08x", UInt32(bitPattern: code))
        }
    }
}
