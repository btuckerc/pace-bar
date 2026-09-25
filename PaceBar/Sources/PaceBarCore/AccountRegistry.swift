import Foundation

public enum AccountProvider: String, Codable, CaseIterable, Sendable {
    case codex, claude
    public var title: String {
        self == .codex ? "Codex" : "Claude"
    }
}

public enum AccountSource: Codable, Equatable, Sendable {
    case codexFiles(paths: [String], managedHome: String?)
    case omp(database: String, credentialRowIDs: [Int64])
}

public struct AccountEnrollment: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let provider: AccountProvider
    public var providerAccountID: String?
    public var label: String
    public let slot: Int
    public var source: AccountSource
    public var enabled: Bool
    public var removed: Bool
    /// Discovery-only presentation data, deliberately excluded from configuration.
    public var identityHint = "Unknown account"

    private enum CodingKeys: String, CodingKey {
        case id, provider, providerAccountID, label, slot, source, enabled, removed
    }

    public var readingID: String {
        self.providerAccountID ?? self.id.uuidString
    }

    public init(
        id: UUID = UUID(),
        provider: AccountProvider,
        providerAccountID: String?,
        label: String,
        slot: Int,
        source: AccountSource,
        enabled: Bool = true,
        removed: Bool = false,
        identityHint: String = "Unknown account")
    {
        self.id = id
        self.provider = provider
        self.providerAccountID = providerAccountID
        self.label = label
        self.slot = slot
        self.source = source
        self.enabled = enabled
        self.removed = removed
        self.identityHint = identityHint
    }
}

public struct AccountCandidate: Identifiable, Equatable, Sendable {
    public let provider: AccountProvider
    public let providerAccountID: String?
    public var label: String
    public var source: AccountSource
    public var issue: String?
    public var identityHint: String
    public var id: String {
        "\(self.provider.rawValue):\(self.providerAccountID ?? String(describing: self.source))"
    }

    public init(
        provider: AccountProvider,
        providerAccountID: String?,
        label: String,
        source: AccountSource,
        issue: String? = nil,
        identityHint: String = "Unknown account")
    {
        self.provider = provider
        self.providerAccountID = providerAccountID
        self.label = label
        self.source = source
        self.issue = issue
        self.identityHint = identityHint
    }
}

public enum AccountMigrationState: String, Codable, Sendable {
    case pending, complete
}

extension Configuration {
    public func activeAccounts(_ provider: AccountProvider) -> [AccountEnrollment] {
        self.accounts.filter { $0.provider == provider && $0.enabled && !$0.removed }
    }

    /// Explicit enrollment repairs a known identity; discovery alone never calls this method.
    @discardableResult
    public mutating func enroll(_ candidate: AccountCandidate) throws -> UUID {
        guard let identity = candidate.providerAccountID, !identity.isEmpty, candidate.issue == nil else {
            throw UsageError.message("A readable account identity is required before enrollment.")
        }
        if let index = self.accounts.firstIndex(where: {
            $0.provider == candidate.provider && $0.providerAccountID == identity
        }) {
            self.accounts[index].source = AccountDiscovery.merged(self.accounts[index].source, candidate.source)
            self.accounts[index].removed = false
            self.accounts[index].enabled = true
            self.accounts[index].identityHint = candidate.identityHint
            return self.accounts[index].id
        }
        let number = self.nextAccountNumber[candidate.provider.rawValue] ?? 1
        self.nextAccountNumber[candidate.provider.rawValue] = number + 1
        let entry = AccountEnrollment(
            provider: candidate.provider,
            providerAccountID: identity,
            label: "\(candidate.provider.title) \(number)",
            slot: number - 1,
            source: candidate.source,
            identityHint: candidate.identityHint)
        self.accounts.append(entry)
        return entry.id
    }

    public func available(_ candidates: [AccountCandidate], provider: AccountProvider) -> [AccountCandidate] {
        candidates.filter { candidate in
            candidate.provider == provider && !self.accounts.contains {
                $0.provider == provider && $0.providerAccountID == candidate.providerAccountID && candidate
                    .providerAccountID != nil
            }
        }
    }

    public mutating func migrateAccounts(
        codex: [AccountCandidate],
        claude: [AccountCandidate],
        codexReadable: Bool = true,
        claudeReadable: Bool = true)
    {
        for provider in AccountProvider.allCases where self.accountMigration[provider.rawValue] != .complete {
            // Legacy labels (Codex 1…4) define the visible order, not the discovery order of their files.
            let candidates = (provider == .codex ? codex : claude).enumerated().sorted { lhs, rhs in
                let left = Self.legacyNumber(lhs.element, provider) ?? Int.max
                let right = Self.legacyNumber(rhs.element, provider) ?? Int.max
                return left == right ? lhs.offset < rhs.offset : left < right
            }.map(\.element)
            for candidate in candidates {
                if let identity = candidate.providerAccountID,
                   let index = self.accounts
                       .firstIndex(where: { $0.provider == provider && $0.providerAccountID == identity })
                {
                    self.accounts[index].source = AccountDiscovery.merged(self.accounts[index].source, candidate.source)
                    self.accounts[index].identityHint = candidate.identityHint
                    continue
                }
                if let index = self.accounts.firstIndex(where: {
                    $0.provider == provider && $0.providerAccountID == nil && $0.source == candidate.source
                }) {
                    self.accounts[index].providerAccountID = candidate.providerAccountID
                    self.accounts[index].identityHint = candidate.identityHint
                    continue
                }
                let preferred = Self.legacyNumber(candidate, provider)
                let next = self.nextAccountNumber[provider.rawValue] ?? 1
                let number = preferred.flatMap { value in
                    self.accounts.contains { $0.provider == provider && $0.slot == value - 1 } ? nil : value
                } ?? next
                self.accounts.append(AccountEnrollment(
                    provider: provider,
                    providerAccountID: candidate.providerAccountID,
                    label: "\(provider.title) \(number)",
                    slot: number - 1,
                    source: candidate.source,
                    identityHint: candidate.identityHint))
                self.nextAccountNumber[provider.rawValue] = max(next, number + 1)
            }
            let readable = provider == .codex ? codexReadable : claudeReadable
            self.accountMigration[provider.rawValue] = readable && candidates
                .allSatisfy { $0.issue == nil } ? .complete : .pending
        }
        self.schemaVersion = 2
    }

    private static func legacyNumber(_ candidate: AccountCandidate, _ provider: AccountProvider) -> Int? {
        Int(candidate.label.replacingOccurrences(of: provider.title + " ", with: ""))
    }
}

public enum AccountDiscovery {
    /// Only ENOENT is absence; permission and traversal failures remain visible.
    public static func isAbsent(_ url: URL) -> Bool {
        do {
            _ = try url.checkResourceIsReachable()
            return false
        } catch {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        }
    }

    public static func revalidate(_ candidate: AccountCandidate) throws {
        let enrollment = AccountEnrollment(
            provider: candidate.provider, providerAccountID: candidate.providerAccountID,
            label: candidate.label, slot: 0, source: candidate.source)
        if candidate.provider == .codex {
            _ = try self.resolveCodex(enrollment)
        } else {
            _ = try self.resolveClaude(enrollment)
        }
    }

    public static func validateLogout(home: URL, expectedIdentity: String?) throws {
        let auth = home.appendingPathComponent("auth.json")
        guard let expectedIdentity,
              home.lastPathComponent.hasPrefix(".codex-pace-"),
              UUID(uuidString: String(home.lastPathComponent.dropFirst(".codex-pace-".count))) != nil,
              home.standardizedFileURL == home.resolvingSymlinksInPath(),
              auth.standardizedFileURL == auth.resolvingSymlinksInPath(),
              try CodexAccount.parse(Configuration.boundedRead(auth.path)).id == expectedIdentity
        else {
            throw UsageError.message("The local home changed identity or is a symbolic link. Sign-out is blocked.")
        }
    }

    public static func merged(_ old: AccountSource, _ new: AccountSource) -> AccountSource {
        switch (old, new) {
        case let (.codexFiles(paths, home), .codexFiles(other, otherHome)):
            .codexFiles(paths: Array(Set(paths + other)).sorted(), managedHome: home ?? otherHome)
        case let (.omp(database, rows), .omp(otherDatabase, otherRows)) where database == otherDatabase:
            .omp(database: database, credentialRowIDs: Array(Set(rows + otherRows)).sorted())
        default: new
        }
    }

    public static func codexPaths(
        _ configuration: Configuration,
        roots: [String] = ["~/.codex-t3", "~/.codex-gui"]) throws -> [String]
    {
        var paths = [configuration.legacyCodexAuthFile ?? "~/.codex/auth.json", "~/.codex/auth.json"]
        for root in roots {
            do {
                let children = try FileManager.default.contentsOfDirectory(
                    at: Configuration.expand(root), includingPropertiesForKeys: nil)
                paths += children.sorted { $0.path < $1.path }.map { $0.appendingPathComponent("auth.json").path }
            } catch {
                if !self.isAbsent(Configuration.expand(root)) {
                    throw error
                }
            }
        }
        for enrollment in configuration.accounts {
            if case let .codexFiles(known, _) = enrollment.source { paths += known }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert(Configuration.expand($0).path).inserted }
    }

    public static func codex(paths: [String]) -> [AccountCandidate] {
        var candidates: [AccountCandidate] = []
        for (index, path) in paths.enumerated()
            where !self.isAbsent(Configuration.expand(path))
        {
            let nickname = Configuration.expand(path).deletingLastPathComponent().lastPathComponent
            let label = if index == 0 {
                "Codex 1"
            } else {
                switch nickname {
                case "second", "secondary": "Codex 2"
                case "last": "Codex 3"
                case "btc": "Codex 4"
                default: "account"
                }
            }
            let source = AccountSource.codexFiles(paths: [Configuration.expand(path).path], managedHome: nil)
            let parsed = try? CodexAccount.parse(Configuration.boundedRead(path))
            let candidate = AccountCandidate(
                provider: .codex,
                providerAccountID: parsed?.id,
                label: label,
                source: source,
                issue: parsed == nil ? "Auth file unreadable; identity unresolved." : nil,
                identityHint: parsed?.identityHint ?? "Unknown account")
            if let id = parsed?.id, let existing = candidates.firstIndex(where: { $0.providerAccountID == id }) {
                candidates[existing].source = self.merged(candidates[existing].source, source)
            } else { candidates.append(candidate) }
        }
        return candidates
    }

    public static func resolveCodex(_ enrollment: AccountEnrollment) throws -> CodexAccount {
        guard case let .codexFiles(paths, _) = enrollment.source, let expected = enrollment.providerAccountID else {
            throw UsageError.message("Sign-in identity unresolved.")
        }
        var newest: (CodexAccount, Date)?
        for path in paths {
            guard let parsed = try? CodexAccount.parse(Configuration.boundedRead(path)),
                  parsed.id == expected else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: Configuration.expand(path).path)
            let modified = attributes?[.modificationDate] as? Date ?? .distantPast
            if newest == nil || modified > newest!.1 { newest = (parsed, modified) }
        }
        guard let account = newest?.0
        else { throw UsageError.message("Sign-in missing or changed identity; review sign-in.") }
        return CodexAccount(
            id: account.id,
            label: enrollment.label,
            token: account.token,
            identityHint: account.identityHint)
    }

    public static func resolveClaude(_ enrollment: AccountEnrollment) throws -> ClaudeAccount {
        guard case let .omp(database, _) = enrollment.source,
              let account = try ClaudeAccount.discover(database: Configuration.expand(database))
                  .first(where: { $0.id == enrollment.providerAccountID }),
                  !account.token.isEmpty else { throw UsageError.message("OMP sign-in missing or changed identity.") }
        return ClaudeAccount(
            id: account.id, label: enrollment.label, token: account.token, expires: account.expires,
            identityHint: account.identityHint)
    }
}
