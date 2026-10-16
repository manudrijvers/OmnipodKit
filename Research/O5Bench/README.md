# Removed-Pod experiment runner

The physical path uses the owner's single-active-Pod workflow: physically remove
this Pod, leave it active in Trio, run separate experiment actions, then deactivate
and replace it normally. It uses the existing controller identity, LTK, BLE
association and sequence state. There is no second active Pod or controller handoff.

**Implementation status:** a real BLE adapter and screen are implemented. The
portable tests and iOS-source syntax checks run on Linux; a full Xcode build and
physical Pod acceptance have not been performed. This is experimental source,
not a verified installable iOS build.

## In the app

Open Omnipod 5 settings → **Removed Pod Experiment**. Confirm that the Pod has
been removed and no longer supplies therapy, then start the session. Starting
reserves the existing active Pod and automatically opens protected local capture.
It does not suspend or change its existing delivery program. Ordinary app
commands are blocked while this Pod is reserved, including background commands.

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
The isolation lock persists until normal discard/replacement. A new session cannot
silently erase the old session or its uncertainty.

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

`BlePodComms.makePhysicalBenchConnection` acquires a durable interlock on the
serialized Pod session queue after earlier commands finish. Its permit binds lot,
sequence, BLE identifier and a one-way context reference incorporating controller,
Pod address, LTK and the active signing key. It rechecks the active context at the
application send boundary. Ordinary legacy, raw and AID transport entry points
check the lock too, including already-queued sessions.

The normal deactivation path has a narrow exception for status, cancellation and
deactivation commands. There is no resume-to-therapy button for the removed Pod.
Normal discard clears the interlock; the session files remain. An unreadable or
corrupt interlock blocks ordinary commands. Interlock metadata remains readable
after first unlock; private research journals use complete file protection.

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

Before reserving the Pod, the adapter loads its controller registration, verifies
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
persistent isolation. Physical branches use a deterministic radio double in tests;
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
