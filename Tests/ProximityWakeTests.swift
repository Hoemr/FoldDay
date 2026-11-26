import Foundation

@main
enum ProximityWakeTests {
    static func main() {
        var device = ProximityEvidence()
        device.observe(rssi: -59, now: 0, unlockRSSI: -85, lockRSSI: -85)
        device.observe(rssi: -59, now: 1, unlockRSSI: -85, lockRSSI: -85)
        precondition(device.isStablyClose(now: 1))

        var session = ProximitySession()
        session.sawNearby()
        precondition(!session.canAttemptUnlock)

        // The phone never left. A sleeping display requires fresh samples.
        device.expireSignal()
        precondition(!device.isStablyClose(now: 2))
        device.observe(rssi: -63, now: 2, unlockRSSI: -85, lockRSSI: -85)
        precondition(!device.isStablyClose(now: 2))
        device.observe(rssi: -62, now: 3, unlockRSSI: -85, lockRSSI: -85)
        precondition(device.isStablyClose(now: 3))
        precondition(session.requestDisplayWake())
        precondition(!session.requestDisplayWake())
        precondition(!session.canAttemptUnlock)

        session.displayWokeWhileLocked()
        precondition(session.consumeUnlockAttempt())
        session.displayWokeWhileLocked()
        precondition(!session.consumeUnlockAttempt())
        session.unlocked(nearby: true)
        precondition(session.requestDisplayWake())
        precondition(!session.canAttemptUnlock)

        // An automatically locked screen can still unlock after a measured return.
        session.requestedLock(accepted: true)
        precondition(session.consumeUnlockAttempt())
        precondition(!session.consumeUnlockAttempt())

        print("Nearby-without-departure wake and single unlock attempt passed.")
    }
}
