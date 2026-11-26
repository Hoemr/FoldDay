import Foundation

struct ProximityOptions: Codable, Equatable {
    var enabled = false
    var unlockOnApproach = true
    var lockOnDeparture = true
    var keepDisplayAwake = false
    var wakeDisplay = true
    var unlockRSSI = -60
    var lockRSSI = -80
    var lockDelay = 5
    var signalTimeout = 60
    var unlockRequiresAll = false
    var lockRequiresAll = true
    var useConnectedRSSI = true
}

struct ProximityProfile: Codable, Equatable {
    var devices: [UUID] = []
    var addresses: [UUID: String] = [:]
    var labels: [UUID: String]?
    var options = ProximityOptions()

    @discardableResult
    mutating func add(_ id: UUID, label: String) -> Bool {
        guard !devices.contains(id) else { return false }
        devices.append(id)
        labels = (labels ?? [:]).merging([id: label]) { _, new in new }
        return true
    }

    mutating func remove(_ id: UUID) {
        devices.removeAll { $0 == id }
        labels?.removeValue(forKey: id)
        addresses.removeValue(forKey: id)
    }

    static func normalizedAddress(_ value: String) -> String {
        String(value.lowercased().filter { "0123456789abcdef".contains($0) })
    }
}

struct ProximitySession {
    private(set) var wasNearby = false
    private var mayUnlock = false
    private var requestedWake = false
    private var submittedUnlock = false

    var canAttemptUnlock: Bool { mayUnlock && !submittedUnlock }

    mutating func sawNearby() { wasNearby = true }
    mutating func sawAwayWhileLocked() { mayUnlock = true }
    mutating func displayWokeWhileLocked() { mayUnlock = true }

    mutating func requestDisplayWake() -> Bool {
        guard !requestedWake else { return false }
        requestedWake = true
        return true
    }

    mutating func displaySleptWhileUnlocked() { requestedWake = false }

    mutating func requestedLock(accepted: Bool) {
        wasNearby = false
        mayUnlock = accepted
    }
    mutating func unlocked(nearby: Bool) {
        wasNearby = nearby
        mayUnlock = false
        requestedWake = false
        submittedUnlock = false
    }

    mutating func consumeUnlockAttempt() -> Bool {
        guard canAttemptUnlock else { return false }
        submittedUnlock = true
        return true
    }
}
