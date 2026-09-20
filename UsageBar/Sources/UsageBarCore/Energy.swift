import Foundation

/// Hardware counter deltas, not integration of sparse instantaneous power samples.
public struct GPUEnergy: Sendable {
    private var baseline: (millijoules: Double, uptime: Double)?
    private var previous: (millijoules: Double, uptime: Double)?
    public private(set) var wattHours: Double?
    public private(set) var averageWatts: Double?

    public init() {}

    public mutating func record(millijoules: Double?, uptime: Double?) {
        guard let millijoules, let uptime, millijoules.isFinite, uptime.isFinite,
              millijoules >= 0, uptime >= 0
        else {
            self.wattHours = nil
            self.averageWatts = nil
            return
        }
        if self.baseline == nil || millijoules < (self.previous?.millijoules ?? 0)
            || uptime < (self.previous?.uptime ?? 0)
        {
            self.baseline = (millijoules, uptime)
            self.wattHours = nil
            self.averageWatts = nil
        }
        self.previous = (millijoules, uptime)
        guard let baseline = self.baseline, uptime > baseline.uptime else { return }
        let joules = (millijoules - baseline.millijoules) / 1000
        self.wattHours = joules / 3600
        self.averageWatts = joules / (uptime - baseline.uptime)
    }

    public func cost(rate: Double?) -> Double? {
        guard let rate, rate.isFinite, rate >= 0, let wattHours = self.wattHours else { return nil }
        return wattHours / 1000 * rate
    }
}
