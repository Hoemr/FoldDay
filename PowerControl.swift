import Foundation
import IOKit

let powerHelperPath = "/Library/PrivilegedHelperTools/local.lidawake.power"
let powerMarkerPath = powerHelperPath + ".active"
let powerRulePath = "/private/etc/sudoers.d/local_lidawake"

enum PowerCommand: UInt8 {
    case arm = 65, recover = 82, takeOver = 84
}

enum PowerReply: UInt8 {
    case active = 79, restored = 68, external = 69, busy = 66, failed = 70
}

func rootFlag(_ name: String) -> Bool? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool
}

enum PowerError: LocalizedError {
    case unavailable, external, busy, failed, restoreFailed, administrator(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "需要安装或重新授权电源组件。"
        case .external: return "系统睡眠已由其他配置禁用。"
        case .busy: return "电源组件已被另一实例占用。"
        case .failed: return "macOS 未确认电源设置变更。"
        case .restoreFailed: return "无法恢复系统睡眠，请使用「恢复系统睡眠」。"
        case .administrator(let message): return message
        }
    }
}

final class PowerControl {
    private var helper: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    var interrupted: (() -> Void)?

    var installed: Bool { FileManager.default.isExecutableFile(atPath: powerHelperPath) }
    var needsRecovery: Bool { FileManager.default.fileExists(atPath: powerMarkerPath) }
    var isActive: Bool { helper?.isRunning == true }

    func start(takeOver: Bool = false) throws {
        guard !isActive else { return }
        let (process, stdin, stdout) = try connect(takeOver ? .takeOver : .arm)
        helper = process
        input = stdin
        output = stdout
    }

    func stop() throws {
        guard let process = helper, let input, let output else { return }
        helper = nil
        self.input = nil
        self.output = nil
        try? input.close()
        let reply = try? output.read(upToCount: 1)?.first
        process.waitUntilExit()
        guard reply == PowerReply.restored.rawValue, process.terminationStatus == 0 else {
            throw PowerError.restoreFailed
        }
    }

    func recover() throws {
        guard needsRecovery else { return }
        let (process, input, _) = try connect(.recover)
        try? input.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PowerError.restoreFailed }
    }

    private func connect(_ command: PowerCommand) throws -> (Process, FileHandle, FileHandle) {
        guard installed else { throw PowerError.unavailable }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "--", powerHelperPath]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.helper === process else { return }
                self.helper = nil
                self.input = nil
                self.output = nil
                self.interrupted?()
            }
        }
        try process.run()
        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        let reply: PowerReply?
        do {
            try writer.write(contentsOf: Data([command.rawValue]))
            reply = try reader.read(upToCount: 1)?.first.flatMap(PowerReply.init(rawValue:))
        } catch {
            try? writer.close()
            process.waitUntilExit()
            throw PowerError.unavailable
        }
        switch reply {
        case .restored, .active: return (process, writer, reader)
        default:
            try? writer.close()
            process.waitUntilExit()
            switch reply {
            case .external: throw PowerError.external
            case .busy: throw PowerError.busy
            case .failed: throw PowerError.failed
            default: throw PowerError.unavailable
            }
        }
    }

    func install() throws {
        guard let source = Bundle.main.url(forResource: "lidawake-power", withExtension: nil) else {
            throw PowerError.unavailable
        }
        let rule = "Defaults!\(powerHelperPath) !use_pty\n#\(getuid()) ALL=(root) NOPASSWD: \(powerHelperPath) \"\"\n"
        try administer("""
            set -eu
            temp=$(/usr/bin/mktemp /private/var/tmp/lidawake.XXXXXXXX)
            trap '/bin/rm -f "$temp"' EXIT
            /usr/bin/printf %s \(shellQuote(rule)) > "$temp"
            /usr/sbin/visudo -c -f "$temp" >/dev/null
            [ -d /Library/PrivilegedHelperTools ] || /usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
            [ -d /private/etc/sudoers.d ] || /usr/bin/install -d -o root -g wheel -m 755 /private/etc/sudoers.d
            /usr/bin/install -o root -g wheel -m 755 \(shellQuote(source.path)) \(powerHelperPath)
            /usr/bin/install -o root -g wheel -m 440 "$temp" \(powerRulePath)
            /usr/sbin/visudo -c >/dev/null
            """)
        // Verify the installed rule by querying it without asking for a password.
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        check.arguments = ["-n", "-l", "--", powerHelperPath]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        try check.run()
        check.waitUntilExit()
        guard check.terminationStatus == 0 else { throw PowerError.unavailable }
    }

    func uninstall() throws {
        try stop()
        try recover()
        try administer("/bin/rm -f \(powerRulePath) \(powerHelperPath)")
    }

    private func administer(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else {
            throw PowerError.unavailable
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            throw PowerError.administrator(error[NSAppleScript.errorMessage] as? String ?? "管理员授权失败。")
        }
    }

    private func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
