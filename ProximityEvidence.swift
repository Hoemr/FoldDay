import Foundation

enum ProximityLockReason: String {
    case away, lost
}

/// Only valid, recent observations may establish proximity. Time uses system uptime.
struct ProximityEvidence {
    private var samples: [Int] = []
    private var closeSince: TimeInterval?
    private var closeSampleCount = 0
    private var weakSince: TimeInterval?
    private(set) var lastSampleAt: TimeInterval?
    private(set) var filteredRSSI: Int?
    static let maximumSampleGap: TimeInterval = 5

    @discardableResult
    mutating func observe(rssi: Int, now: TimeInterval, unlockRSSI: Int, lockRSSI: Int) -> Bool {
        guard (-126..<0).contains(rssi) else { return false }
        if let last = lastSampleAt, now - last > Self.maximumSampleGap {
            self = Self()
        }
        samples.append(rssi)
        if samples.count > 5 { samples.removeFirst() }
        let filtered = samples.sorted()[(samples.count - 1) / 2]
        filteredRSSI = filtered
        lastSampleAt = now

        // Unlock from two of the latest three readings. The longer, five-reading
        // median remains responsible for departure, so walking back is responsive.
        let closeReadings = samples.suffix(3).filter { $0 >= unlockRSSI }.count
        if closeReadings >= 2 {
            if closeSince == nil { closeSince = now }
            closeSampleCount = closeReadings
        } else {
            closeSince = rssi >= unlockRSSI ? now : nil
            closeSampleCount = rssi >= unlockRSSI ? 1 : 0
        }
        if filtered < lockRSSI {
            if weakSince == nil { weakSince = now }
        } else {
            weakSince = nil
        }
        return true
    }

    func isStablyClose(now: TimeInterval) -> Bool {
        guard let since = closeSince, closeSampleCount >= 2, isFresh(now: now) else { return false }
        return now - since >= 0.6
    }

    func isWeak(now: TimeInterval, delay: TimeInterval) -> Bool {
        guard let since = weakSince, isFresh(now: now) else { return false }
        return now - since >= delay
    }

    func lockReason(now: TimeInterval, awayDelay: TimeInterval, signalTimeout: TimeInterval) -> ProximityLockReason? {
        if isWeak(now: now, delay: awayDelay) { return .away }
        if let last = lastSampleAt, now - last >= signalTimeout { return .lost }
        return nil
    }

    mutating func expireSignal() {
        samples.removeAll()
        closeSince = nil
        closeSampleCount = 0
        weakSince = nil
        filteredRSSI = nil
        // Keep the last valid timestamp so a real, prolonged loss remains detectable.
    }

    private func isFresh(now: TimeInterval) -> Bool {
        guard let last = lastSampleAt else { return false }
        return now - last <= Self.maximumSampleGap
    }
}

enum AutomaticLockSafety {
    static func reason(evidence: [ProximityEvidence], requireAllAway: Bool,
                       now: TimeInterval, idleSeconds: TimeInterval,
                       awayDelay: TimeInterval, signalTimeout: TimeInterval) -> ProximityLockReason? {
        guard !evidence.isEmpty else { return nil }
        let reasons = evidence.map { $0.lockReason(now: now, awayDelay: awayDelay, signalTimeout: signalTimeout) }
        // Android screen-off can stop advertising indefinitely. Silence is unknown,
        // never proof of departure, even after the signal-loss timeout expires.
        let measuredAway = reasons.map { $0 == .away }
        let shouldLock = requireAllAway ? measuredAway.allSatisfy { $0 } : measuredAway.contains(true)
        guard shouldLock, idleSeconds >= awayDelay else { return nil }
        return .away
    }
}
