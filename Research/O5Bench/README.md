# Removed-Pod experiment runner

The physical path uses the owner's single-active-Pod workflow: physically remove
this Pod, leave it active in Trio, run separate experiment actions, then deactivate
and replace it normally. It uses the existing controller identity, LTK, BLE
association and sequence state. There is no second active Pod or controller handoff.

**Implementation status:** a real BLE adapter and screen are implemented. The
portable tests and iOS-source syntax checks run on Linux. Full simulator builds
run in Trio's `O5 experiment simulator build` GitHub Actions workflow; check the
result for the exact source revision. Physical Pod acceptance has not been tested.

## In the app

Open Omnipod 5 settings → **Removed Pod Experiment**. Confirm that the Pod has
been removed and no longer supplies therapy, then start the session. Starting
requires Trio automatic dosing to be off and automatically opens protected local
capture. Leave automatic dosing off until this Pod is replaced; the experiment
checks the setting again before its commands. Starting does not suspend or change
the existing delivery program. Only automatic status polling, post-connect status
processing, timed silence restoration and pending alert acknowledgments pause.
Manual commands and the ordinary send paths remain available.

Run the buttons separately, reviewing each result:

1. Capture baseline: ten real minutes, with an initial verified export.
2. Reconnect and repeat baseline: ten minutes, without configuration writes.
3. Enable only: control key 4 only; observe for fifteen minutes.
4. Enter the actual four-character G7 code and twelve-character serial, preserving
   leading zeroes, then provision G7.
5. Observe reception for thirty minutes; reconnect and observe again if successful.
6. Export the session, then leave the screen and deactivate/replace normally.

Keep the app and experiment screen foregrounded. The screen prevents idle sleep.
Leaving the foreground, stopping, an alarm, a feed interruption, faults, malformed
replies, missing capture or an uncertain command stops the mutation chain. Reopened
physical sessions permit diagnostics and export only; they never replay a SET.
The background-maintenance pause ends when the experiment is stopped, leaves the
foreground, closes, or its connection is released. It is in memory only: an app
restart resumes normal background processing. A stable journal identity preserves
interrupted-session history for that Pod; reopening cannot silently erase its
uncertainty. Diagnostic readback reacquires the pause and checks automatic dosing.

Logging needs no special setting. **Export redacted session** omits raw bytes,
Pod/sensor identifiers, the certificate fingerprint and operator notes. **Export
private raw capture** preserves exact application bytes, including parse failures
and replies received before an ACK failure. It contains identifiers, but neither
export contains signing keys, session keys or credentials. Operator alarm time is
recorded separately from software fault detection. Phone/watch observations are
operator reports; the runner does not infer that those feeds are healthy.

**Pod Experiment Dry Run** and the CLI remain explicitly simulated alternatives.
They use virtual time and synthetic identities; their exports say so.

## Transport and isolation

`BlePodComms.makePhysicalBenchConnection` uses the same BLE connection and serialized
session queue as ordinary commands. Earlier sessions finish before preparation.
The adapter binds lot, sequence, BLE identifier and a one-way context reference
incorporating controller, Pod address, LTK and the active signing key. It rechecks
that context at the experiment send boundary.

There is no persistent command lock and no deactivation/discard exception. Normal
legacy, raw and AID send implementations are restored to the pre-live-experiment
version (`9c5950a`). Dedicated experiment methods handle signing and durable capture.
The pump manager has a process-local, token-owned maintenance pause; queued status
and alert work rechecks it before running. The automatic-dosing guard only rejects
experiment operations; it does not modify Trio's setting or intercept therapy commands.

Old interlock files are consulted only when opening an experiment, to locate its
existing journal. They have no effect on ordinary commands. Journal snapshots and
mutation uncertainty remain durable and private; this is separate from pausing
background maintenance.

Experiment reads use the existing transport directly. Only secure sequence/nonce
state is returned through the transport delegate. Experimental glucose, status and
history are not submitted to the pump's treatment-state update methods or HealthKit.

The runner requires fresh, parsed Manual/active/nonfaulted status, firmware 9.0.4 /
BLE 5.0.2, successful baseline/reconnect and an armed off-body session before writes.
The first enable mutation accepts only the reviewed DEFAULT 255 + empty identity
branch. An already-enabled baseline skips enablement and labels it unexercised.
Matching identity skips provisioning; different or incomplete identity blocks it.

Provisioning sends **one** comma-separated application batch containing control-only
`SE4.2` then `SE4.1`, validates both results, and sends the separate `G3.12` + wrapped
legacy page-7 read batch. Binary replies are split using lengths. Additional
`4.2`/`4.1` readback is labeled diagnostic. No desired-type key or activation setup
write is added. The previous unguarded “Connect Dexcom G7” mutation entry point
now directs the operator to this runner.

The physical UI omits optional target/DIA groups; these remain dry-run fixtures.
Observation uses real process uptime and a sixty-second cadence. Reception is a
limited numeric/freshness test, not a manufacturer pairing declaration: distinct
sensor timestamps, range 39–401, age at most 360 seconds, no stale interval after
first reception, and fresh reporting at the end. Raw special values and sensor
states are retained independently.

## Signing selection and remaining hardware uncertainty

Before opening the journal, the adapter loads its controller registration, verifies
that its signing key matches the active Pod context, and extracts the certificate's
`commands:` policy from structurally parsed DER extension URI/IA5 fields. This is
policy extraction from an already-provisioned registration, not certificate trust
validation. Missing, ambiguous, malformed or unsupported policies fail before any
experiment command is sent. No certificate from the user's installed phone was
available for validation here.

The chosen policy is the traced **iOS signing ID 0 registration default**. Mode 1
uses encryption; mode 4 uses the existing secondary P-256 signing key over the
same encrypted header/payload construction as Trio's signed commands. Primary-key
mode is unsupported and blocked. There is no unsigned-first or signed-on-rejection
retry. The selected mode and certificate fingerprint are recorded privately;
standalone legacy status reads retain Trio's existing mode 1. This is an explicit
Trio policy choice based on the iOS trace, not a claim that Android batch ID 65536
has the same policy or that Pod acceptance has been established.

References in `manudrijvers/re-omnipod`:

- `analysis/cgm-provisioning/ios-signing-policy.md`
- `analysis/cgm-provisioning/signing-policy.md`
- `analysis/cgm-provisioning/g7-enable-sequence.md`
- `analysis/cgm-provisioning/reply-parsers.md`
- `analysis/mode-switch/android-crosscheck.md` (legacy status batch wrapper)

## Validation and provenance

`swift test` covers strict parsing, action gates, uncertainty, durable storage,
redaction, signing-policy extraction, binary read batches, target checks and
background-pause lifecycle and journal continuity. Physical branches use a deterministic radio double in tests;
none of those results are physical Pod evidence. The optional private incident
replay is skipped unless `O5_INCIDENT_LOG` is supplied.

`Validation/physical-runner-tests.log` records current portable tests.
`Validation/physical-integration-checks.txt` records the iOS syntax check and its
limits. Earlier logs and `retained-validation-provenance.json` remain historical
records of the offline implementation and original retained parser patch.
`Samples/redacted-session` is an explicitly synthetic export.

Run `Scripts/stamp-sources.py --check` to verify the bundled source provenance and
`Scripts/verify-export.py <export-directory>` to independently check exports.
Snapshots use fsync + atomic rename, 0600 files/0700 directories and a process
lease. Send preparation, send-start, transport write ACK, raw reply and application
validation are separate milestones. The current BLE packet sender has no command
retransmission loop; reconnect handshakes do not replay an application SET.
