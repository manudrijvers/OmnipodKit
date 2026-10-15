import Foundation

/// One runner serializes all action/capture work. Physical access is intentionally
/// unavailable until batch framing and provisioned policy selection are reviewed.
final class BenchRunner {
    private(set) var session: BenchSession
    let store: BenchStore
    let transport: FakeBenchTransport
    let clock: BenchClock
    private let mutex = NSRecursiveLock()
    private var busy = false
    private var snapshot: BenchSnapshot?
    private var captureFailed = false
    /// Test-only process-termination injection: durable pending state is left intact.
    var checkpoint: ((String) throws -> Void)?

    init(store: BenchStore, transport: FakeBenchTransport, revisions: [String: String] = [:]) throws {
        self.store = store; self.transport = transport; clock = transport.clock
        if let saved = try store.load() {
            guard saved.schema == 1 else { throw BenchError.logging }
            session = saved; clock.elapsed = saved.virtualElapsed
            transport.control = saved.fakeControl; transport.identity = saved.fakeIdentity
            if saved.activeStep != nil || saved.operations.contains(where: { $0.outcome == "pending" }) {
                session.locks.append("interrupted-session; no automatic replay or advancement")
                for index in session.steps.indices where session.steps[index].finished == nil {
                    session.steps[index].result = "interrupted"
                }
                // Preserve the unfinished step and operation, including last milestones.
                try persist()
            }
        } else {
            session = BenchSession(id: UUID().uuidString, target: transport.target, revisions: revisions,
                activationProvenance: "synthetic fixture; no physical activation observed", clockID: clock.id)
            try persist()
        }
    }

    func requirePhysicalAccess() throws { throw BenchError.physicalDisabled }

    private func persist() throws {
        session.virtualElapsed = clock.elapsed
        session.fakeControl = transport.control; session.fakeIdentity = transport.identity
        do { try store.save(session) }
        catch {
            captureFailed = true
            if !session.locks.contains("logging-failure") { session.locks.append("logging-failure") }
            throw BenchError.logging
        }
    }

    private func event(_ kind: String, _ fields: [String: String] = [:]) throws {
        session.events.append(BenchEvent(time: clock.stamp, kind: kind, fields: fields)); try persist()
    }

    func arm(offBodyConfirmed: Bool) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !busy else { throw BenchError.busy }
        guard offBodyConfirmed, session.locks.isEmpty, !captureFailed else { throw BenchError.blocked }
        session.offBodyConfirmed = true; session.armed = true
        try event("armed", ["scope": "synthetic-only; Pod remains the sole active Pod until normal replacement"])
    }

    func recordFeed(phoneOK: Bool, watchOK: Bool, note: String = "") throws {
        mutex.lock(); defer { mutex.unlock() }
        session.phoneFeedOK = phoneOK; session.watchFeedOK = watchOK
        if !phoneOK || !watchOK { session.locks.append("operator-observed-phone-or-watch-feed-interruption") }
        try event("external-feed-observation", ["phoneOK": String(phoneOK), "watchOK": String(watchOK), "note": note])
    }

    func markAlarm(note: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        session.locks.append("operator-observed-alarm")
        try event("operator-audible-alarm", ["note": note, "softwareFaultDetection": "independent"])
    }

    func export(to url: URL, redacted: Bool = true) throws {
        mutex.lock(); defer { mutex.unlock() }
        // Export remains available even if the live journal becomes unwritable.
        try store.export(session, to: url, redacted: redacted)
    }

    func perform(_ action: BenchAction, identity: BenchIdentity? = nil, baselineExport: URL? = nil) throws {
        guard mutex.try() else { throw BenchError.busy }
        defer { mutex.unlock() }
        guard !busy else { throw BenchError.busy }
        busy = true; defer { busy = false }
        let step = BenchStep(id: UUID().uuidString, action: action, started: clock.stamp)
        let stepIndex = session.steps.count
        session.steps.append(step); session.activeStep = step.id
        try persist()
        do {
            switch action {
            case .baseline:
                guard let baselineExport else { throw BenchError.arguments }
                try checkTarget()
                session.baselineComplete = false; snapshot = nil
                _ = try readSnapshot()
                try export(to: baselineExport)
                try event("baseline-export-verified")
                _ = try observe(seconds: 600, requireEnable: false)
                session.baselineComplete = true
                if snapshot?.interface.control == 0 {
                    session.enableVerified = true
                    try event("enable-not-exercised", ["reason": "already enabled throughout baseline readback at completion"])
                }
            case .reconnect:
                try checkTarget(); transport.reconnect()
                try event("reconnect", ["programmingRequests": "0"])
                _ = try observe(seconds: 600, requireEnable: session.enableVerified)
                session.reconnectComplete = true
            case .diagnostic:
                _ = try readSnapshot()
            case .targetProfile:
                let bodies = try exchange([.get("3.1"), .get("3.12"), .page7], group: "recovered-target-read-group")
                let b = Array(bodies[0])
                guard b.count == 194, b[0] == 0, b[1] == 192 else { throw BenchError.reply }
                let values = stride(from: 2, to: 194, by: 4).map { i in
                    b[i..<i+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                }
                _ = try O5UnifiedAidStatus(bodies[1])
                try event("target-profile", ["valuesMgdl": values.map(String.init).joined(separator: ","),
                    "interpretation": "diagnostic reconstruction; no official setup-complete state is asserted"])
            case .dia:
                let bodies = try exchange([.get("3.9"), .get("3.12"), .page7], group: "recovered-dia-read-group")
                guard let text = String(data: bodies[0], encoding: .ascii),
                      !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                      let raw = UInt32(text), String(raw) == text else { throw BenchError.reply }
                _ = try O5UnifiedAidStatus(bodies[1])
                try event("dia", ["halfHourCount": text, "durationHours": String(Double(raw) / 2),
                    "interpretation": "diagnostic reconstruction; no setup-complete prerequisite fabricated"])
            case .enable:
                let current = try readSnapshot()
                try mutationGate()
                if current.interface.control == 0 {
                    session.enableVerified = true
                    try event("enable-not-exercised", ["reason": "already enabled"])
                } else {
                    guard current.interface.control == 255, current.identity.isEmpty else { throw BenchError.identity }
                    _ = try exchange([.enable], group: "enable-only", expected: "canonical success then control=0 and Manual/nonfaulted for 900s")
                    _ = try observe(seconds: 900, requireEnable: true)
                    session.enableVerified = true
                }
            case .provision:
                guard let identity else { throw BenchError.identity }
                let current = try readSnapshot()
                try mutationGate()
                guard session.enableVerified, current.interface.control == 0 else { throw BenchError.baseline }
                if identity.matches(current.identity) {
                    session.identity = identity; session.configurationConfirmed = true
                    try event("provision-not-exercised", ["reason": "matching validated identity; no SET; observation available"])
                } else {
                    guard current.identity.isEmpty else { throw BenchError.identity }
                    // One logical batch, with both application bodies preserved. No
                    // unsupported physical envelope or independent-send substitution.
                    session.identity = identity
                    _ = try exchange([.enable, .identity(identity)], group: "recovered-active-pod-g7-batch",
                        expected: "both canonical SET results; separate recovered status group; diagnostic identity readback")
                    let statusGroup = try exchange([.get("3.12"), .page7], group: "recovered-post-provision-status-group")
                    let status = try O5UnifiedAidStatus(statusGroup[0])
                    guard status.isManual, status.podActive else { throw BenchError.baseline }
                    let configured = try readSnapshot(group: "additional-bench-diagnostic-readback")
                    guard configured.interface.control == 0, identity.matches(configured.identity) else { throw BenchError.reply }
                    session.configurationConfirmed = true
                    try event("configuration-confirmed", ["pairing": "not established by SET acceptance"])
                }
            case .observe:
                guard session.configurationConfirmed else { throw BenchError.baseline }
                let observation = try observe(seconds: 1800, requireEnable: true)
                session.receptionObserved = observation.sustained
                try event("reception-result", ["distinctFreshSensorSamples": String(observation.count),
                    "sustainedWithinWindow": String(observation.sustained), "scope": "synthetic observation only"])
            case .reconnectReception:
                guard session.configurationConfirmed, session.receptionObserved else { throw BenchError.baseline }
                let previous = session.lastSensorTimestamp
                try checkTarget(); transport.reconnect()
                try event("reconnect-after-reception", ["programmingRequests": "0"])
                let count = try observe(seconds: 600, requireEnable: true)
                guard count.count >= 1, count.sustained, let latest = session.lastSensorTimestamp, latest != previous else { throw BenchError.reply }
                try event("fresh-glucose-resumed", ["configurationResent": "false"])
            }
            session.steps[stepIndex].result = "completed"
            session.steps[stepIndex].finished = clock.stamp
            session.activeStep = nil
            try persist()
        } catch {
            // Leave the interrupted step pending for a simulated process death.
            if error as? BenchError == .interrupted { throw error }
            session.events.append(BenchEvent(time: clock.stamp, kind: "action-validation-error",
                fields: ["action": action.rawValue, "reason": error.localizedDescription]))
            session.steps[stepIndex].result = "failed"
            session.steps[stepIndex].finished = clock.stamp
            session.activeStep = nil
            session.locks.append("action-failed-\(action.rawValue)")
            try? persist()
            throw error
        }
    }

    private func checkTarget() throws {
        guard transport.target == session.target else { throw BenchError.target }
    }

    private func mutationGate() throws {
        try checkTarget()
        guard !captureFailed, session.locks.isEmpty, session.offBodyConfirmed, session.armed,
              session.phoneFeedOK, session.watchFeedOK else { throw BenchError.blocked }
        guard session.baselineComplete, session.reconnectComplete,
              transport.firmware == "9.0.4", transport.bleVersion == "5.0.2",
              let snapshot, clock.elapsed >= snapshot.received, clock.elapsed - snapshot.received <= 90,
              snapshot.status.isManual, snapshot.status.podActive, snapshot.legacy.active,
              let desired = snapshot.interface.desiredSensorType,
              let allowed = snapshot.interface.allowedSensorType,
              [0, 1, 4, 5, 7, 8, 9].contains(desired), [0, 1, 4, 5, 7, 8, 9].contains(allowed),
              snapshot.interface.managerVersion != nil,
              snapshot.legacy.fault == 0, snapshot.legacy.reservoirPulses > 0 else { throw BenchError.baseline }
        guard !session.operations.contains(where: { $0.requests.contains(where: \.isMutation) && $0.outcome == "pending" }) else {
            throw BenchError.blocked
        }
    }

    /// Gate immediately before fake dispatch as well as at the action boundary.
    /// Read-only diagnostics are available with pending/uncertain mutations.
    private func exchange(_ requests: [BenchRequest], group: String, expected: String = "strict parsed replies") throws -> [Data] {
        let mutation = requests.contains(where: \.isMutation)
        try checkTarget()
        if mutation { try mutationGate() }
        let op = BenchOperation(id: UUID().uuidString, experimentID: session.id,
            actionID: session.activeStep ?? "diagnostic", target: session.target, requests: requests,
            group: group, applicationBatch: mutation && requests.count == 2 ? try BenchBatchCodec.request(requests) : nil,
            expected: expected, signingPolicy: "simulation-only; physical policy unresolved", prepared: clock.stamp)
        session.operations.append(op); let i = session.operations.count - 1
        try persist(); try checkpoint?("prepared")
        try checkTarget()
        // Recheck freshness/arming without counting the newly prepared operation
        // as an earlier uncertain mutation.
        if mutation {
            guard !captureFailed, session.locks.isEmpty, session.armed, session.offBodyConfirmed,
                  let snapshot, clock.elapsed - snapshot.received <= 90,
                  clock.elapsed >= snapshot.received else { throw BenchError.blocked }
        }
        session.operations[i].sendStarted = clock.stamp
        try persist(); try checkpoint?("send-start")
        // Last boundary check after all durable pre-send milestones.
        try checkTarget()
        if mutation {
            guard !captureFailed, session.locks.isEmpty, session.armed, session.offBodyConfirmed,
                  session.phoneFeedOK, session.watchFeedOK, let snapshot,
                  clock.elapsed >= snapshot.received, clock.elapsed - snapshot.received <= 90 else { throw BenchError.blocked }
        }
        let replies: [Data]
        do { replies = try transport.exchange(requests) }
        catch {
            session.locks.append(mutation ? "mutation-outcome-unknown" : "diagnostic-interrupted")
            try? persist()
            throw BenchError.interrupted
        }
        session.operations[i].transportCompleted = clock.stamp
        try persist(); try checkpoint?("transport-complete")
        session.operations[i].replies = replies; session.operations[i].repliesReceived = clock.stamp
        try persist(); try checkpoint?("reply-received")
        let memberReplies: [Data]
        if op.applicationBatch != nil {
            guard replies.count == 1 else { throw BenchError.reply }
            memberReplies = try BenchBatchCodec.replies(replies[0])
        } else { memberReplies = replies }
        guard memberReplies.count == requests.count else { throw BenchError.reply }
        var bodies: [Data] = []; var invalid = false
        for (index, request) in requests.enumerated() {
            do {
                let reply = memberReplies[index], prefix = Data(request.responsePrefix.utf8)
                guard reply.starts(with: prefix) else { throw BenchError.reply }
                let body = Data(reply.dropFirst(prefix.count)); bodies.append(body)
                if request.isMutation {
                    try O5AidResponseValidation.extendedSet(body, command: request.responsePrefix)
                }
                session.operations[i].memberResults.append(request.isMutation ? "canonical-success" : "framed; semantic validation follows")
            } catch {
                invalid = true
                session.operations[i].memberResults.append("rejected-or-malformed")
            }
        }
        session.operations[i].outcome = invalid ? "rejected-or-malformed; mutation chain stopped" : "application-replies-received"
        try persist()
        if invalid { throw BenchError.reply }
        if mutation {
            session.operations[i].validated = clock.stamp
            session.operations[i].outcome = "accepted; configuration and reception not yet confirmed"
            try persist(); try checkpoint?("validated")
        }
        return bodies
    }

    @discardableResult
    private func readSnapshot(group: String = "bench-baseline-reads") throws -> BenchSnapshot {
        // Invalidate before every attempt so malformed replies never leave an
        // earlier successful state available for a mutation decision.
        snapshot = nil
        let data = try exchange([.get("4.2"), .get("4.1"), .get("3.12"), .legacy], group: group)
        let value = try BenchSnapshot(interface: O5CgmInterfaceStatus(data[0]), identity: O5G7SensorInfo(data[1]),
            status: O5UnifiedAidStatus(data[2]), legacy: BenchLegacyStatus(data[3]), received: clock.elapsed)
        try event("status", ["firmware": transport.firmware, "bleVersion": transport.bleVersion,
            "podAgeMinutes": String(value.legacy.ageMinutes),
            "nominalRemainingServiceMinutes": String(80 * 60 - value.legacy.ageMinutes),
            "reservoirPulses": String(value.legacy.reservoirPulses), "alerts": String(value.legacy.alerts),
            "fault": String(value.legacy.fault), "loopState": String(value.status.loopState),
            "ready": String(value.status.algorithmReady), "active": String(value.status.podActive),
            "control": value.interface.control.map(String.init) ?? "absent",
            "desiredType": value.interface.desiredSensorType.map(String.init) ?? "absent",
            "allowedType": value.interface.allowedSensorType.map(String.init) ?? "absent",
            "managerVersion": value.interface.managerVersion.map(String.init) ?? "absent",
            "identityShape": value.identity.isEmpty ? "empty-unconfigured-shape-observed" : "keyed",
            "driverVersion": value.identity.driverVersion.map(String.init) ?? "absent",
            "egvRaw": String(value.status.egvRaw),
            "egvClassification": value.status.hasRecentG7Reading(maxAge: 360) ? "fresh-numeric" : "special-absent-invalid-or-stale",
            "validityScope": "numeric range and age checks; raw algorithm/transmitter states retained separately",
            "podTimestamp": String(value.status.podTime), "referenceTime": String(value.status.referenceTime),
            "sensorTimestamp": value.status.g7.map { String($0.sensorTimestamp) } ?? "absent",
            "algorithmState": value.status.g7.map { String($0.algorithmState) } ?? "absent",
            "transmitterStatus": value.status.g7.map { String($0.transmitterStatus) } ?? "absent",
            "pairing": "raw states retained; not inferred from an ACK"])
        guard value.status.isManual, value.status.podActive, value.legacy.active, value.legacy.fault == 0 else {
            session.locks.append("fault-inactive-or-unexpected-mode"); try persist(); throw BenchError.baseline
        }
        snapshot = value
        if value.status.hasRecentG7Reading(maxAge: 360), let sensor = value.status.g7, sensor.sensorTimestamp >= 0 {
            session.lastSensorTimestamp = sensor.sensorTimestamp
        }
        // Record semantic validation separately from frame parsing.
        if let i = session.operations.indices.last {
            session.operations[i].validated = clock.stamp; session.operations[i].outcome = "parsed"
            try persist()
        }
        return value
    }

    private func observe(seconds: Double, requireEnable: Bool) throws -> (count: Int, sustained: Bool) {
        let start = clock.elapsed
        let previousSample = session.lastSensorTimestamp
        var distinct = Set<Int32>()
        var lastNewSampleAt: Double?
        var firstNewSampleAt: Double?
        var continuity = true
        var freshAtEnd = false
        repeat {
            let value = try readSnapshot()
            if requireEnable, value.interface.control != 0 { throw BenchError.reply }
            if let expected = session.identity, !expected.matches(value.identity) { throw BenchError.identity }
            if value.status.hasRecentG7Reading(maxAge: 360), let g7 = value.status.g7,
               g7.sensorTimestamp >= 0, g7.sensorTimestamp != previousSample {
                if distinct.insert(g7.sensorTimestamp).inserted {
                    if firstNewSampleAt == nil { firstNewSampleAt = clock.elapsed }
                    if let last = lastNewSampleAt, clock.elapsed - last > 360 { continuity = false }
                    lastNewSampleAt = clock.elapsed
                }
                session.lastSensorTimestamp = g7.sensorTimestamp
            }
            freshAtEnd = value.status.hasRecentG7Reading(maxAge: 360)
            if lastNewSampleAt != nil && !freshAtEnd { continuity = false }
            guard session.phoneFeedOK, session.watchFeedOK else { throw BenchError.blocked }
            try checkpoint?("observation-sample")
            if clock.elapsed - start >= seconds { break }
            clock.advance(60) // Explicit simulated cadence; no tight physical polling.
        } while true
        try event("observation-window", ["plannedSeconds": String(seconds), "elapsedSeconds": String(clock.elapsed - start),
            "cadenceSeconds": "60", "clock": "virtual", "distinctFreshSensorSamples": String(distinct.count)])
        let sustained = distinct.count >= 2 && continuity && freshAtEnd
            && lastNewSampleAt.map { clock.elapsed - $0 <= 360 } == true
            && firstNewSampleAt.map { $0 - start <= 360 } == true
        return (distinct.count, sustained)
    }
}
