import Darwin
import Foundation
import OSLog

@main
enum PowerHelper {
    private static let log = Logger(subsystem: "local.lidawake", category: "power")

    static func main() {
        guard geteuid() == 0, CommandLine.argc == 1 else { reply(.failed, exitCode: 1) }
        // A normal application exit or kill closes stdin. Keep cleanup running
        // even if the application side has already closed its reply pipe.
        signal(SIGPIPE, SIG_IGN)
        guard let byte = UInt8(exactly: getchar()), let command = PowerCommand(rawValue: byte) else {
            reply(.failed, exitCode: 1)
        }
        let lock = open(powerHelperPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { reply(.busy, exitCode: 1) }

        if FileManager.default.fileExists(atPath: powerMarkerPath), !restore() {
            reply(.failed, exitCode: 1)
        }
        if command == .recover { reply(.restored, exitCode: 0) }
        if rootFlag("SleepDisabled") == true && command != .takeOver { reply(.external, exitCode: 1) }

        let marker = open(powerMarkerPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard marker >= 0 else { reply(.failed, exitCode: 1) }
        fsync(marker)
        close(marker)
        guard pmset(["-a", "disablesleep", "1"]), rootFlag("SleepDisabled") == true else {
            _ = restore()
            reply(.failed, exitCode: 1)
        }

        log.notice("System sleep override active")
        writeReply(.active)
        _ = getchar()
        guard restore() else { reply(.failed, exitCode: 1) }
        writeReply(.restored)
        if rootFlag("AppleClamshellState") == true,
           rootFlag("AppleClamshellCausesSleep") == true {
            let task = pmsetTask(["sleepnow"])
            do { try task.run() } catch { log.error("Could not request normal clamshell sleep") }
        }
    }

    private static func restore() -> Bool {
        guard pmset(["-a", "disablesleep", "0"]), rootFlag("SleepDisabled") != true,
              unlink(powerMarkerPath) == 0 || errno == ENOENT else {
            log.error("Failed to restore system sleep")
            return false
        }
        log.notice("System sleep policy restored")
        return true
    }

    private static func pmset(_ args: [String]) -> Bool {
        let task = pmsetTask(args)
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private static func pmsetTask(_ args: [String]) -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = args
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        return task
    }

    private static func writeReply(_ reply: PowerReply) {
        var byte = reply.rawValue
        _ = write(STDOUT_FILENO, &byte, 1)
    }

    private static func reply(_ result: PowerReply, exitCode: Int32) -> Never {
        writeReply(result)
        exit(exitCode)
    }
}
