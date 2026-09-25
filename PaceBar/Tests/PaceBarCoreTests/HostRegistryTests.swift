import Foundation
import Testing
@testable import PaceBarCore

@Test func `legacy host migration preserves exact values and saves only hosts`() throws {
    let data = Data("""
    {"schemaVersion":2,"openRouterAuthFile":"test","nousURL":"http://NOUS:8080/","nousSSHHost":"tux@nous",
    "nousMetricsURL":"http://nous:8082/","hostUtilization":false,"electricityUSDPerKWh":0.12345}
    """.utf8)
    let config = try JSONDecoder().decode(Configuration.self, from: data)
    let host = try #require(config.hosts.first)
    #expect(host.name == "nous")
    #expect(host.serverURL == "http://NOUS:8080/")
    #expect(host.sshHost == "tux@nous")
    #expect(host.metricsURL == "http://nous:8082/")
    #expect(!host.hostUtilization)
    #expect(host.electricityUSDPerKWh == 0.12345)
    let saved = try JSONEncoder().encode(config)
    let object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    #expect(object["nousURL"] == nil)
    #expect(object["nousSSHHost"] == nil)
    #expect(object["nousMetricsURL"] == nil)
    #expect(object["hostUtilization"] == nil)
    #expect(object["electricityUSDPerKWh"] == nil)
    #expect(try JSONDecoder().decode(Configuration.self, from: saved).hosts == config.hosts)
}

@Test func `duplicate normalized host origins are rejected`() throws {
    var config = Configuration()
    config.hosts = [InferenceHost(serverURL: "http://HOST:80/"), InferenceHost(serverURL: "http://host")]
    #expect(throws: (any Error).self) { try config.validate() }
    config.hosts[1].serverURL = "http://other"
    try config.validate()
}

@Test func `two hosts retain separate energy totals and electricity rates`() throws {
    let first = InferenceHost(serverURL: "http://first", electricityUSDPerKWh: 0.10)
    let second = InferenceHost(serverURL: "http://second", electricityUSDPerKWh: 0.25)
    var readings = [first.id: HostReading(), second.id: HostReading()]
    try readings[first.id]?.energy.record(UsageParser.host("GPU 12, 6246, 10240, 27.2\nENERGY 3600000000 1000"))
    try readings[second.id]?.energy.record(UsageParser.host("GPU 12, 6246, 10240, 27.2\nENERGY 7200000000 1000"))
    #expect(readings[first.id]?.energy.wattHours == 1000)
    #expect(readings[second.id]?.energy.wattHours == 2000)
    let firstRate = try #require(first.electricityUSDPerKWh as Double?)
    let secondRate = try #require(second.electricityUSDPerKWh as Double?)
    #expect(readings[first.id]?.energy.cost(rate: firstRate) == 0.10)
    #expect(readings[second.id]?.energy.cost(rate: secondRate) == 0.50)
}

@Test func `removed hosts reject late completions without invalidating other hosts`() {
    let first = InferenceHost(serverURL: "http://first")
    var second = InferenceHost(serverURL: "http://second")
    var requests = HostRequests()
    requests.reconcile([first, second])
    let firstRevision = requests.revision(for: first.id)
    let secondRevision = requests.revision(for: second.id)
    requests.reconcile([second])
    #expect(!requests.accepts(first.id, revision: firstRevision))
    #expect(requests.accepts(second.id, revision: secondRevision))
    requests.reconcile([first, second])
    #expect(!requests.accepts(first.id, revision: firstRevision))
    second.metricsURL = "http://second:8082"
    requests.reconcile([first, second])
    #expect(!requests.accepts(second.id, revision: secondRevision))
    #expect(requests.accepts(first.id, revision: requests.revision(for: first.id)))
}

@Test func `host token histories remain isolated and equivalent origins reconnect`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = NousHistoryStore(file: directory.appendingPathComponent("history.json"))
    let first = try UsageParser.nous(
        Data(
            "llamacpp:tokens_predicted_total 12\nllamacpp:prompt_tokens_total 20\nllamacpp:prompt_tokens_cached_total 5"
                .utf8),
        model: "Example-9B")
    let second = try UsageParser.nous(
        Data(
            "llamacpp:tokens_predicted_total 35\nllamacpp:prompt_tokens_total 60\nllamacpp:prompt_tokens_cached_total 7"
                .utf8),
        model: "Example-9B")
    _ = await history.record(first, origin: "http://FIRST:80/")
    _ = await history.record(second, origin: "http://second")
    let (firstTotals, firstSaved) = await history.snapshot(origin: "http://first")
    let (secondTotals, secondSaved) = await history.snapshot(origin: "http://second")
    #expect(firstSaved && secondSaved)
    #expect(firstTotals.outputTokens == 12)
    #expect(secondTotals.outputTokens == 35)
}
