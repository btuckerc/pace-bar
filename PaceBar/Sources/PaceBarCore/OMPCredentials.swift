import Foundation
import SQLite3

/// OMP's local credential store, read only. OMP refreshes these sign-ins during normal use; Pace Bar only borrows
/// an access token for its read-only usage requests and never refreshes, copies, or writes a credential.
public enum OMPCredentials {
    public static var database: URL {
        Configuration.expand("~/.omp/agent/agent.db")
    }

    struct Row {
        let id: Int64
        /// `nil` when the stored value is empty or oversized.
        let data: Data?
        let identityKey: String?
    }

    /// Enabled OAuth rows for one OMP provider, in sign-in order. A missing database has no rows.
    static func rows(provider: String, database: URL) throws -> [Row] {
        if AccountDiscovery.isAbsent(database) { return [] }
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw UsageError.message("OMP sign-ins are unreadable.")
        }
        sqlite3_busy_timeout(handle, 1000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let hasIdentityKey = sqlite3_table_column_metadata(
            handle, nil, "auth_credentials", "identity_key", nil, nil, nil, nil, nil) == SQLITE_OK
        let query = """
        SELECT id, data, \(hasIdentityKey ? "identity_key" : "NULL") FROM auth_credentials
        WHERE provider = ?1 AND credential_type = 'oauth' AND disabled_cause IS NULL
        ORDER BY id
        """
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK,
              sqlite3_bind_text(statement, 1, provider, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
              == SQLITE_OK
        else { throw UsageError.message("OMP sign-ins are unreadable.") }
        var rows: [Row] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            defer { status = sqlite3_step(statement) }
            let bytes = sqlite3_column_bytes(statement, 1)
            let data: Data? = if bytes > 0, bytes <= 1_048_576, let blob = sqlite3_column_blob(statement, 1) {
                Data(bytes: blob, count: Int(bytes))
            } else {
                nil
            }
            rows.append(Row(
                id: sqlite3_column_int64(statement, 0),
                data: data,
                identityKey: sqlite3_column_text(statement, 2).map { String(cString: $0) }))
        }
        guard status == SQLITE_DONE else { throw UsageError.message("OMP sign-ins are unreadable.") }
        return rows
    }
}
