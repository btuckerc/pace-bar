import Foundation

/// Recorded cumulative GPU energy. Counter baselines persist; live averages do not.
public struct GPUEnergy: Codable, Equatable, Sendable {
    private var totalMilliJoules: Double?
    private var baseline: Double?
    private var source: HostEnergySource?
    private var epoch: String?
    private var lastUptime: Double?
    public private(set) var isEstimated = false
    public private(set) var averageWatts: Double?
    private var previous: Reading?

    private struct Reading: Equatable, Sendable {
        let counter: Double
        let uptime: Double
    }

    private enum CodingKeys: String, CodingKey {
        case totalMilliJoules, baseline, source, epoch, lastUptime, isEstimated
    }

    public init() {}

    public var wattHours: Double? {
        self.totalMilliJoules.map { $0 / 3_600_000 }
    }

    public mutating func record(_ snapshot: HostSnapshot) {
        self.averageWatts = nil
        guard let counter = Self.valid(snapshot.energyMilliJoules) else {
            self.previous = nil
            return
        }
        let uptime = Self.valid(snapshot.uptime)
        let first = self.baseline == nil
        let sourceChanged = self.source != nil && self.source != snapshot.energySource
        let epochChanged = !sourceChanged && self.epoch != nil && snapshot.energyCounterID != nil
            && self.epoch != snapshot.energyCounterID
        let uptimeRolledBack = if let uptime, let lastUptime = self.lastUptime {
            uptime < lastUptime
        } else {
            false
        }
        let counterRolledBack = counter < (self.baseline ?? counter)
        let hardwareReset = !sourceChanged && snapshot.energySource == .hardware
            && (epochChanged || counterRolledBack || uptimeRolledBack)
        let estimateReset = !sourceChanged && snapshot.energySource == .estimate && epochChanged
        // An older durable checkpoint is not a new counter: wait until it passes the saved high-water mark.
        let replayingCheckpoint = !sourceChanged && !epochChanged
            && snapshot.energySource == .estimate && counterRolledBack
        let delta: Double = if first || hardwareReset || estimateReset {
            counter
        } else if sourceChanged {
            // Different collection methods may cover the same history. Never add that overlap twice.
            0
        } else {
            max(0, counter - (self.baseline ?? counter))
        }
        let total = (self.totalMilliJoules ?? 0) + delta
        guard total.isFinite else {
            self.previous = nil
            return
        }
        if !first, !sourceChanged, !epochChanged, !hardwareReset, !uptimeRolledBack, !replayingCheckpoint,
           let previous = self.previous, let uptime, uptime > previous.uptime, counter >= previous.counter
        {
            let watts = (counter - previous.counter) / 1000 / (uptime - previous.uptime)
            self.averageWatts = watts.isFinite ? watts : nil
        }
        self.totalMilliJoules = total
        if !replayingCheckpoint { self.baseline = counter }
        self.source = snapshot.energySource
        self.epoch = sourceChanged ? snapshot.energyCounterID : (snapshot.energyCounterID ?? self.epoch)
        self.lastUptime = uptime
        if snapshot.energySource == .estimate, first || delta > 0 { self.isEstimated = true }
        self.previous = replayingCheckpoint ? nil : uptime.map { Reading(counter: counter, uptime: $0) }
    }

    public func cost(rate: Double?) -> Double? {
        guard let rate = Self.valid(rate), let wattHours = self.wattHours else { return nil }
        let cost = wattHours / 1000 * rate
        return cost.isFinite ? cost : nil
    }

    var isValid: Bool {
        guard [self.totalMilliJoules, self.baseline, self.lastUptime]
            .compactMap(\.self).allSatisfy({ Self.valid($0) != nil }) else { return false }
        if self.baseline == nil {
            return self.totalMilliJoules == nil && self.source == nil && self.epoch == nil
                && self.lastUptime == nil && !self.isEstimated
        }
        return self.totalMilliJoules != nil && self.source != nil
            && (self.epoch.map { !$0.isEmpty && $0.count <= 160 && !$0.contains(where: \.isWhitespace) } ?? true)
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
