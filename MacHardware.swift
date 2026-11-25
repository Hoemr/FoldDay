import AppKit
import CoreGraphics
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

struct MacStatus {
    let lidClosed: Bool?
    let onBattery: Bool?
    let batteryPercent: Int?

    static func read() -> Self {
        let lid = rootFlag("AppleClamshellState")
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [AnyObject] else {
            return Self(lidClosed: lid, onBattery: nil, batteryPercent: nil)
        }
        let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        let onBattery: Bool? = source == kIOPSACPowerValue ? false : (source == kIOPSBatteryPowerValue ? true : nil)
        for item in sources {
            guard let battery = IOPSGetPowerSourceDescription(snapshot, item)?.takeUnretainedValue() as? [String: Any],
                  battery[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = battery[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = battery[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return Self(lidClosed: lid, onBattery: onBattery, batteryPercent: current * 100 / maximum)
        }
        return Self(lidClosed: lid, onBattery: onBattery, batteryPercent: nil)
    }

    func canStayAwake(onBattery allowBattery: Bool, minimum: Int?) -> Bool {
        guard lidClosed != nil, let onBattery else { return false }
        guard onBattery else { return true }
        guard allowBattery else { return false }
        guard let minimum else { return true }
        return batteryPercent.map { $0 >= minimum } ?? false
    }
}

final class HardwareEvents {
    // IOPM.h defines this as iokit_family_msg(sub_iokit_powermanagement, 0x100).
    private static let clamshellChange: UInt32 = (0x38 << 26) | (13 << 14) | 0x100
    private let changed: () -> Void
    private let port: IONotificationPortRef
    private var interest: io_object_t = 0
    private var powerSource: CFRunLoopSource?
    private var observesDisplays = false

    private static let displayChanged: CGDisplayReconfigurationCallBack = { _, flags, context in
        guard let context, !flags.contains(.beginConfigurationFlag),
              !flags.intersection([.addFlag, .enabledFlag, .desktopShapeChangedFlag]).isEmpty else { return }
        let events = Unmanaged<HardwareEvents>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { [weak events] in events?.changed() }
    }

    init?(changed: @escaping () -> Void) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        self.port = port
        self.changed = changed
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, message, _ in
            guard message == HardwareEvents.clamshellChange, let context else { return }
            Unmanaged<HardwareEvents>.fromOpaque(context).takeUnretainedValue().changed()
        }, context, &interest)
        guard result == kIOReturnSuccess,
              let lidSource = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue(),
              let powerSource = IOPSNotificationCreateRunLoopSource({ context in
                  guard let context else { return }
                  Unmanaged<HardwareEvents>.fromOpaque(context).takeUnretainedValue().changed()
              }, context)?.takeRetainedValue() else { return nil }

        self.powerSource = powerSource
        CFRunLoopAddSource(CFRunLoopGetMain(), lidSource, .commonModes)
        CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes)
        observesDisplays = CGDisplayRegisterReconfigurationCallback(Self.displayChanged, context) == .success
    }

    deinit {
        if observesDisplays {
            CGDisplayRemoveReconfigurationCallback(Self.displayChanged, Unmanaged.passUnretained(self).toOpaque())
        }
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        if interest != IO_OBJECT_NULL { IOObjectRelease(interest) }
        IONotificationPortDestroy(port)
    }
}

final class Backlight {
    private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let framework: UnsafeMutableRawPointer
    private let get: Getter
    private let set: Setter
    private var lastDisplay: CGDirectDisplayID?

    init?() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let framework = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        guard let getter = dlsym(framework, "DisplayServicesGetBrightness"),
              let setter = dlsym(framework, "DisplayServicesSetBrightness") else {
            dlclose(framework)
            return nil
        }
        self.framework = framework
        self.get = unsafeBitCast(getter, to: Getter.self)
        self.set = unsafeBitCast(setter, to: Setter.self)
    }

    deinit { dlclose(framework) }

    private func builtInDisplay() -> CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success,
           let display = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            lastDisplay = display
        }
        return lastDisplay
    }

    func brightness() -> Float? {
        guard let display = builtInDisplay() else { return nil }
        var value: Float = 0
        return get(display, &value) == 0 && (0...1).contains(value) ? value : nil
    }

    func setBrightness(_ value: Float) -> Bool {
        guard let display = builtInDisplay(), set(display, value) == 0,
              let applied = brightness() else { return false }
        return abs(applied - value) < 0.01
    }
}

final class DesktopAssertion {
    private let name: String
    private var id: IOPMAssertionID = 0

    init(name: String = "FoldDay: closed-lid desktop") { self.name = name }

    func setActive(_ active: Bool) -> Bool {
        if active && id == 0 {
            let result = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                    name as CFString, &id)
            return result == kIOReturnSuccess
        }
        if !active && id != 0 {
            guard IOPMAssertionRelease(id) == kIOReturnSuccess else { return false }
            id = 0
        }
        return true
    }

    deinit { _ = setActive(false) }
}
