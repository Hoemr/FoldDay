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

/// A new approach can unlock only after this process has measured a departure.
struct ProximitySession {
    private(set) var wasNearby = false
    private(set) var mayUnlock = false

    mutating func sawNearby() { wasNearby = true }
    mutating func sawAwayWhileLocked() { mayUnlock = true }
    mutating func requestedLock(accepted: Bool) {
        wasNearby = false
        mayUnlock = accepted
    }
    mutating func unlocked(nearby: Bool) {
        wasNearby = nearby
        mayUnlock = false
    }

    mutating func consumeApproach() -> Bool {
        guard mayUnlock else { return false }
        mayUnlock = false
        return true
    }
}
