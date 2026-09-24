import Testing
@testable import UsageBarCore

@Test func `Hardware snapshot identity detects a reboot even when counters grew`() throws {
    var energy = GPUEnergy()
    try energy.record(UsageParser.host("Mem: 100 50\nENERGY 3600000 100\nENERGY_ID boot-a-gpu"))
    try energy.record(UsageParser.host("Mem: 100 50\nENERGY 7200000 200\nENERGY_ID boot-b-gpu"))
    #expect(energy.wattHours == 3)
    #expect(energy.averageWatts == nil)
}

@Test func `Estimated snapshot identity distinguishes an old checkpoint from a new collector`() throws {
    var energy = GPUEnergy()
    try energy.record(UsageParser.host("Mem: 100 50\nENERGY_ESTIMATE 7200000 100\nENERGY_ID estimate-a"))
    try energy.record(UsageParser.host("Mem: 100 50\nENERGY_ESTIMATE 3600000 10\nENERGY_ID estimate-a"))
    #expect(energy.wattHours == 2)
    try energy.record(UsageParser.host("Mem: 100 50\nENERGY_ESTIMATE 3600000 20\nENERGY_ID estimate-b"))
    #expect(energy.wattHours == 3)
    #expect(energy.isEstimated)
}
