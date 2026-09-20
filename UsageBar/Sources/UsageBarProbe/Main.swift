import Foundation
import UsageBarCore

/// Explicit, one-shot live validation. Never runs as part of the test suite and
/// prints only capability counts, not credentials or provider response bodies.
@main
struct Probe {
    static func main() async {
        do {
            let config = try Configuration.load()
            let services = Services()
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--import-history" {
                try await self.importHistory(path: CommandLine.arguments[2], configuration: config, services: services)
                return
            }
            let failures = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for provider in ["Codex", "OpenRouter", "Nous", "Host"] {
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
}
