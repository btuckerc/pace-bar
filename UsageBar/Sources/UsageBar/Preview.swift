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
                label: "account\($0)@example.com",
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
        let view = Dashboard(store: store, openSettings: {}).background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 390, height: 540)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else { throw UsageError.message("Preview rendering failed") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:])
        else { throw UsageError.message("Preview encoding failed") }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
