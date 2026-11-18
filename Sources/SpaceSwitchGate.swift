import Foundation

/// Allows one live Space selection at a time and rejects targets that have
/// already disappeared from Mission Control's current Space snapshot.
struct SpaceSwitchGate {
    private(set) var activeToken: UInt64?
    private var nextToken: UInt64 = 0

    var isBusy: Bool { activeToken != nil }

    mutating func begin(targetID: UInt64, availableSpaceIDs: Set<UInt64>) -> UInt64? {
        guard availableSpaceIDs.contains(targetID) else { return nil }
        return begin()
    }

    mutating func begin() -> UInt64? {
        guard activeToken == nil else { return nil }
        nextToken &+= 1
        activeToken = nextToken
        return nextToken
    }

    func isActive(_ token: UInt64) -> Bool {
        activeToken == token
    }

    mutating func finish(_ token: UInt64) {
        guard activeToken == token else { return }
        activeToken = nil
    }

    static func selfTest() -> Bool {
        var gate = SpaceSwitchGate()
        guard gate.begin(targetID: 12, availableSpaceIDs: [11, 12]) == 1,
              gate.begin(targetID: 11, availableSpaceIDs: [11, 12]) == nil,
              gate.begin(targetID: 13, availableSpaceIDs: [11, 12]) == nil,
              gate.isActive(1) else { return false }
        gate.finish(0)
        guard gate.isActive(1) else { return false }
        gate.finish(1)
        guard !gate.isBusy else { return false }
        guard gate.begin(targetID: 13, availableSpaceIDs: [11, 12]) == nil,
              let add = gate.begin(), gate.begin(targetID: 11, availableSpaceIDs: [11]) == nil,
              gate.begin() == nil else { return false }
        gate.finish(add)
        return !gate.isBusy
    }
}
