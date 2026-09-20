import AppKit
import SwiftUI
import UsageBarCore

/// Deterministic layout artifact, with fictitious identities and no network requests.
@MainActor
enum Preview {
    static func render(to path: String) throws {
        let store = UsageStore()
        let snapshot = try UsageParser.codex(Data("""
        {"plan_type":"pro","rate_limit":{"primary_window":{
        "used_percent":23,"reset_at":\(Int(Date().timeIntervalSince1970 + 518_400)),"limit_window_seconds":604800}}}
        """.utf8))
        store.codex = (1...4).map {
            CodexReading(
                id: "fixture-\($0)",
                label: ["primary", "secondary", "last", "btc"][$0 - 1],
                snapshot: snapshot,
                updated: Date(),
                error: nil)
        }
        store.router = try UsageParser.openRouter(
            key: Data("{\"data\":{\"usage_daily\":0.1,\"usage_weekly\":1.2,\"usage_monthly\":3.4}}".utf8),
            credits: Data("{\"data\":{\"total_credits\":40,\"total_usage\":7.32}}".utf8), warning: nil)
        store.nous = try UsageParser.nous(Data("""
        llamacpp:tokens_predicted_total 31978
        llamacpp:prompt_tokens_total 116790
        llamacpp:prompt_tokens_cached_total 479407
        llamacpp:predicted_tokens_seconds 42.5
        """.utf8), model: "Example-9B-Q5_K_M")
        store.host = try UsageParser.host("""
        GPU 12, 6246, 10240, 27.2
                      total used free shared buff/cache available
        Mem:          31027 8499 12000 10 10528 22000
        cpu 100 0 50 850 0 0 0 0
        """)
        store.cpuPercent = 8.4
        store.configuration.electricityUSDPerKWh = 0.15
        store.gpuEnergy.record(millijoules: 1000, uptime: 1000)
        store.gpuEnergy.record(millijoules: 360_001_000, uptime: 4600)
        store.codex[2].snapshot = try UsageParser.codex(Data("""
        {"plan_type":"pro","rate_limit":{"primary_window":{
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
                    {"plan_type":"pro","rate_limit":{"primary_window":{
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
