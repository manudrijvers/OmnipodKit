# Optional control enable during fresh activation

This implements the early control-only experiment for firmware 9.0.4 / BLE 5.0.2.
It is experimental: no fresh-Pod hardware result establishes that it avoids E2.

On the **Pair Pod** screen, before pairing a new O5 Pod, select
**Experimental: enable control during activation**. The default is off. A selection
is captured in the newly created PodState and consumed for that Pod. Updating the
app or opening setup for an existing Pod does not arm it.

Normal Trio common AID setup, basal programming, alerts and cannula insertion run
with their existing values and commands. At the shared insertion-completion point
(including recovery), an armed Pod runs these exchanges on the same serialized
PodCommsSession, before setup is marked completed:

1. G3.12 and legacy detailed page 2: require ready, active, Manual, sensor type 0,
   scheduled basal and no fault.
2. G4.2: require desired sensor type 0 and known control value.
3. If control is not already enabled, send exactly `SE4.2=` + `00 02 04 00` once.
   Require `ES4.2=0`. No sensor-type/identity or Automated-mode command is sent.
4. G4.2: require enabled control 0 and desired sensor type 0.
5. Repeat G3.12 and detailed page 2 with the same status requirements.

No common setup inputs are replayed by this hook. A confirmed result can be
rechecked after an interrupted app completion, with reads only. Changed state
stops the attempt; it never enables again. A verified record also rejects any
attempt to repeat priming, initial basal programming or fresh insertion after a
rollback of the host's saved setup progress.

The per-Pod journal is armed during pairing, protected in Application Support,
excluded from backups, locked and atomically fsynced before each exchange.
`writePending` is saved before the only write. A timeout, rejection, malformed
response, status mismatch or interrupted attempt stops further automatic enable
attempts. Missing/corrupt journals also stop. Unsupported firmware is rejected
before priming. Insertion errors from this component suppress the UI's retry and
offer the existing deactivation flow. Cannula insertion and scheduled basal may
already have begun when a post-insertion experiment fails; this error does not
claim to stop insulin delivery.

**Pod Diagnostics → Pump Manager Details** includes the local activation journal
for review/export. It includes application requests/reply bodies and wall times;
it does not contain session keys. The existing message logs retain transport
responses. No special logging toggle is needed for this record.

This feature does not pair a G7, prove sustained operation or establish a failure
probability. Leave sensor connection for the separately reviewed late-life,
removed-Pod experiment. A green insertion screen means immediate checks passed,
not that E2 cannot happen later.
