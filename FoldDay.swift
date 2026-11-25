import AppKit
import Combine
import CoreGraphics
import OSLog
import ServiceManagement
import SwiftUI

private var appName: String { tr("折昼") }

struct Options: Codable, Equatable {
    var keepAwake = false
    var backlightOff = true
    var keepDesktop = true
    var allowBattery = true
    var protectBattery = true
    var minimumBattery = 20
}

final class LidController: ObservableObject {
    @Published var settingsTab = 0
    @Published var options: Options {
        didSet {
            guard options != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(options), forKey: "options")
            refresh()
        }
    }
    @Published private(set) var status = MacStatus.read()
    @Published private(set) var active = false
    @Published private(set) var installed = false
    @Published private(set) var login = false
    @Published private(set) var needsLoginApproval = false
    @Published private(set) var canTakeOver = false
    @Published private(set) var needsRecovery = false
    @Published private(set) var error: String?

    private let power = PowerControl()
    private let desktop = DesktopAssertion()
    private let backlight = Backlight()
    private var events: HardwareEvents?
    private var wake: NSObjectProtocol?
    private let log = Logger(subsystem: "local.lidawake", category: "lid")
    private let brightnessKey = "brightnessBeforeClose"
    private var lastState = ""

    var state: String {
        if needsRecovery { return "电源设置待恢复" }
        if status.lidClosed == nil { return "未检测到笔记本上盖" }
        if active { return status.lidClosed == true ? "合盖保活中" : "等待合盖" }
        if !options.keepAwake { return "合盖保活已关闭" }
        if !installed { return "需要授权电源组件" }
        if canTakeOver { return "系统已有睡眠覆盖设置" }
        if status.onBattery == true && !options.allowBattery { return "电池供电时暂停" }
        if status.onBattery == true && options.protectBattery &&
           (status.batteryPercent ?? 0) < options.minimumBattery { return "低电量或电量未知，保活暂停" }
        return "合盖保活未启用"
    }

    init() {
        let defaults = UserDefaults.standard
        options = defaults.data(forKey: "options").flatMap { try? JSONDecoder().decode(Options.self, from: $0) } ?? Options()
        // Cache the internal display ID while WindowServer still reports it online.
        _ = backlight?.brightness()
        events = HardwareEvents { [weak self] in self?.refresh(hardwareEvent: true) }
        wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh(hardwareEvent: true) }
        power.interrupted = { [weak self] in self?.powerInterrupted() }
        if power.needsRecovery {
            do { try power.recover() } catch { self.error = error.localizedDescription }
        }
        refreshLogin()
        refresh()
    }

    func installPower() {
        do {
            try power.install()
            refresh()
        } catch { self.error = error.localizedDescription; installed = power.installed }
    }

    func takeOver() { refresh(takeOver: true) }

    func recover() {
        do {
            try power.recover()
            options.keepAwake = false
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    func removePower() {
        do {
            try shutdown()
            options.keepAwake = false
            try power.uninstall()
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch { self.error = error.localizedDescription }
        refreshLogin()
    }

    func refreshLogin() {
        let state = SMAppService.mainApp.status
        login = state == .enabled || state == .requiresApproval
        needsLoginApproval = state == .requiresApproval
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    func openLockScreen() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func eligible(_ snapshot: MacStatus) -> Bool {
        let batteryFloor = options.protectBattery ? options.minimumBattery : nil
        return options.keepAwake && snapshot.canStayAwake(onBattery: options.allowBattery, minimum: batteryFloor)
    }

    private func refresh(takeOver: Bool = false, hardwareEvent: Bool = false) {
        let previouslyEligible = eligible(status)
        status = .read()
        installed = power.installed
        needsRecovery = power.needsRecovery && !power.isActive
        let nowEligible = eligible(status)
        var issue: String? = events == nil ? "无法订阅上盖或电源事件。" : nil
        let wanted = nowEligible && events != nil && !needsRecovery

        if !wanted && power.isActive {
            if let brightnessIssue = updateDisplay(dark: false) { issue = brightnessIssue }
            _ = desktop.setActive(false)
            do { try power.stop() } catch { issue = error.localizedDescription }
        }
        if wanted && !power.isActive && installed && (!hardwareEvent || !previouslyEligible) {
            do {
                try power.start(takeOver: takeOver)
                canTakeOver = false
            } catch PowerError.external {
                canTakeOver = true
            } catch { issue = error.localizedDescription }
        } else if !wanted {
            canTakeOver = false
        }
        active = power.isActive && rootFlag("SleepDisabled") == true
        if power.isActive && !active { issue = "系统睡眠已被其他设置重新启用。" }
        needsRecovery = power.needsRecovery && !power.isActive
        let closedAndActive = active && status.lidClosed == true
        if !desktop.setActive(closedAndActive && options.keepDesktop) {
            issue = "无法切换桌面保活。"
        }
        if let brightnessIssue = updateDisplay(dark: closedAndActive && options.backlightOff) {
            issue = issue ?? brightnessIssue
        }
        error = issue
        let state = "\(status.lidClosed.map(String.init) ?? "unknown")/\(active)/\(status.onBattery.map(String.init) ?? "unknown")"
        if state != lastState {
            log.notice("Lid closed / power override / on battery: \(state, privacy: .public)")
            lastState = state
        }
    }

    private func powerInterrupted() {
        active = false
        needsRecovery = power.needsRecovery
        _ = desktop.setActive(false)
        error = updateDisplay(dark: false) ?? "电源组件已停止。可关闭后重新开启合盖保活。"
    }

    private func updateDisplay(dark: Bool) -> String? {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: brightnessKey) as? NSNumber
        if dark {
            if saved != nil && backlight?.brightness() == 0 { return nil }
            guard let backlight, let value = backlight.brightness() else {
                return "无法读取内置屏亮度。"
            }
            if saved == nil {
                defaults.set(value, forKey: brightnessKey)
                CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            }
            guard backlight.setBrightness(0) else { return "macOS 未确认内置屏背光归零。" }
            log.notice("Internal backlight set to zero")
        } else if let saved {
            guard backlight?.setBrightness(saved.floatValue) == true else {
                return "内置屏尚未恢复亮度。开盖后会再次恢复。"
            }
            defaults.removeObject(forKey: brightnessKey)
            log.notice("Internal backlight restored to \(saved.floatValue, privacy: .public)")
        }
        return nil
    }

    func shutdown() throws {
        let brightnessIssue = updateDisplay(dark: false)
        _ = desktop.setActive(false)
        try power.stop()
        try power.recover()
        active = false
        if let brightnessIssue { throw PowerError.administrator(brightnessIssue) }
    }
}

private struct SettingsHeader<Accessory: View>: View {
    let title: String
    let status: String
    let symbol: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 54, height: 51)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(tr(title)).font(.system(size: 24, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text(tr(status)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            accessory
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tr(title)).fontWeight(.medium)
                if let detail {
                    Text(tr(detail)).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct SettingsToggle<Accessory: View>: View {
    let title: String
    let detail: String
    let binding: Binding<Bool>
    @ViewBuilder var accessory: Accessory

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            accessory
            Toggle(tr(title), isOn: binding).toggleStyle(.switch).labelsHidden()
        }
    }
}

private extension SettingsToggle where Accessory == EmptyView {
    init(title: String, detail: String, binding: Binding<Bool>) {
        self.init(title: title, detail: detail, binding: binding) { EmptyView() }
    }
}

private struct SettingsDividingLine: View {
    var body: some View { Divider().padding(.horizontal, 12) }
}

private struct SettingsMessage: View {
    let text: String

    var body: some View {
        Label(tr(text), systemImage: "exclamationmark.circle")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct LidSettings: View {
    @ObservedObject var controller: LidController

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            SettingsHeader(title: "合盖保活", status: controller.state, symbol: "laptopcomputer") {
                if let percent = controller.status.batteryPercent {
                    Label("\(percent)%", systemImage: controller.status.onBattery == true ? "battery.75percent" : "battery.100percent.bolt")
                        .accessibilityLabel(tr("电量 %@%%", String(percent)))
                }
            }

            SettingsCard {
                SettingsToggle(title: "启用合盖保活", detail: "在开盖时预先启用，以拦截系统合盖休眠。", binding: $controller.options.keepAwake)
                SettingsDividingLine()
                SettingsToggle(title: "关闭内置屏背光", detail: "合盖时亮度归零，开盖时恢复。", binding: $controller.options.backlightOff)
                SettingsDividingLine()
                SettingsToggle(title: "保持桌面可操作", detail: "保活期间抑制合盖后的闲置显示休眠。", binding: $controller.options.keepDesktop)
                SettingsDividingLine()
                SettingsToggle(title: "电池供电时启用", detail: "拔掉电源后继续保活。", binding: $controller.options.allowBattery)
                SettingsDividingLine()
                SettingsToggle(title: "低电量保护", detail: "低于设定电量时暂停保活。", binding: $controller.options.protectBattery) {
                    if controller.options.protectBattery {
                        Picker(tr("保护阈值"), selection: $controller.options.minimumBattery) {
                            ForEach([10, 15, 20, 25, 30, 40], id: \.self) { Text("\($0)%").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 74)
                    }
                }
            }

            SettingsCard {
                SettingsToggle(title: "登录后自动启动", detail: "重启并登录 macOS 后应用已保存的设置。", binding: Binding(
                    get: { controller.login }, set: { controller.setLogin($0) }
                ))
            }

            if let error = controller.error {
                SettingsMessage(text: error)
            }
            if controller.canTakeOver {
                Text(tr("接管现有设置后，暂停、退出或移除电源组件时将恢复正常系统睡眠。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if controller.needsRecovery {
                    Button(tr("恢复系统睡眠"), action: controller.recover)
                } else if controller.canTakeOver {
                    Button(tr("接管并启用"), action: controller.takeOver)
                } else if !controller.installed {
                    Button(tr("授权电源组件…"), action: controller.installPower)
                } else {
                    Button(tr("移除电源组件…"), action: controller.removePower)
                }
                Spacer()
                if controller.needsLoginApproval {
                    Button(tr("批准登录项…"), action: controller.openLoginItems)
                }
                Button(tr("锁定屏幕设置…"), action: controller.openLockScreen)
            }
        }
    }
}

struct FoldDaySettings: View {
    @ObservedObject var lid: LidController
    @ObservedObject var proximity: ProximityController
    let languageChanged: () -> Void
    @AppStorage(InterfaceLanguage.preference) private var language = InterfaceLanguage.system
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker(tr("设置类别"), selection: $lid.settingsTab) {
                    Label(tr("合盖保活"), systemImage: "laptopcomputer").tag(0)
                    Label(tr("蓝牙锁屏"), systemImage: "lock.shield").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker(tr("界面语言"), selection: $language) {
                    ForEach(InterfaceLanguage.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .id(language)
            }
            .padding(.horizontal, 21)
            .padding(.top, 15)
            ScrollView {
                Group {
                    if lid.settingsTab == 0 {
                        LidSettings(controller: lid)
                    } else {
                        proximitySettings
                    }
                }
                .padding(21)
                .id(language)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 496, height: 605)
        .tint(colorScheme == .dark
              ? Color(red: 0.34, green: 0.83, blue: 0.69)
              : Color(red: 0.04, green: 0.43, blue: 0.34))
        .onChange(of: language) { _, _ in languageChanged() }
        .onChange(of: lid.settingsTab) { _, tab in
            if tab != 1 { proximity.setDiscovery(false) }
        }
    }

    private var proximitySettings: some View {
        VStack(alignment: .leading, spacing: 15) {
            SettingsHeader(title: "蓝牙锁屏", status: proximity.status, symbol: "lock.shield") { EmptyView() }

            if proximity.discovering {
                discoverySettings
            } else {
                SettingsCard {
                    SettingsRow(title: "感应设备") {
                        Button(tr("添加蓝牙设备…")) { proximity.setDiscovery(true) }
                    }
                    SettingsDividingLine()
                    if proximity.devices.isEmpty {
                        Text(tr("尚未添加设备")).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    } else {
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(proximity.devices) { device in
                                    HStack {
                                        Label(device.name, systemImage: "antenna.radiowaves.left.and.right")
                                            .lineLimit(1)
                                        Text(device.rssi.map { "\($0) dBm" } ?? tr("暂无信号"))
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                            .fixedSize()
                                        Spacer()
                                        Button(tr("移除")) { proximity.removeDevice(device.id) }
                                            .accessibilityLabel(tr("移除%@", device.name))
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                        .frame(height: min(119, CGFloat(proximity.devices.count * 29)))
                        .padding(.vertical, 7)
                    }
                }

                SettingsCard {
                    SettingsToggle(title: "启用蓝牙感应", detail: "合盖时暂停，开盖后恢复感应。", binding: setting(\.enabled))
                    SettingsDividingLine()
                    SettingsToggle(title: "设备靠近时解锁", detail: "信号达到解锁阈值时解锁。", binding: setting(\.unlockOnApproach)) {
                        stepper("解锁阈值", \.unlockRSSI, -99 ... -20, "dBm")
                    }
                    SettingsDividingLine()
                    SettingsToggle(title: "设备离开时锁屏", detail: "信号低于锁屏阈值时开始计时。", binding: setting(\.lockOnDeparture)) {
                        stepper("锁屏阈值", \.lockRSSI, -99 ... -20, "dBm")
                    }
                    SettingsDividingLine()
                    SettingsRow(title: "离开延迟", detail: "信号持续偏弱达到此时长后锁屏。") {
                        stepper("离开延迟", \.lockDelay, 1...300, "秒")
                    }
                    SettingsDividingLine()
                    SettingsToggle(title: "设备在旁时保持亮屏", detail: "抑制当前桌面的闲置显示休眠。", binding: setting(\.keepDisplayAwake))
                    SettingsDividingLine()
                    SettingsToggle(title: "靠近时先唤醒屏幕", detail: "屏幕休眠时先唤醒，再尝试解锁。", binding: setting(\.wakeDisplay))
                }

                if proximity.profile.options.unlockOnApproach || proximity.hasCredential {
                    HStack(spacing: 10) {
                        Button(tr(proximity.hasCredential ? "管理解锁密码…" : "设置解锁密码…"), action: proximity.editPassword)
                        Spacer()
                        if proximity.profile.options.unlockOnApproach {
                            if !proximity.accessibilityAllowed {
                                Button(tr("授权辅助功能…"), action: proximity.requestAccessibility)
                            } else {
                                Label(tr("辅助功能已授权"), systemImage: "checkmark.circle").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let error = proximity.error {
                SettingsMessage(text: error)
            }
        }
        .onAppear(perform: proximity.refreshPermissions)
    }

    private var discoverySettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                SettingsRow(title: "附近设备", detail: "让要添加的设备保持可发现。") { EmptyView() }
                SettingsDividingLine()
                if proximity.discovered.isEmpty {
                    Text(tr("暂无可添加的设备"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                        .padding(.horizontal, 12)
                } else {
                    ScrollView {
                        VStack(spacing: 7) {
                            ForEach(proximity.discovered) { device in
                                HStack(spacing: 9) {
                                    Text(device.name).lineLimit(1)
                                    Spacer()
                                    if let rssi = device.rssi {
                                        Text("\(rssi) dBm").monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    Button(tr("添加")) { proximity.addDevice(device.id) }
                                        .accessibilityLabel(tr("添加%@", device.name))
                                }
                            }
                        }
                        .padding(12)
                    }
                    .frame(height: 190)
                }
            }
            HStack {
                Button(tr("系统蓝牙设置…"), action: proximity.openBluetoothSettings)
                Button(tr("蓝牙权限…"), action: proximity.openBluetoothPermissions)
                Spacer()
                Button(tr("完成")) { proximity.setDiscovery(false) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func setting<Value: Equatable>(_ key: WritableKeyPath<ProximityOptions, Value>) -> Binding<Value> {
        Binding(get: { proximity.profile.options[keyPath: key] },
                set: { proximity.set(key, to: $0) })
    }

    private func stepper(_ label: String, _ key: WritableKeyPath<ProximityOptions, Int>,
                         _ range: ClosedRange<Int>, _ unit: String) -> some View {
        Stepper(value: setting(key), in: range) {
            Text("\(proximity.profile.options[keyPath: key]) \(tr(unit))").monospacedDigit()
        }
        .accessibilityLabel(tr(label))
        .fixedSize()
    }
}

final class LidAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let controller = LidController()
    private let proximity = ProximityController()
    private var lidObservation: AnyCancellable?
    private var menuItem: NSStatusItem?
    private var settingsMenuItem: NSMenuItem?
    private var quitMenuItem: NSMenuItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        lidObservation = controller.$status.map(\.lidClosed).removeDuplicates()
            .sink { [weak proximity] lidClosed in proximity?.setLidOpen(lidClosed == false) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: appName)
        let menu = NSMenu()
        settingsMenuItem = menu.addItem(withTitle: "", action: #selector(showSettings), keyEquivalent: ",")
        settingsMenuItem?.target = self
        menu.addItem(.separator())
        quitMenuItem = menu.addItem(withTitle: "", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        menuItem = item
        updateLocalizedTitles()
        if !UserDefaults.standard.bool(forKey: "hasOpenedSettings") { showSettings() }
    }

    private func updateLocalizedTitles() {
        let name = appName
        menuItem?.button?.toolTip = name
        menuItem?.button?.setAccessibilityLabel(name)
        settingsMenuItem?.title = tr("%@ 设置…", name)
        quitMenuItem?.title = tr("退出%@", name)
        settingsWindow?.title = tr("%@ 设置", name)
    }

    @objc private func showSettings() {
        controller.refreshLogin()
        proximity.refreshPermissions()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: FoldDaySettings(lid: controller, proximity: proximity) { [weak self] in
                    self?.updateLocalizedTitles()
                    self?.proximity.refreshNames()
                }
            ))
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.canHide = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        updateLocalizedTitles()
        UserDefaults.standard.set(true, forKey: "hasOpenedSettings")
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        proximity.setDiscovery(false)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            try controller.shutdown()
            return .terminateNow
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = tr("未能恢复设置。")
            alert.informativeText = tr(error.localizedDescription)
            alert.addButton(withTitle: tr("退出"))
            alert.addButton(withTitle: tr("返回设置"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { return .terminateNow }
            showSettings()
            return .terminateCancel
        }
    }
}

@main
enum FoldDayApp {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.dropFirst() == ["--diagnostics"] {
            let status = MacStatus.read()
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let locked = session?["CGSSessionScreenIsLocked"] as? Bool
            print("Lid closed: \(status.lidClosed.map(String.init) ?? "unknown")")
            print("On battery: \(status.onBattery.map(String.init) ?? "unknown")")
            print("Battery percentage: \(status.batteryPercent.map(String.init) ?? "unknown")")
            print("SleepDisabled: \(rootFlag("SleepDisabled").map(String.init) ?? "unset")")
            print("Built-in brightness: \(Backlight()?.brightness().map(String.init(describing:)) ?? "unavailable")")
            print("Screen locked: \(locked.map(String.init) ?? (session == nil ? "unknown" : "false"))")
            print("Active displays: \(NSScreen.screens.count)")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = LidAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
