import Foundation

/// Driver-lifetime energy, with recent average power from hardware counter deltas.
public struct GPUEnergy: Sendable {
    private var previous: (millijoules: Double, uptime: Double)?
    public private(set) var wattHours: Double?
    public private(set) var averageWatts: Double?

    public init() {}

    public mutating func record(millijoules: Double?, uptime: Double?) {
        self.averageWatts = nil
        guard let millijoules, millijoules.isFinite, millijoules >= 0 else {
            self.wattHours = nil
            return
        }
        // The hardware owns this total; restarting the app must not subtract a new baseline.
        self.wattHours = millijoules / 3_600_000
        guard let uptime, uptime.isFinite, uptime >= 0 else {
            self.previous = nil
            return
        }
        defer { self.previous = (millijoules, uptime) }
        guard let previous = self.previous,
              millijoules >= previous.millijoules, uptime > previous.uptime else { return }
        self.averageWatts = (millijoules - previous.millijoules) / 1000 / (uptime - previous.uptime)
    }

    public func cost(rate: Double?) -> Double? {
        guard let rate, rate.isFinite, rate >= 0, let wattHours = self.wattHours else { return nil }
        return wattHours / 1000 * rate
    }
}
