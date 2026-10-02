import Foundation
import PaceBarCore

extension UsageStore {
    static func hostKey(_ id: UUID, hardware: Bool) -> String {
        "\(id.uuidString):\(hardware ? "hardware" : "inference")"
    }

    /// Failed inference with live host metrics means the machine is up and only its server is down.
    func inferenceDownLabel(_ id: UUID) -> String {
        self.hostReadings[id]?.hardware != nil && self.errors[Self.hostKey(id, hardware: true)] == nil
            ? "Server down" : "Unreachable"
    }

    func scheduleHost(
        _ host: InferenceHost, hardware: Bool, interval: TimeInterval, retryInterval: TimeInterval, force: Bool)
    {
        let key = Self.hostKey(host.id, hardware: hardware)
        guard self.tasks[key] == nil else { return }
        // At most four host component requests in flight; the coalesced timer drains the rest.
        guard self.tasks.keys.filter({ $0.contains(":") }).count < 4 else { return }
        // Live sampling is for small HTTP reads only: a failing component and the SSH collector keep the
        // background cadence, so an outage or a process launch never repeats every few seconds.
        let sshCollector = hardware && (host.metricsURL ?? "").isEmpty
        let interval = self.errors[key] != nil || sshCollector ? max(interval, retryInterval) : interval
        if !force, !Self.due(self.attempted[key], interval: interval) { return }
        // A paused server said when to come back; check every few minutes in case it resumes early.
        if !force, !hardware, let until = self.hostReadings[host.id]?.pause?.until, Date() < until,
           let last = self.attempted[key], Date().timeIntervalSince(last) < 300 { return }
        self.attempted[key] = Date()
        // Persist history at most every half minute; live samples between saves only preview the totals.
        let persist = self.lastPersisted[key].map { Date().timeIntervalSince($0) >= 30 } ?? true
        self.refreshing.insert(key)
        let revision = self.revisions[key, default: 0]
        let hostRevision = self.hostRequests.revision(for: host.id)
        self.tasks[key] = Task { [weak self] in
            guard let self else { return }
            @MainActor func current() -> Bool {
                revision == self.revisions[key, default: 0] && !Task.isCancelled
                    && self.hostRequests.accepts(host.id, revision: hostRevision)
            }
            defer {
                if current() {
                    self.tasks.removeValue(forKey: key)
                    self.refreshing.remove(key)
                    self.refresh()
                }
            }
            do {
                if hardware {
                    let value = try await self.services.host(host)
                    guard current() else { return }
                    let (energy, saved) = await self.nousHistory.recordEnergy(
                        value, origin: host.serverURL, persist: persist)
                    guard current() else { return }
                    var reading = self.hostReadings[host.id] ?? HostReading()
                    reading.record(hardware: value)
                    reading.energy = energy
                    self.hostReadings[host.id] = reading
                    self.errors[key + ":history"] = saved ? nil : "Could not save GPU energy history."
                    if persist, saved { self.lastPersisted[key] = Date() }
                } else {
                    if self.hostReadings[host.id]?.lifetime == nil {
                        let (stored, loaded) = await self.nousHistory.snapshot(origin: host.serverURL)
                        guard current() else { return }
                        self.hostReadings[host.id, default: HostReading()].lifetime = stored
                        self.errors[key + ":history"] = loaded ? nil : "Could not load token history."
                    }
                    let value = try await self.services.nous(host)
                    guard current() else { return }
                    let (totals, saved) = await self.nousHistory.record(value, origin: host.serverURL, persist: persist)
                    guard current() else { return }
                    self.hostReadings[host.id, default: HostReading()].nous = value
                    self.hostReadings[host.id, default: HostReading()].pause = nil
                    self.hostReadings[host.id, default: HostReading()].lifetime = totals
                    self.errors[key + ":history"] = saved ? nil : "Could not save token history."
                    if persist, saved { self.lastPersisted[key] = Date() }
                }
                self.updated[key] = Date()
                self.errors[key] = nil
                self.diagnosedOutages.remove(key)
            } catch let UsageError.unavailable(until, reason) where !hardware {
                // An intentional pause is not an outage: no warning and no SSH diagnosis.
                guard current() else { return }
                self.hostReadings[host.id, default: HostReading()].inferencePaused(until: until, reason: reason)
                self.errors[key] = nil
                self.diagnosedOutages.remove(key)
            } catch {
                guard current() else { return }
                if !hardware { self.hostReadings[host.id, default: HostReading()].inferenceFailed() }
                // Diagnose once per outage over SSH; later failed polls keep that explanation.
                if !hardware, self.diagnosedOutages.contains(key) { return }
                self.errors[key] = error is UsageError ? error.localizedDescription : "Connection unavailable."
                if !hardware {
                    self.diagnosedOutages.insert(key)
                    let detail = await HostDoctor().diagnoseInferenceFailure(host)
                    guard current() else { return }
                    self.errors[key] = detail
                }
            }
        }
    }
}
