import AppKit
import ApplicationServices
import Combine
import CoreBluetooth
import IOBluetooth
import IOKit.pwr_mgt
import LocalAuthentication
import OSLog
import Security

struct ProximityDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int? = nil
}

final class ProximityController: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var profile = ProximityProfile()
    @Published private(set) var devices: [ProximityDevice] = []
    @Published private(set) var discovered: [ProximityDevice] = []
    @Published private(set) var discovering = false
    @Published private(set) var nearby = false
    @Published private(set) var accessibilityAllowed = false
    @Published private(set) var hasCredential = false
    @Published private(set) var status = "蓝牙感应已关闭"
    @Published private(set) var error: String?

    private let defaults = UserDefaults.standard
    private let assertion = DesktopAssertion(name: "FoldDay: Bluetooth device nearby")
    private let log = Logger(subsystem: "local.lidawake", category: "proximity")
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var names: [UUID: String] = [:]
    private var evidence: [UUID: ProximityEvidence] = [:]
    private var nearbyIDs: Set<UUID> = []
    private var signalExpiry: Timer?
    private var readRSSI: Timer?
    private var displayWakeAssertion: IOPMAssertionID = 0
    private var session = ProximitySession()
    private var lidOpen = false
    private var systemSleeping = false
    private var displaySleeping = false
    private var pendingUnlock = false
    private var editingPassword = false

    override init() {
        super.init()
        profile = defaults.data(forKey: "proximityProfile")
            .flatMap { try? JSONDecoder().decode(ProximityProfile.self, from: $0) }
            ?? ProximityProfile()
        refreshNames()
        refreshPermissions()

        let workspace = NSWorkspace.shared.notificationCenter
        NotificationCenter.default.addObserver(self, selector: #selector(refreshPermissions),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displayDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displayDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenDidLock), name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenDidUnlock), name: .init("com.apple.screenIsUnlocked"), object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        signalExpiry?.invalidate()
        readRSSI?.invalidate()
    }

    func setDiscovery(_ active: Bool) {
        guard discovering != active else { return }
        discovering = active
        discovered = []
        error = nil
        stopMonitoring()
        session = ProximitySession()
        refreshMonitoring()
    }

    func addDevice(_ id: UUID) {
        guard discovering, let candidate = discovered.first(where: { $0.id == id }) else { return }
        var updated = profile
        guard updated.add(id, label: candidate.name) else { return }
        save(updated)
        discovered.removeAll { $0.id == id }
        refreshNames()
    }

    func removeDevice(_ id: UUID) {
        var updated = profile
        updated.remove(id)
        save(updated)
        names.removeValue(forKey: id)
        stopMonitoring()
        session = ProximitySession()
        refreshNames()
        refreshMonitoring()
    }

    func set<Value: Equatable>(_ key: WritableKeyPath<ProximityOptions, Value>, to value: Value) {
        var profile = profile
        guard profile.options[keyPath: key] != value else { return }
        let previous = profile.options
        profile.options[keyPath: key] = value
        save(profile)
        if profile.options.enabled != previous.enabled ||
           profile.options.useConnectedRSSI != previous.useConnectedRSSI {
            stopMonitoring()
            session = ProximitySession()
        } else if profile.options.unlockRSSI != previous.unlockRSSI ||
                  profile.options.lockRSSI != previous.lockRSSI ||
                  profile.options.lockDelay != previous.lockDelay ||
                  profile.options.signalTimeout != previous.signalTimeout ||
                  profile.options.unlockRequiresAll != previous.unlockRequiresAll ||
                  profile.options.lockRequiresAll != previous.lockRequiresAll {
            resetEvidence()
            session = ProximitySession()
        }
        refreshPermissions()
        refreshMonitoring()
        updateDisplayAssertion()
    }

    private func save(_ profile: ProximityProfile) {
        self.profile = profile
        defaults.set(try? JSONEncoder().encode(profile), forKey: "proximityProfile")
    }

    func setLidOpen(_ open: Bool) {
        guard lidOpen != open else { return }
        lidOpen = open
        if !open { session = ProximitySession() }
        refreshMonitoring()
    }

    @objc func refreshPermissions() {
        accessibilityAllowed = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        hasCredential = UnlockCredential.read() != nil
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermissions()
    }

    func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    func openBluetoothPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }

    func editPassword() {
        guard ScreenSession.isLocked == false else { return }
        error = nil
        editingPassword = true
        pendingUnlock = false
        defer { editingPassword = false }

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 270, height: 24))
        field.placeholderString = "当前 Mac 账户的登录密码"
        let alert = NSAlert()
        alert.messageText = hasCredential ? "更改自动解锁密码" : "设置自动解锁密码"
        alert.informativeText = "折昼将密码保存在本机钥匙串，并在设备返回时用它解锁当前会话。"
        alert.accessoryView = field
        alert.addButton(withTitle: "存入钥匙串")
        alert.addButton(withTitle: "取消")
        if hasCredential { alert.addButton(withTitle: "删除已存密码") }
        alert.window.initialFirstResponder = field
        let choice = alert.runModal()
        defer { field.stringValue = "" }
        if choice == .alertFirstButtonReturn {
            guard !field.stringValue.isEmpty else {
                error = "请输入当前 Mac 账户的登录密码。"
                return
            }
            if UnlockCredential.store(Data(field.stringValue.utf8)) { hasCredential = true }
            else { error = "无法写入本机钥匙串。" }
        } else if choice == .alertThirdButtonReturn {
            if UnlockCredential.remove() { hasCredential = false }
            else { error = "无法删除折昼保存的钥匙串密码。" }
        }
    }

    private var monitoringEnabled: Bool {
        !discovering && profile.options.enabled && !profile.devices.isEmpty
    }

    private func refreshMonitoring() {
        guard discovering || monitoringEnabled else {
            stopMonitoring()
            status = profile.options.enabled ? "请先添加蓝牙设备" : "蓝牙感应已关闭"
            return
        }
        guard lidOpen, !systemSleeping else {
            stopMonitoring()
            if !lidOpen { status = "合盖时暂停蓝牙锁屏与解锁" }
            else { status = "系统睡眠期间暂停" }
            return
        }
        if central == nil {
            status = "正在启用蓝牙"
            central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    private func stopMonitoring() {
        if let central {
            if central.state == .poweredOn {
                central.stopScan()
                for peripheral in peripherals.values { central.cancelPeripheralConnection(peripheral) }
            }
        }
        central = nil
        peripherals.removeAll()
        readRSSI?.invalidate()
        readRSSI = nil
        resetEvidence()
    }

    private func resetEvidence() {
        signalExpiry?.invalidate()
        signalExpiry = nil
        evidence.removeAll()
        nearbyIDs.removeAll()
        pendingUnlock = false
        if displayWakeAssertion != 0 {
            IOPMAssertionRelease(displayWakeAssertion)
            displayWakeAssertion = 0
        }
        if nearby { nearby = false }
        updateDeviceSignals()
        updateDisplayAssertion()
    }

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        guard manager === central else { return }
        guard manager.state == .poweredOn else {
            peripherals.removeAll()
            discovered = []
            readRSSI?.invalidate()
            readRSSI = nil
            resetEvidence()
            session = ProximitySession()
            switch manager.state {
            case .unauthorized: status = "需要 macOS 蓝牙权限"
            case .poweredOff: status = "蓝牙已关闭"
            case .unsupported: status = "此 Mac 不支持蓝牙低功耗"
            default: status = "正在等待蓝牙"
            }
            return
        }
        status = discovering ? "正在扫描附近的蓝牙设备" : "正在查找已选设备"
        if monitoringEnabled && profile.options.useConnectedRSSI {
            for peripheral in manager.retrievePeripherals(withIdentifiers: profile.devices) {
                track(peripheral, with: manager)
            }
        }
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: !discovering])
    }

    func centralManager(_ manager: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard manager === central else { return }
        let id = peripheral.identifier
        let label = [advertisementData[CBAdvertisementDataLocalNameKey] as? String, peripheral.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if discovering {
            guard !profile.devices.contains(id), let label, (-126..<0).contains(RSSI.intValue) else { return }
            // Keep rows in discovery order so the target of an Add click stays in place.
            if let index = discovered.firstIndex(where: { $0.id == id }) {
                if discovered[index].rssi != RSSI.intValue { discovered[index].rssi = RSSI.intValue }
            } else {
                discovered.append(ProximityDevice(id: id, name: label, rssi: RSSI.intValue))
            }
            return
        }
        guard monitoringEnabled, profile.devices.contains(id) else { return }
        if let label, names[peripheral.identifier] != label {
            names[peripheral.identifier] = label
            refreshNames()
        }
        if profile.options.useConnectedRSSI, peripherals[peripheral.identifier] == nil {
            track(peripheral, with: manager)
        }
        if peripheral.state != .connected || !profile.options.useConnectedRSSI {
            observe(peripheral.identifier, rssi: RSSI.intValue)
        }
    }

    private func track(_ peripheral: CBPeripheral, with manager: CBCentralManager) {
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected { centralManager(manager, didConnect: peripheral) }
        else if peripheral.state == .disconnected { manager.connect(peripheral) }
    }

    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard manager === central, peripherals[peripheral.identifier] === peripheral else { return }
        peripheral.readRSSI()
        guard readRSSI == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            for peripheral in self.peripherals.values where peripheral.state == .connected {
                peripheral.readRSSI()
            }
        }
        readRSSI = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard manager === central, peripherals[peripheral.identifier] === peripheral else { return }
        peripherals.removeValue(forKey: peripheral.identifier)
        if !peripherals.values.contains(where: { $0.state == .connected }) {
            readRSSI?.invalidate()
            readRSSI = nil
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, peripherals[peripheral.identifier] === peripheral else { return }
        observe(peripheral.identifier, rssi: RSSI.intValue)
    }

    private func observe(_ id: UUID, rssi: Int) {
        guard monitoringEnabled else { return }
        let options = profile.options
        let now = ProcessInfo.processInfo.systemUptime
        guard evidence[id, default: ProximityEvidence()].observe(
            rssi: rssi, now: now, unlockRSSI: options.unlockRSSI, lockRSSI: options.lockRSSI
        ) else { return }
        updatePresence(now)
        scheduleExpiry(now)
    }

    private func scheduleExpiry(_ now: TimeInterval) {
        guard let oldest = evidence.values.compactMap({ item in
                  item.filteredRSSI == nil ? nil : item.lastSampleAt
              }).min() else { return }
        let timeout = profile.options.signalTimeout
        let fireDate = Date(timeIntervalSinceNow: max(0.01, oldest + Double(timeout) - now))
        if let timer = signalExpiry {
            timer.fireDate = fireDate
            return
        }
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.signalExpiry = nil
            let now = ProcessInfo.processInfo.systemUptime
            self.updatePresence(now)
            self.scheduleExpiry(now)
        }
        signalExpiry = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updatePresence(_ now: TimeInterval) {
        guard monitoringEnabled else { return }
        let options = profile.options
        let timeout = Double(options.signalTimeout)
        let delay = Double(options.lockDelay)
        let tracked = profile.devices
        for id in tracked {
            guard let item = evidence[id], let last = item.lastSampleAt else { continue }
            if now - last >= timeout {
                evidence[id]?.expireSignal()
                nearbyIDs.remove(id)
            } else if item.isStablyClose(now: now) {
                nearbyIDs.insert(id)
            } else if item.isWeak(now: now, delay: delay) {
                nearbyIDs.remove(id)
            }
        }
        let near = options.unlockRequiresAll ? tracked.allSatisfy(nearbyIDs.contains) : !nearbyIDs.isEmpty
        if nearby != near { nearby = near }
        updateDeviceSignals()
        let hasSignal = devices.contains { $0.rssi != nil }
        let display = near ? "已确认设备在附近" : (hasSignal ? "正在测量设备距离" : "等待有效蓝牙信号")
        if status != display { status = display }
        updateDisplayAssertion()
        guard !editingPassword, let locked = ScreenSession.isLocked else { return }
        let readings = tracked.map { evidence[$0] ?? ProximityEvidence() }
        let stableNear = options.unlockRequiresAll
            ? readings.allSatisfy { $0.isStablyClose(now: now) }
            : readings.contains { $0.isStablyClose(now: now) }
        if stableNear {
            session.sawNearby()
            if locked && options.unlockOnApproach && accessibilityAllowed && hasCredential &&
               session.consumeApproach() {
                beginUnlock()
            }
            return
        }
        guard !near else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: UInt32.max)!)
        guard AutomaticLockSafety.reason(evidence: readings, requireAllAway: options.lockRequiresAll,
                                         now: now, idleSeconds: locked ? delay : idle,
                                         awayDelay: delay, signalTimeout: timeout) != nil else { return }
        if locked {
            session.sawAwayWhileLocked()
        } else if options.lockOnDeparture && session.wasNearby {
            let locked = ScreenSession.lock()
            session.requestedLock(accepted: locked)
            if locked {
                log.notice("Locked the screen after measured departure")
            } else {
                error = "macOS 未接受自动锁屏请求。"
            }
        }
    }

    private func updateDisplayAssertion() {
        _ = assertion.setActive(central != nil && nearby && !displaySleeping &&
                                profile.options.keepDisplayAwake && ScreenSession.isLocked == false)
    }

    private func beginUnlock() {
        if displaySleeping {
            guard profile.options.wakeDisplay else { return }
            pendingUnlock = IOPMAssertionDeclareUserActivity("FoldDay: device returned" as CFString,
                kIOPMUserActiveLocal, &displayWakeAssertion) == kIOReturnSuccess
        } else {
            pendingUnlock = true
            submitUnlockWhenReady()
        }
    }

    private func submitUnlockWhenReady() {
        guard pendingUnlock else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.pendingUnlock else { return }
            self.pendingUnlock = false
            let now = ProcessInfo.processInfo.systemUptime
            let profile = self.profile
            guard self.monitoringEnabled, self.central?.state == .poweredOn, self.lidOpen,
                  !self.editingPassword, !self.displaySleeping, profile.options.unlockOnApproach,
                  ScreenSession.isLocked == true else { return }
            let close = profile.devices.map { self.evidence[$0]?.isStablyClose(now: now) == true }
            guard profile.options.unlockRequiresAll ? close.allSatisfy({ $0 }) : close.contains(true),
                  AXIsProcessTrusted(), CGPreflightPostEventAccess() else { return }
            guard let secret = UnlockCredential.read(),
                  let password = String(data: secret, encoding: .utf8), !password.isEmpty else {
                self.hasCredential = false
                return
            }
            guard ScreenSession.isLocked == true else { return }
            ScreenSession.submit(password)
            self.log.notice("Submitted an unlock attempt after a new approach")
        }
    }

    private func refreshNames() {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let labels = profile.devices.enumerated().map { index, id in
            let pair = paired.first { device in
                guard let address = device.addressString, let expected = profile.addresses[id] else { return false }
                return ProximityProfile.normalizedAddress(address) == expected
            }
            return ProximityDevice(
                id: id,
                name: profile.labels?[id] ?? pair?.name ?? names[id] ?? "蓝牙设备 \(index + 1)",
                rssi: evidence[id]?.filteredRSSI
            )
        }
        if devices != labels { devices = labels }
    }

    private func updateDeviceSignals() {
        let updated = devices.map { device in
            var device = device
            device.rssi = evidence[device.id]?.filteredRSSI
            return device
        }
        if devices != updated { devices = updated }
    }

    @objc private func systemWillSleep() {
        systemSleeping = true
        refreshMonitoring()
    }

    @objc private func systemDidWake() {
        systemSleeping = false
        refreshMonitoring()
    }

    @objc private func displayDidSleep() {
        displaySleeping = true
        updateDisplayAssertion()
    }

    @objc private func displayDidWake() {
        displaySleeping = false
        updateDisplayAssertion()
        submitUnlockWhenReady()
    }

    @objc private func screenDidLock() { updateDisplayAssertion() }

    @objc private func screenDidUnlock() {
        pendingUnlock = false
        session.unlocked(nearby: nearby)
        updateDisplayAssertion()
    }
}

private enum UnlockCredential {
    static func read() -> Data? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, !data.isEmpty else { return nil }
        return data
    }

    static func store(_ data: Data) -> Bool {
        let query = identity
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "FoldDay"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove() -> Bool {
        let status = SecItemDelete(identity as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.lidawake.proximity", kSecAttrAccount as String: NSUserName()]
    }
}

private enum ScreenSession {
    private static let login = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LOCAL | RTLD_LAZY)

    static var isLocked: Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session["kCGSSessionOnConsoleKey"] as? Bool == true,
              session["kCGSSessionUserIDKey"] as? UInt32 == getuid() else { return nil }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    static func lock() -> Bool {
        guard isLocked == false, let login, let symbol = dlsym(login, "SACLockScreenImmediate") else { return false }
        let lock = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
        return lock() == 0
    }

    static func submit(_ password: String) {
        guard isLocked == true, let source = CGEventSource(stateID: .hidSystemState) else { return }
        let characters = Array(password.utf16)
        for start in stride(from: 0, to: characters.count, by: 20) {
            let count = min(20, characters.count - start)
            let event = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true)
            characters.withUnsafeBufferPointer { buffer in
                event?.keyboardSetUnicodeString(stringLength: count, unicodeString: buffer.baseAddress?.advanced(by: start))
            }
            event?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
        }
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
