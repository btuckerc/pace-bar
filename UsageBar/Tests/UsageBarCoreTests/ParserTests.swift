import Foundation
import Testing
@testable import UsageBarCore

private func json(_ text: String) -> Data { Data(text.utf8) }

@Test func `Codex keeps valid quota when an additional lane is malformed`() throws {
    let value = try UsageParser.codex(json("""
    {"plan_type":"pro","rate_limit":{"primary_window":{
      "used_percent":23,"reset_at":1800000000,"limit_window_seconds":18000}},
     "additional_rate_limits":[{"limit_name":"Broken","rate_limit":"invalid"},
       {"limit_name":"Alternate","rate_limit":{"secondary_window":{
         "used_percent":80,"reset_at":1800000000,"limit_window_seconds":604800}}}]}
    """))
    #expect(value.windows.count == 2)
    #expect(value.windows[0].remainingPercent == 77)
    #expect(value.windows[1].label == "Alternate · Weekly")
}

@Test func `Weekly only primary window is labeled by duration`() throws {
    let value = try UsageParser.codex(json("""
    {"rate_limit":{"primary_window":{"used_percent":101,"reset_at":1800000000,
      "limit_window_seconds":604800}}}
    """))
    #expect(value.windows[0].label == "Weekly")
    #expect(value.windows[0].remainingPercent == 0)
    #expect(value.windows[0].usedPercent == 101)
}

@Test func `Missing quota never becomes a fabricated zero`() {
    #expect(throws: (any Error).self) { try UsageParser.codex(json("{\"rate_limit\":null}")) }
    #expect(throws: (any Error).self) {
        try UsageParser.openRouter(key: nil, credits: nil, warning: nil)
    }
}

@Test func `Key spend survives unavailable account balance`() throws {
    let value = try UsageParser.openRouter(
        key: json("{\"data\":{\"usage_daily\":0,\"usage_monthly\":1.5,\"limit_remaining\":30}}"),
        credits: nil, warning: "Account balance unavailable")
    #expect(value.balance == nil)
    #expect(value.today == 0)
    #expect(value.month == 1.5)
    #expect(value.keyRemaining == 30)
    #expect(value.warning != nil)
}

@Test func `Account balance and key cap stay independent`() throws {
    let value = try UsageParser.openRouter(
        key: json("{\"data\":{\"limit_remaining\":30}}"),
        credits: json("{\"data\":{\"total_credits\":5,\"total_usage\":3.1}}"), warning: nil)
    #expect(try abs(#require(value.balance) - 1.9) < 0.00001)
    #expect(value.keyRemaining == 30)
    #expect(value.month == nil)
}

@Test func `Model discovery follows loaded model without choosing unloaded models`() throws {
    let value = try UsageParser.loadedModel(json("""
    {"data":[{"id":"unloaded","status":{"value":"unloaded"}},
     {"id":"active / model","status":{"value":"loaded"}}]}
    """))
    #expect(value == "active / model")
    #expect(try UsageParser.loadedModel(json("{\"data\":[]}")) == nil)
    #expect(try UsageParser.loadedModel(json("{\"data\":[{\"id\":\"single\"}]}")) == "single")
}

@Test func `Nous keeps prompt cache and generation counters separate`() throws {
    let value = try UsageParser.nous(json("""
    # HELP llamacpp:prompt_tokens_total Prompt tokens
    llamacpp:prompt_tokens_total 100
    llamacpp:prompt_tokens_cached_total 200
    llamacpp:tokens_predicted_total 30
    llamacpp:predicted_tokens_seconds 91.8
    llamacpp:requests_processing 0
    llamacpp:requests_deferred 0
    irrelevant{label="hello"} 999
    """), model: "model")
    #expect(value.promptTokens == 100)
    #expect(value.cachedTokens == 200)
    #expect(value.outputTokens == 30)
    #expect(value.generationTPS == 91.8)
    #expect(value.processing == 0)
}

@Test func `Malformed and nonfinite counters are rejected`() {
    #expect(throws: (any Error).self) {
        try UsageParser.nous(
            json("llamacpp:prompt_tokens_total NaN\nllamacpp:tokens_predicted_total Inf"),
            model: "model")
    }
    #expect(throws: (any Error).self) {
        try UsageParser.nous(Data(repeating: 65, count: 65537), model: "model")
    }
    #expect(UsageParser.number(true) == nil)
    #expect(UsageParser.number("NaN") == nil)
    #expect(UsageParser.number(-1) == nil)
}

@Test func `Host parsing calculates CPU from counter deltas and excludes guest duplication`() throws {
    let initial = try UsageParser.host("""
    GPU 25, 6000, 10240, 80.5
    Mem: 31000 8000 1000 50 22000 23000
    cpu 100 0 100 700 100 0 0 0 200 100
    """)
    let next = try UsageParser.host("cpu 150 0 100 850 100 0 0 0 200 100")
    #expect(initial.gpuPercent == 25)
    #expect(initial.vramUsedMiB == 6000)
    #expect(initial.ramUsedMiB == 8000)
    #expect(initial.cpu?.total == 1000)
    #expect(next.cpu?.usage(since: initial.cpu) == 25)
    #expect(initial.cpu?.usage(since: next.cpu) == nil)
    #expect(initial.cpu?.usage(since: nil) == nil)
}

@Test func `Unavailable NVIDIA readings do not erase host memory`() throws {
    let value = try UsageParser.host("GPU [N/A], 6000, 10240, [N/A]\nMem: 31000 8000 1000 50 22000 23000")
    #expect(value.gpuPercent == nil)
    #expect(value.vramTotalMiB == 10240)
    #expect(value.ramTotalMiB == 31000)
}

@Test func `Credentials only accept the intended account format`() throws {
    #expect(try Credentials.codex(json("{\"tokens\":{\"access_token\":\"fixture\",\"account_id\":\"test-account\"}}"))
        .account == "test-account")
    #expect(try Credentials.openRouter(json("{\"openrouter\":{\"type\":\"api\",\"key\":\"fixture\"}}")) == "fixture")
    #expect(throws: (any Error).self) { try Credentials.codex(json("{\"OPENAI_API_KEY\":\"fixture\"}")) }
    #expect(throws: (any Error).self) {
        try Credentials.openRouter(json("{\"openai\":{\"type\":\"api\",\"key\":\"fixture\"}}"))
    }
}

@Test func `Configuration rejects credential URLs and shell arguments`() throws {
    var config = Configuration()
    try config.validate()
    config.nousSSHHost = "nous; touch /tmp/no"
    #expect(throws: (any Error).self) { try config.validate() }
    config.nousSSHHost = "-oProxyCommand=bad"
    #expect(throws: (any Error).self) { try config.validate() }
    config.nousSSHHost = "tux@nous"
    config.nousURL = "http://user:password@nous:8080"
    #expect(throws: (any Error).self) { try config.validate() }
    config.nousURL = "http://nous:8080?model=foo"
    #expect(throws: (any Error).self) { try config.validate() }
}

@Test func `Account discovery deduplicates identities and keeps separate quotas separate`() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identities = ["one", "two", "three", "four", "two"]
    var paths: [String] = []
    for (index, identity) in identities.enumerated() {
        let file = directory.appendingPathComponent("\(index).json")
        try json("{\"tokens\":{\"access_token\":\"token-\(index)\",\"account_id\":\"\(identity)\"}}")
            .write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(index + 1))],
            ofItemAtPath: file.path)
        paths.append(file.path)
    }
    let accounts = try CodexAccount.discover(paths: paths)
    #expect(accounts.map(\.id) == ["one", "two", "three", "four"])
    #expect(accounts[1].token == "token-4")
    #expect(accounts[0].token == "token-0")
}

@Test func `Unreadable account stays visible without contaminating another account`() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try json("{}").write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let accounts = try CodexAccount.discover(paths: [file.path])
    #expect(accounts.count == 1)
    #expect(accounts[0].token.isEmpty)
    #expect(throws: (any Error).self) {
        try CodexAccount.parse(json("{\"tokens\":{\"access_token\":\"test\"}}"))
    }
}

@Test func `Account aliases hide emails and follow the requested order`() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var paths: [String] = []
    for name in ["main", "btc", "last", "second"] {
        let home = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("auth.json")
        let claims = Data("{\"email\":\"private@example.com\"}".utf8).base64EncodedString()
        try json("""
        {"tokens":{"access_token":"fixture","account_id":"\(name)","id_token":"e30.\(claims).signature"}}
        """).write(to: file)
        paths.append(file.path)
    }
    let accounts = try CodexAccount.discover(paths: paths)
    #expect(accounts.map(\.label) == ["primary", "secondary", "last", "btc"])
    #expect(accounts.map(\.id) == ["main", "second", "last", "btc"])
    #expect(!accounts.contains { $0.label.contains("@") })
}

@Test func `Compact quota titles preserve durations and reserve identity`() throws {
    let value = try UsageParser.codex(json("""
    {"rate_limit":{"primary_window":{"used_percent":3,"reset_at":1800000000,"limit_window_seconds":18000},
    "secondary_window":{"used_percent":4,"reset_at":1800000000,"limit_window_seconds":604800}},
    "additional_rate_limits":[{"limit_name":"gpt-reserve","rate_limit":{"primary_window":{
    "used_percent":0,"reset_at":1800000000,"limit_window_seconds":604800}}}]}
    """))
    #expect(value.windows.map(\.compactLabel) == ["5h", "7d", "Reserve · 7d"])
    #expect(value.windows[2].label == "gpt-reserve · Weekly")
    #expect(value.windows[2].remainingPercent == 100)
}

@Test func `Hardware energy deltas convert to Wh average watts and cost`() {
    var energy = GPUEnergy()
    energy.record(millijoules: 1000, uptime: 100)
    #expect(energy.wattHours == nil)
    energy.record(millijoules: 3_601_000, uptime: 160)
    #expect(energy.wattHours == 1)
    #expect(energy.averageWatts == 60)
    #expect(energy.cost(rate: 0.15) == 0.00015)
    #expect(energy.cost(rate: nil) == nil)
}

@Test func `Energy resets do not create negative or borrowed consumption`() {
    var energy = GPUEnergy()
    energy.record(millijoules: 1000, uptime: 100)
    energy.record(millijoules: 3_601_000, uptime: 160)
    energy.record(millijoules: 10, uptime: 180)
    #expect(energy.wattHours == nil)
    energy.record(millijoules: 3_600_010, uptime: 240)
    #expect(energy.wattHours == 1)
    energy.record(millijoules: 7_200_010, uptime: 10)
    #expect(energy.wattHours == nil)
}

@Test func `Missing energy does not turn into zero and long gaps use counter deltas`() {
    var energy = GPUEnergy()
    energy.record(millijoules: 0, uptime: 100)
    energy.record(millijoules: nil, uptime: nil)
    #expect(energy.wattHours == nil)
    energy.record(millijoules: 360_000_000, uptime: 3700)
    #expect(energy.wattHours == 100)
    #expect(energy.averageWatts == 100)
    energy.record(millijoules: .nan, uptime: 3800)
    #expect(energy.wattHours == nil)
}

@Test func `Account spend remains correct when a particular key reports zero`() throws {
    let value = try UsageParser.openRouter(
        key: json("{\"data\":{\"usage_daily\":0,\"usage_weekly\":0,\"usage_monthly\":0}}"),
        credits: json("{\"data\":{\"total_credits\":100,\"total_usage\":75}}"), warning: nil)
    #expect(value.totalSpent == 75)
    #expect(value.balance == 25)
    #expect(value.month == 0)
}

@Test func `Optional energy settings decode older configuration and reject credential URLs`() throws {
    let old = json("""
    {"codexAuthFile":"test","openRouterAuthFile":"test","nousURL":"http://host:8080",
    "nousSSHHost":"host","hostUtilization":true}
    """)
    var config = try JSONDecoder().decode(Configuration.self, from: old)
    #expect(config.nousMetricsURL == nil)
    #expect(config.electricityUSDPerKWh == nil)
    config.nousMetricsURL = "http://user:secret@host:8082"
    #expect(throws: (any Error).self) { try config.validate() }
    config.nousMetricsURL = "http://host:8082"
    config.electricityUSDPerKWh = -1
    #expect(throws: (any Error).self) { try config.validate() }
}
