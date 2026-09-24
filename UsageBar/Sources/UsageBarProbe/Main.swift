import Foundation
import UsageBarCore

/// Explicit, one-shot live validation. Never runs as part of the test suite and
/// prints only capability counts, not credentials or provider response bodies.
@main
struct Probe {
    static func main() async {
        do {
            let config = try Configuration.load()
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--import-cost-history" {
                try await self.importCostHistory(path: CommandLine.arguments[2], configuration: config)
                return
            }
            let services = Services()
            if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--pool" {
                try await self.showPool(configuration: config, services: services)
                return
            }
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--import-history" {
                try await self.importHistory(path: CommandLine.arguments[2], configuration: config, services: services)
                return
            }
            let failures = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for provider in ["Codex", "Claude", "OpenRouter", "Nous", "Host"] {
                    group.addTask {
                        do {
                            let detail: String
                            switch provider {
                            case "Codex":
                                let accounts = try CodexAccount.discover(config)
                                for (index, account) in accounts.enumerated() {
                                    let value = try await services.codex(account: account)
                                    print("Codex account \(index + 1): \(value.windows.count) quota windows")
                                }
                                detail = "\(accounts.count) distinct accounts"
                            case "Claude":
                                let accounts = try ClaudeAccount.discover()
                                for account in accounts {
                                    let windows = try await services.claude(account: account)
                                    print("\(account.label): \(windows.map(\.compactLabel).joined(separator: ", "))")
                                }
                                detail = "\(accounts.count) OMP sign-ins"
                            case "OpenRouter":
                                let value = try await services.openRouter(config)
                                detail = "balance=\(value.balance != nil), account spend=\(value.totalSpent != nil)"
                            case "Nous":
                                let value = try await services.nous(config)
                                detail = "model loaded=\(value.model != nil), token counters=\(value.outputTokens != nil)"
                            default:
                                let value = try await services.host(config)
                                detail = "GPU=\(value.gpuPercent != nil), RAM=\(value.ramUsedMiB != nil)"
                                    + ", CPU=\(value.cpu != nil), energy=\(value.energyMilliJoules != nil)"
                            }
                            print("\(provider): OK (\(detail))")
                            return false
                        } catch {
                            print(
                                "\(provider): FAILED (\(error is UsageError ? error.localizedDescription : "connection or credentials"))")
                            return true
                        }
                    }
                }
                var failures = 0
                for await failed in group where failed {
                    failures += 1
                }
                return failures
            }
            exit(failures == 0 ? 0 : 1)
        } catch {
            print("Configuration: FAILED")
            exit(1)
        }
    }

    /// Local usage metadata only: no account probes, credentials, Keychain, or inference calls.
    private static func importCostHistory(path: String, configuration: Configuration) async throws {
        let now = Date()
        let history = CodexCostHistory()
        var snapshot = await history.records(authFile: configuration.codexAuthFile, now: now)
        var passes = 1
        while snapshot.pendingScan, passes < 64 {
            snapshot = await history.records(authFile: configuration.codexAuthFile, now: now)
            passes += 1
        }
        let pricing = APICostPricing()
        let estimate = await pricing.estimate(records: snapshot.records, incomplete: snapshot.incomplete, now: now)
        var models: [String: [String: Double]] = [:]
        for record in snapshot.records {
            var totals = models[record.model] ?? [:]
            totals["input", default: 0] += record.tokens.input
            totals["cachedInput", default: 0] += record.tokens.cachedInput
            totals["cacheWrite", default: 0] += record.tokens.cacheWrite
            totals["output", default: 0] += record.tokens.output
            totals["records", default: 0] += 1
            models[record.model] = totals
        }
        let window = APICostWindow.bounds(now: now)
        let report: [String: Any] = [
            "asOf": now.timeIntervalSince1970,
            "windowStart": window.lowerBound.timeIntervalSince1970,
            "windowEnd": window.upperBound.timeIntervalSince1970,
            "retainedRecords": snapshot.retainedRecords,
            "importedT3": snapshot.importedT3,
            "incomplete": estimate.incomplete,
            "pendingScan": snapshot.pendingScan,
            "pricedRecords": estimate.pricedRecords,
            "unpricedRecords": estimate.unpricedRecords,
            "weekUSD": estimate.weekUSD as Any? ?? NSNull(),
            "usd": estimate.usd as Any? ?? NSNull(),
            "models": models,
        ]
        let file = URL(fileURLWithPath: path)
        guard !FileManager.default.fileExists(atPath: file.path) else {
            throw UsageError.message("Refusing to overwrite an existing report.")
        }
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(
            to: file,
            options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        print("Local usage history: \(snapshot.retainedRecords) retained records.")
        print(
            "30-day priced records: \(estimate.pricedRecords); unpriced: \(estimate.unpricedRecords); partial: \(estimate.incomplete).")
        print("Private reconciliation report written. No account probes were run.")
    }

    private static func importHistory(path: String, configuration: Configuration, services: Services) async throws {
        let file = URL(fileURLWithPath: path)
        guard try (file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1024 * 1024 else {
            throw UsageError.message("History import is too large.")
        }
        var readings: [CodexReading] = []
        for account in try CodexAccount.discover(configuration) {
            let snapshot = try await services.codex(account: account)
            readings.append(CodexReading(
                id: account.id,
                label: account.label,
                snapshot: snapshot,
                updated: Date(),
                error: nil))
        }
        let forecast = try await QuotaHistoryStore().importHistory(
            Data(contentsOf: file),
            readings: readings,
            now: Date())
        for reading in readings {
            for window in reading.snapshot?.windows ?? [] {
                let projection = forecast.project(account: reading.id, window: window, now: Date())
                print("\(reading.label) · \(window.compactLabel): \(projection.method)")
            }
        }
    }

    private static func showPool(configuration: Configuration, services: Services) async throws {
        var readings: [CodexReading] = []
        for account in try CodexAccount.discover(configuration) {
            let snapshot = try await services.codex(account: account)
            readings.append(CodexReading(
                id: account.id,
                label: account.label,
                snapshot: snapshot,
                updated: Date(),
                error: nil))
        }
        let history = await QuotaHistoryStore().snapshot()
        let pool = history.pool(readings, now: Date())
        print("Pooled active days: \(pool.activeDays); daily percentage points: \(pool.dailyConsumption ?? 0)")
        print(pool.explanation)
        print("Available banked resets: " +
            (CodexResetInventory.total(readings, now: Date()).map(String.init) ?? "unknown"))
        print("Pool remaining: \(pool.remainingPercent.map { String(format: "%.1f%%", $0) } ?? "unknown")")
        print("Empty at: \(pool.exhaustsAt?.formatted() ?? "not before \(pool.coveredThrough?.formatted() ?? "?")")")
        print(String(format: "Resets unused: %.1f%% of pool", pool.expiringPercent))
        for reading in readings {
            print("\(reading.label): \(String(format: "%.1f", pool.expiring[reading.id] ?? 0))% resets unused")
        }
    }
}
