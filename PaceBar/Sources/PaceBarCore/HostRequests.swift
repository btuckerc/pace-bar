import Foundation

/// A host revision survives removal so an old request cannot match a re-added entry.
public struct HostRequests: Sendable {
    private var hosts: [UUID: InferenceHost] = [:]
    private var revisions: [UUID: UInt64] = [:]

    public init() {}

    public mutating func reconcile(_ hosts: [InferenceHost]) {
        let next = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        for id in Set(self.hosts.keys).union(next.keys) where self.hosts[id] != next[id] {
            self.revisions[id, default: 0] += 1
        }
        self.hosts = next
    }

    public func revision(for id: UUID) -> UInt64 { self.revisions[id, default: 0] }

    public func accepts(_ id: UUID, revision: UInt64) -> Bool {
        self.hosts[id]?.enabled == true && self.revisions[id, default: 0] == revision
    }
}
