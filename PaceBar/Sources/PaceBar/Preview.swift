import AppKit
import PaceBarCore
import SwiftUI

/// Deterministic layout artifact, with fictitious identities and no network requests.
@MainActor
enum Preview {
    static func render(to path: String) throws {
        let store = UsageStore(loadConfiguration: false)
        let host = InferenceHost(electricityUSDPerKWh: 0.15)
        store.configuration.hosts = [host]
        var reading = HostReading()
        let snapshot = try UsageParser.codex(Data("""
        {"plan_type":"pro","rate_limit_reset_credits":{"available_count":0},"rate_limit":{"primary_window":{
        "used_percent":23,"reset_at":\(Int(Date().timeIntervalSince1970 + 518_400)),"limit_window_seconds":604800}}}
        """.utf8))
        store.codex = (1...4).map {
            CodexReading(
                id: "fixture-\($0)",
                label: CodexAccount.labels[$0 - 1],
                snapshot: snapshot,
                updated: Date(),
                error: nil)
        }
        store.codexCost = APICostEstimate(
            usd: 1234.56, unpricedRecords: 0, pricedRecords: 240, incomplete: false,
            ratesUpdated: Date(), weekUSD: 345.67)
        let resets = [Date().addingTimeInterval(9000), Date().addingTimeInterval(345_600)]
            .map { ISO8601DateFormatter().string(from: $0) }
        store.claude = try [ClaudeReading(
            id: "fixture-claude", label: "Claude 1",
            windows: UsageParser.claude(Data("""
            {"five_hour":{"utilization":12,"resets_at":"\(resets[0])"},
            "seven_day":{"utilization":31,"resets_at":"\(resets[1])"}}
            """.utf8)),
            updated: Date(), error: nil)]
        store.claudeCost = APICostEstimate(
            usd: 210.4, unpricedRecords: 0, pricedRecords: 80, incomplete: false,
            ratesUpdated: Date(), weekUSD: 98.1)
        store.router = try UsageParser.openRouter(
            key: Data("{\"data\":{\"usage_daily\":0.1,\"usage_weekly\":1.2,\"usage_monthly\":3.4}}".utf8),
            credits: Data("{\"data\":{\"total_credits\":40,\"total_usage\":7.32}}".utf8), warning: nil)
        reading.nous = try UsageParser.nous(Data("""
        llamacpp:tokens_predicted_total 31978
        llamacpp:prompt_tokens_total 116790
        llamacpp:prompt_tokens_cached_total 479407
        llamacpp:predicted_tokens_seconds 42.5
        """.utf8), model: "Example-9B-Q5_K_M")
        reading.lifetime = NousLifetimeTotals(
            promptTokens: 116_790, cachedTokens: 479_407, outputTokens: 31978)
        reading.hardware = try UsageParser.host("""
        GPU 12, 6246, 10240, 27.2
                      total used free shared buff/cache available
        Mem:          31027 8499 12000 10 10528 22000
        cpu 100 0 50 850 0 0 0 0
        """)
        reading.cpuPercent = 8.4
        try reading.energy.record(UsageParser.host("GPU 12, 6246, 10240, 27.2\nENERGY 1000 1000"))
        try reading.energy.record(UsageParser.host("GPU 12, 6246, 10240, 27.2\nENERGY 360001000 4600"))
        store.hostReadings[host.id] = reading
        if ProcessInfo.processInfo.arguments.contains("--preview-host-offline") {
            let key = UsageStore.hostKey(host.id, hardware: false)
            store.updated[key] = Date().addingTimeInterval(-600)
            store.errors[key] = "Nothing is listening on port 8080 on nous; start your inference server."
            store.hostReadings[host.id]?.inferenceFailed()
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-host-paused") {
            store.hostReadings[host.id]?.inferencePaused(
                until: Date().addingTimeInterval(7200),
                reason: "nous GPU is in use by round6.sh until 14:06 UTC; inference resumes automatically.")
        }
        store.codex[2].snapshot = try UsageParser.codex(Data("""
        {"plan_type":"pro","rate_limit_reset_credits":{"available_count":0},"rate_limit":{"primary_window":{
        "used_percent":100,"reset_at":\(Int(Date().timeIntervalSince1970 + 28800)),"limit_window_seconds":604800}},
        "additional_rate_limits":[{"limit_name":"gpt-reserve","rate_limit":{"primary_window":{
        "used_percent":0,"reset_at":\(Int(Date().timeIntervalSince1970 + 604_800)),"limit_window_seconds":604800}}}]}
        """.utf8))
        for (index, account) in store.codex.enumerated() {
            guard index != 2 else { continue }
            for ago in [2, 1] {
                let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(ago) * 86400 + 3600)
                for (offset, used) in [(0.0, 0.0), (3600.0, [20.0, 5.0, 0.0, 60.0][index])] {
                    let sample = try UsageParser.codex(Data("""
                    {"plan_type":"pro","rate_limit_reset_credits":{"available_count":0},"rate_limit":{"primary_window":{
                    "used_percent":\(used),"reset_at":\(Int(start.timeIntervalSince1970 + 604_800)),"limit_window_seconds":604800}}}
                    """.utf8))
                    store.quotaForecast.record(
                        account: account.id,
                        windows: sample.windows,
                        at: start.addingTimeInterval(offset))
                }
            }
        }
        let view = Dashboard(store: store, openSettings: {}).background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else { throw UsageError.message("Preview rendering failed") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:])
        else { throw UsageError.message("Preview encoding failed") }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
