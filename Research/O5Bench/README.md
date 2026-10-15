# Removed-Pod experiment runner

This implementation follows the owner's updated **single-active-Pod** workflow:
physically remove the Pod, leave it active in Trio during the experiment, then
finish with normal deactivation/replacement. No second Pod, controller handoff,
"Previous Pod" connection, or reuse of a deactivated Pod is required.

**Current deliverable: offline runner and app preview. Physical access is disabled.**
In Omnipod 5 settings, open **Pod Experiment Dry Run**. All its actions use a fake
transport and a virtual clock. Opening it does not put the active Pod into a
physical bench mode. The existing pump-manager, activation, delivery and
replacement paths are unchanged.

## Why physical actions remain disabled

The revised lifecycle removes the earlier handoff blocker, but does not resolve
transport policy or exclude competing writers:

- At installed OmnipodKit `043b91d`, `BlePodMessageTransport.sendO5AidCommand`
  explicitly constructs an `ENCRYPTED` packet. It does not consult provisioned
  command/default policy or use the signing-key selection used by ordinary
  delivery commands. `O5RegistrationData` persists keys and certificates but
  does not expose a validated command-policy selection API. No installation's
  applicable policy was supplied or inspected in this implementation.
- The research establishes comma-separated application batches. This runner
  encodes the exact enable/identity batch and validates its two result members
  offline. The installed BLE AID API strips **one** response prefix; no complete
  multi-member physical exchange, policy selection and result integration has
  been demonstrated. The runner does not substitute two standalone SET calls.
- This fallback has no access to the live controller. Therefore no physical
  exclusive-writer mechanism is claimed. Connecting it to the active Pod still
  requires a persisted, target-bound bench lock at dispatch, including queued
  delivery/background commands, and exclusion of bench data from therapy stores.
  Merely disabling a screen or asking the operator to turn off looping is not
  that mechanism. Normal, explicitly targeted deactivation must remain available
  after evidence capture; the removed Pod must not resume ordinary dosing.

These are concrete missing integrations, not a requirement for a second
controller. The relevant existing paths are
[`BlePodComms.bleRunSession`](../../OmnipodKit/Bluetooth/BlePodComms.swift),
[`BleMessageTransport`](../../OmnipodKit/Bluetooth/BleMessageTransport.swift),
[`O5RegistrationData`](../../OmnipodKit/Bluetooth/Pair/O5RegistrationData.swift),
and [`OmniPumpManager`](../../OmnipodKit/PumpManager/OmniPumpManager.swift).

The same active `PodState` contains lot/sequence, BLE association, LTK and transport
state. Leaving the Pod active preserves that context. In contrast, normal
`deactivatePod` sends deactivation; `forgetPod` disconnects BLE and
`prepForNewPod` clears the active context and advances IDs. The Previous Pod UI
only displays historical details. None of those paths is modified here.

## Implemented behavior

Each UI button or CLI invocation performs one action. There is no product
run-all control. Baseline uses 10 simulated minutes, enable observation 15,
reception 30, and reconnect checks 10, with 60-second simulated read cadence.
These are experiment choices, not manufacturer timing guarantees.

| Action | Implemented offline behavior |
| --- | --- |
| Baseline and export | Full target match, capture, verified redacted baseline export, timed reads, firmware/BLE, age, nominal remaining service time, faults, reservoir/alerts, mode/readiness and sensor state |
| Reconnect | No programming; repeat baseline reads |
| Target / DIA | Recovered read-group order; all 48 values / raw half-hour count; no setup-complete state fabricated |
| Enable only | Exactly `SE4.2=` + `00 02 04 00`; DEFAULT 255 and recognized empty identity gate; canonical ACK, matching readback, Manual/nonfaulted observation required |
| Provision | Matching validated identity skips SET; different/incomplete/nonempty identity blocks; one two-member application batch, then separate recovered status group, then labeled diagnostic readback |
| Observe | Distinct sensor timestamps and freshness, raw special glucose values, raw algorithm/transmitter states, independent phone/watch observations |
| Reconnect after reception | No SET; check persisted configuration and new sensor timestamps |
| Alarm / export | Independent operator timestamp; redacted or private structured export, including failed/interrupted steps |

Fresh parsed status is required before every simulated mutation, with a 90-second
freshness limit checked again at dispatch. Firmware 9.0.4 / BLE 5.0.2 is the only
allowed simulated mutation branch. Control values other than enabled 0 and the
narrow DEFAULT 255 first-enable case are not silently treated as disabled.

The G7 command writes only four-byte code and twelve-byte serial. Values are
validated as fixed-length ASCII alphanumeric text, preserve leading zeroes and
compare case-insensitively. No desired-type key, timing, address or optional
identity field is added. Only synthetic identity is accepted by the CLI/UI.
The retained codec's stricter numeric-only comparison remains unchanged for its
original tests; the runner uses `BenchIdentity.matches` for its explicit policy.

The numeric reception criterion is deliberately limited: range 39…401, Pod-relative
age at most 360 seconds, at least two distinct sensor timestamps, the first new sample within six minutes, no stale/invalid
interval after it, and continued fresh reporting at the end.
It is **not** an official pairing-state decoder or a firmware acceptance claim.
Raw sensor algorithm/transmitter states and negative/special EGV values are kept
separately. A received history record or phone timestamp is never counted as a
new sensor sample. Page 7 remains an opaque synthetic fixture; its physical
legacy wrapper/message sequence and parser integration are not claimed here.

## Persistence and separation

`O5BenchCore` depends only on Foundation (and SwiftUI for its optional view).
It accepts no `OmniPumpManager`, BLE manager, HealthKit store or treatment store.
The concrete fake transport has no radio implementation. Its target includes
lot, sequence, BLE association and an opaque secure-context reference; no key or
credential is accepted or serialized. Both UI and CLI use this same runner.

A process lease and recursive in-process lock serialize actions. Session snapshots
are written via exclusive temporary file, fsync, atomic rename and directory
fsync. Files are mode 0600 and directories 0700; iOS adds complete file protection
and excludes research directories from backup. Save failure before dispatch
prevents send; failure after dispatch locks the chain.

Before a send, the journal saves operation/experiment/action IDs, complete target
reference, exact application requests, expected result, simulated signing policy
and timestamps. Send-start, transport completion, raw replies and validation are
separate milestones. The complete two-member application batch and its response
envelope are preserved. Raw bytes remain available after parser failures.

An interrupted action remains in the journal across reload. Diagnostics,
reconnect reads and export remain available, but a later matching readback does
not clear uncertainty or replay/advance a mutation. Restart tests inject failure
at preparation, send-start, transport-complete, reply-received, validation and
observation. A disk-backed reload test additionally verifies durable recovery.
The fake has zero lower-level retransmissions; no physical retransmission audit
is claimed.

Each event records UTC wall time, virtual monotonic time/clock ID and system
uptime. Virtual elapsed time is explicitly labeled in exports and the UI. Actual
hardware observation, clock continuity across device reboots, and background
execution on iOS have not been demonstrated.

## Exports and verification

Each export is a new directory containing `manifest.json`, `exchanges.ndjson`,
`events.ndjson` and `SHA256SUMS`. Private exports additionally contain the full
private session. Sharing exports omit **all** raw payload bytes, target/sensor
identifiers and free-text operator notes; safe decoded observations and result
milestones remain. Checksums cover exported bytes and are verified by rereading
them. They are integrity checks, not authentication or original-payload hashes.

[`Samples/redacted-session`](Samples/redacted-session) was generated by separate
CLI processes exercising the successful synthetic path and independent alarm
marking. It contains no real Pod or sensor data. Verify it independently:

```sh
python3 Scripts/verify-export.py Samples/redacted-session
python3 Scripts/stamp-sources.py --check
```

Build/test on a host with Swift 5.9 or later:

```sh
swift test
swift run o5-bench help
swift run o5-bench /tmp/experiment.private init
swift run o5-bench /tmp/experiment.private arm --confirm-off-body
swift run o5-bench /tmp/experiment.private baseline /tmp/new-baseline-export
```

Continue with one command at a time (`reconnect`, `enable`, `provision`, `observe`,
`reconnectReception`). `export <new-directory>` is redacted by default;
`--private` explicitly includes private requests/replies. Do not enter real
identifiers in this offline CLI. The smoke-test script is fixture-generation
infrastructure; it cannot select physical transport.

## Revisions, retained patch and validation limits

- Trio base: `0b29cd53415e7f0e668677749cad8daf81c68c2f`.
- Installed OmnipodKit base: `043b91dbf1958d26c55d927a6a8d651bc91f208d`.
- Research checkout: `db92e426b97914ce1c80bdab45a74001a858840a`.
- This working implementation is identified by the bundled
  [`source-checksums.json`](Sources/O5BenchCore/Resources/source-checksums.json),
  including app integration, package, implementation and test sources. Regenerate
  the stamp after edits and rebuild before exporting evidence.
- The retained validation patch targets a different OmnipodKit revision,
  `363f75ae02be15ff3f2ef2b5b0a1d7fbfeebb54e`; it was **not** applied wholesale to
  the current framework. Its response codec was verified against recorded
  SHA-256 and reused unchanged. Original command builders are test fixtures only,
  so their activation-style command cannot be selected by the runner. The
  associated setup/pairing integration changes were intentionally not installed.
  [`retained-validation-provenance.json`](retained-validation-provenance.json)
  records the original patch and source hashes.

**Final result: 60 tests passed, one optional private-log replay skipped, zero failures.**
The CLI smoke test completed across separate processes; independent verification
checked three export data files, 89 exchanges and 100 events. The edited Xcode
project parsed with Foundation and the SwiftUI source passed syntax parsing;
this is not iOS type checking.

See [`Validation/swift-tests.txt`](Validation/swift-tests.txt) and
[`Validation/cli-smoke.txt`](Validation/cli-smoke.txt). The private original-log
replay test is optional and is skipped unless `O5_INCIDENT_LOG` is supplied.
The new tests cover gates, exact serialization, member failures, missing/empty
results, stale/unknown state, identity comparison, every send milestone, durable
reload, logging loss, concurrency, negative glucose, interrupted reception,
independent operator observations and export redaction/checksums.

Linux tests compile the actual package/CLI and response codec. They do not
compile SwiftUI or link the iOS framework. This environment has no Xcode and most
Trio submodules are uninitialized. A full Xcode build and device UI validation
remain outstanding. No physical Pod, sensor, credentials or radio was used.

## Research references

All references below were read from the pinned local checkout because GitHub
was inaccessible from this environment:

- [Bench plan](https://github.com/manudrijvers/re-omnipod/blob/db92e426b97914ce1c80bdab45a74001a858840a/BENCH_EXPERIMENTS.md)
- [Keyed reply schemas](https://github.com/manudrijvers/re-omnipod/blob/db92e426b97914ce1c80bdab45a74001a858840a/analysis/cgm-provisioning/reply-parsers.md)
- [Enable and active-Pod batch](https://github.com/manudrijvers/re-omnipod/blob/db92e426b97914ce1c80bdab45a74001a858840a/analysis/cgm-provisioning/g7-enable-sequence.md)
- [Application batch framing](https://github.com/manudrijvers/re-omnipod/blob/db92e426b97914ce1c80bdab45a74001a858840a/analysis/mode-switch/android-crosscheck.md#the-batch-actually-sent)
- [Android signing selection](https://github.com/manudrijvers/re-omnipod/blob/db92e426b97914ce1c80bdab45a74001a858840a/analysis/cgm-provisioning/signing-policy.md)
- [iOS signing distinction](https://github.com/manudrijvers/re-omnipod/blob/db92e426b97914ce1c80bdab45a74001a858840a/analysis/cgm-provisioning/ios-signing-policy.md)
- [Readback contracts](https://github.com/manudrijvers/re-omnipod/blob/db92e426b97914ce1c80bdab45a74001a858840a/analysis/pod-fault-e2/configuration-readback.md)
- [Retained validation patch](https://github.com/manudrijvers/re-omnipod/blob/db92e426b97914ce1c80bdab45a74001a858840a/analysis/pod-fault-e2/incident-replay-and-validation.md)
