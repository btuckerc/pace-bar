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
}
