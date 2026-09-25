import Darwin
import Foundation

/// One-time copy of Usage Bar's settings, history, and caches into Pace Bar's locations.
/// Each tree is copied to a private staging sibling, verified, and published without replacing anything.
/// An existing destination wins wholesale. The legacy directories stay as backups and are never deleted.
public enum IdentityMigration {
    static let pairs = [
        (legacy: ".config/usage-bar", current: ".config/pace-bar"),
        (legacy: ".local/share/usage-bar", current: ".local/share/pace-bar"),
        (legacy: "Library/Caches/usage-bar", current: "Library/Caches/pace-bar"),
    ]
    static let receiptPath = ".config/pace-bar/.identity-migration-v1.json"
    static let archiveName = "codex-cost-history.json"
    static let rootKeys = ["usageBarImportedT3": "paceBarImportedT3", "usageBarT3Stamp": "paceBarT3Stamp"]
    static let entryKeys = [
        "usageBarIncomplete": "paceBarIncomplete",
        "usageBarPendingScan": "paceBarPendingScan",
        "usageBarScanVersion": "paceBarScanVersion",
    ]

    /// Whether a legacy tree exists and no receipt records a completed migration.
    public static func pending(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: home.appendingPathComponent(self.receiptPath).path) else { return false }
        return self.pairs.contains { manager.fileExists(atPath: home.appendingPathComponent($0.legacy).path) }
    }

    public static func run(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard self.pending(home: home) else { return }
        for pair in self.pairs {
            try self.migrate(
                from: home.appendingPathComponent(pair.legacy),
                to: home.appendingPathComponent(pair.current))
        }
        let receipt = home.appendingPathComponent(self.receiptPath)
        try FileManager.default.createDirectory(
            at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let body = try JSONSerialization.data(withJSONObject: [
            "version": 1, "migrated": ISO8601DateFormatter().string(from: Date()),
        ])
        try body.write(to: receipt, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
    }

    private static func migrate(from legacy: URL, to current: URL) throws {
        let manager = FileManager.default
        guard self.exists(legacy), !self.exists(current) else { return }
        let values = try legacy.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw UsageError.message("\(legacy.path) is not a directory.")
        }
        // A leftover staging tree is from an interrupted launch and was never published.
        let staging = current.deletingLastPathComponent()
            .appendingPathComponent(".\(current.lastPathComponent).migrating")
        if self.exists(staging) { try manager.removeItem(at: staging) }
        try manager.copyItem(at: legacy, to: staging)
        do {
            try self.verify(staging, matches: legacy)
            let archive = staging.appendingPathComponent(self.archiveName)
            if manager.fileExists(atPath: archive.path) { try self.renameArchiveKeys(archive) }
            guard renamex_np(staging.path, current.path, UInt32(RENAME_EXCL)) == 0 else {
                let code = errno
                // Something created the destination meanwhile; it wins.
                guard code == EEXIST else {
                    throw UsageError.message("Could not publish \(current.path): \(String(cString: strerror(code)))")
                }
                try manager.removeItem(at: staging)
                return
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Relative paths of every entry, failing on anything that is not a plain file or directory.
    private static func entries(_ root: URL) throws -> [String: Bool] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            throw UsageError.message("Could not read \(root.path).")
        }
        let prefix = root.resolvingSymlinksInPath().path + "/"
        var result: [String: Bool] = [:]
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            let path = url.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
            if values.isSymbolicLink == true || (values.isRegularFile != true && values.isDirectory != true) {
                throw UsageError.message("Unsupported entry \(url.path); move it aside and relaunch.")
            }
            result[relative] = values.isDirectory == true
        }
        return result
    }

    private static func verify(_ copy: URL, matches source: URL) throws {
        let expected = try self.entries(source)
        guard try self.entries(copy) == expected else {
            throw UsageError.message("Copy of \(source.path) is incomplete.")
        }
        for (relative, isDirectory) in expected where !isDirectory {
            let original = try Data(contentsOf: source.appendingPathComponent(relative), options: .alwaysMapped)
            let copied = try Data(contentsOf: copy.appendingPathComponent(relative), options: .alwaysMapped)
            guard original == copied else { throw UsageError.message("Copy of \(relative) differs.") }
        }
    }

    /// Renames the archive's provenance keys structurally; an existing new-name key is a conflict.
    private static func renameArchiveKeys(_ file: URL) throws {
        guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw UsageError.message("\(self.archiveName) is not a JSON object.")
        }
        root = try self.rename(root, keys: self.rootKeys)
        if let files = root["files"] as? [String: Any] {
            var renamed: [String: Any] = [:]
            for (path, value) in files {
                guard let entry = value as? [String: Any] else {
                    throw UsageError.message("\(self.archiveName) has an invalid file entry.")
                }
                renamed[path] = try self.rename(entry, keys: self.entryKeys)
            }
            root["files"] = renamed
        }
        let data = try JSONSerialization.data(withJSONObject: root)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func rename(_ object: [String: Any], keys: [String: String]) throws -> [String: Any] {
        var result = object
        for (old, new) in keys {
            guard let value = result.removeValue(forKey: old) else { continue }
            guard result[new] == nil
            else { throw UsageError.message("\(self.archiveName) has both \(old) and \(new).") }
            result[new] = value
        }
        return result
    }
}
