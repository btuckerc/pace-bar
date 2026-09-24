import Foundation

/// Bootstraps T3's retained token history once, then maintains its own durable append-only scan cache.
public actor CodexCostHistory {
    private let home: URL
    private let archiveFile: URL
    private let t3Directory: URL
    private let scanner = CodexCostScanner()
    private var archive = CodexHistoryArchive()
    private var loaded = false
    private var storageAvailable = true
    private var savePending = false

    private struct ScanFile {
        let url: URL
        let provider: String
        let size: Int
        let modified: Date
    }

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        archiveFile: URL? = nil, t3Directory: URL? = nil)
    {
        self.home = home.standardizedFileURL
        self.archiveFile = archiveFile ?? home.appendingPathComponent(".local/share/usage-bar/codex-cost-history.json")
        self.t3Directory = t3Directory ?? home.appendingPathComponent(".t3/userdata")
    }

    public func records(
        authFile: String, now: Date = Date(), calendar: Calendar = .current)
        -> (records: [APICostRecord], incomplete: Bool, importedT3: Bool, retainedRecords: Int, pendingScan: Bool)
    {
        var incomplete = false
        self.load(incomplete: &incomplete)
        var changed = self.importT3(incomplete: &incomplete)
        // Commit the bootstrap before attempting any live scan; deleted source logs are still retained history.
        if changed { self.save(incomplete: &incomplete) }
        let files = self.files(authFile: authFile, incomplete: &incomplete)
        var budget = 512 * 1024 * 1024
        var pending = false
        for source in files {
            if Task.isCancelled { incomplete = true; pending = true; break }
            let file = source.url
            let size = source.size
            let milliseconds = source.modified.timeIntervalSince1970 * 1000
            let cached = self.archive.files[file.path]
            if let cached, cached.provider == source.provider, cached.size == size,
               abs(cached.mtimeMs - milliseconds) < 0.01, !cached.pendingScan,
               cached.scanVersion == CodexCostScanner.version(for: source.provider)
            {
                incomplete = incomplete || cached.incomplete
                continue
            }
            guard budget > 0 else { pending = true; continue }
            guard let parsed = self.scanner.read(
                file: file, previous: cached, size: size, mtimeMs: milliseconds, budget: &budget,
                provider: source.provider)
            else {
                incomplete = true // A read error never replaces retained records with an empty file.
                continue
            }
            self.archive.files[file.path] = parsed
            changed = true
            incomplete = incomplete || parsed.incomplete
            pending = pending || parsed.pendingScan
        }
        if changed || self.savePending { self.save(incomplete: &incomplete) }
        let window = APICostWindow.bounds(now: now, calendar: calendar)
        var output: [APICostRecord] = []
        var seen = Set<String>()
        var retained = 0
        for (path, file) in self.archive.files.sorted(by: { $0.key < $1.key }) {
            retained += file.records.count + file.tail.count
            guard file.provider == "codex" || file.provider == "omp" else { continue }
            incomplete = incomplete || file.incomplete || file.pendingScan
            var occurrences: [String: Int] = [:]
            for event in [file.records, file.tail].joined() {
                let tokens = event.tokens
                // T3 assigns occurrence suffixes per file to retain genuine repeated equal events while matching
                // copies.
                let key = [
                    event.sessionID.isEmpty ? path : event.sessionID,
                    String(event.timestampMs),
                    event.model,
                    String(tokens.input),
                    String(tokens.cachedInput),
                    String(tokens.cacheWrite),
                    String(tokens.output),
                    String(event.reasoning),
                ].joined(separator: "|")
                occurrences[key, default: 0] += 1
                let identity = event.dedupeKey ?? "\(key):\(occurrences[key, default: 0])"
                guard seen.insert(identity).inserted else { continue }
                let date = Date(timeIntervalSince1970: event.timestampMs / 1000)
                if window.contains(date) {
                    output.append(APICostRecord(
                        id: identity, date: date, model: event.model, tokens: tokens, vendor: event.vendor))
                }
            }
        }
        return (output, incomplete || pending || !self.storageAvailable, self.archive.importedT3, retained, pending)
    }

    private func load(incomplete: inout Bool) {
        guard !self.loaded else { return }
        self.loaded = true
        guard FileManager.default.fileExists(atPath: self.archiveFile.path) else { return }
        do {
            self.archive = try autoreleasepool { try CodexHistoryArchive.read(self.archiveFile) }
        } catch {
            self.storageAvailable = false
            incomplete = true // Preserve a damaged archive rather than overwrite potentially recoverable history.
        }
    }

    private func importT3(incomplete: inout Bool) -> Bool {
        guard !self.archive.importedT3 else { return false }
        let file = self.t3Directory.appendingPathComponent("usage-scan-cache.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate else { incomplete = true; return false }
        let stamp = "\(size):\(modified.timeIntervalSince1970)"
        guard stamp != self.archive.t3Stamp else { return false }
        do {
            let imported = try autoreleasepool { try CodexHistoryArchive.read(file) }
            for (path, entry) in imported.files {
                let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                if let existing = self.archive.files[canonical], existing.mtimeMs > entry.mtimeMs { continue }
                self.archive.files[canonical] = entry
            }
            self.archive.importedT3 = true
            self.archive.t3Stamp = stamp
            return true
        } catch { incomplete = true; return false }
    }

    private func save(incomplete: inout Bool) {
        guard self.storageAvailable else { incomplete = true; return }
        do {
            try autoreleasepool { try self.archive.write(to: self.archiveFile) }
            self.savePending = false
        } catch {
            self.savePending = true
            incomplete = true
        }
    }

    private func files(authFile: String, incomplete: inout Bool) -> [ScanFile] {
        let manager = FileManager.default
        var nativeRoots = [
            self.home.appendingPathComponent(".codex"),
            Configuration.expand(authFile).deletingLastPathComponent(),
        ]
        nativeRoots += self.t3Homes(incomplete: &incomplete)
        for name in [".codex-t3", ".codex-gui"] {
            let parent = self.home.appendingPathComponent(name)
            guard manager.fileExists(atPath: parent.path) else { continue }
            do {
                nativeRoots += try manager.contentsOfDirectory(
                    at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            } catch { incomplete = true }
        }
        var agentRoots = [
            self.home.appendingPathComponent(".omp/agent"),
            self.home.appendingPathComponent(".pi/agent"),
            self.home.appendingPathComponent(".local/share/omp"),
        ]
        for name in [".omp", ".pi"] {
            let profiles = self.home.appendingPathComponent(name).appendingPathComponent("profiles")
            guard manager.fileExists(atPath: profiles.path) else { continue }
            do {
                let entries = try manager.contentsOfDirectory(
                    at: profiles, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                agentRoots += entries.map { $0.appendingPathComponent("agent") }
            } catch { incomplete = true }
        }
        var directories: [(url: URL, provider: String)] = []
        for (roots, provider) in [(nativeRoots, "codex"), (agentRoots, "omp")] {
            for root in roots {
                let names = provider == "codex" ? ["sessions", "archived_sessions"] : ["sessions"]
                for name in names {
                    let directory = root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
                    if manager.fileExists(atPath: directory.path) { directories.append((directory, provider)) }
                }
            }
        }
        var visited = Set<String>()
        var found: [String: (url: URL, provider: String)] = [:]
        // Keep following known sources even if a client's source setting is later removed.
        for (path, entry) in self.archive.files
            where (entry.provider == "codex" || entry.provider == "omp") && manager.fileExists(atPath: path)
        {
            found[path] = (URL(fileURLWithPath: path), entry.provider)
        }
        while let directory = directories.popLast() {
            if Task.isCancelled { incomplete = true; break }
            guard visited.insert(directory.url.path).inserted else { continue }
            do {
                let entries = try manager.contentsOfDirectory(
                    at: directory.url, includingPropertiesForKeys: [
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                    ],
                    options: [.skipsHiddenFiles])
                for entry in entries {
                    let values = try entry.resourceValues(forKeys: [
                        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    ])
                    if values.isSymbolicLink == true { continue }
                    if values.isDirectory == true {
                        directories.append((entry, directory.provider))
                    } else if values.isRegularFile == true, entry.pathExtension == "jsonl" {
                        let canonical = entry.resolvingSymlinksInPath().standardizedFileURL
                        found[canonical.path] = (canonical, directory.provider)
                    }
                }
            } catch { incomplete = true }
        }
        return found.values.compactMap { source -> ScanFile? in
            guard let values = try? source.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate
            else { incomplete = true; return nil }
            return ScanFile(url: source.url, provider: source.provider, size: size, modified: modified)
        }.sorted {
            // Current client activity should not wait behind a large native-history bootstrap.
            if ($0.provider == "omp") != ($1.provider == "omp") { return $0.provider == "omp" }
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.url.path < $1.url.path
        }
    }

    private func t3Homes(incomplete: inout Bool) -> [URL] {
        let file = self.t3Directory.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: 1_048_577), data.count <= 1_048_576,
                  let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                incomplete = true
                return []
            }
            var entries = ((settings["providerInstances"] as? [String: [String: Any]]) ?? [:]).values
                .filter { $0["driver"] as? String == "codex" }
            if let config = (settings["providers"] as? [String: Any])?["codex"] as? [String: Any] {
                entries.append(["config": config])
            }
            return entries.flatMap { entry -> [URL] in
                let config = entry["config"] as? [String: Any] ?? [:]
                let environment = entry["environment"] as? [String: String] ?? [:]
                let configured = (config["homePath"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let shadow = (config["shadowHomePath"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let candidates = [configured, shadow, environment["CODEX_HOME"] ?? ""]
                let paths = candidates.filter { !$0.isEmpty }.map { path -> URL in
                    if path.hasPrefix("~/") { return self.home.appendingPathComponent(String(path.dropFirst(2))) }
                    return URL(fileURLWithPath: path)
                }
                return paths.isEmpty ? [self.home.appendingPathComponent(".codex")] : paths
            }
        } catch { incomplete = true; return [] }
    }
}
