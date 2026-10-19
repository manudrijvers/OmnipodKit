# Short removed-Pod G7 screen

Protocol `short-g7-screen-v1`, 2026-10-19. This is a one-shot research screen,
not a validated pairing workflow. It uses the existing controller context and
original recovered enable-plus-identity batch. No Pod execution is claimed by
the implementation or its synthetic tests.

## Scope and time

Allow about **20 minutes**, excluding normal deactivation and replacement:
two minutes of baseline observation plus read/export overhead, one batch send,
and a 15-minute window measured from the captured send. Connection/read time
can add overhead; there is no promise of a hard 20-minute wall-clock finish.
The deadline does not restart after an ACK, identity readback, or first glucose.
An expired deadline before monitoring begins produces an incomplete result.
An in-flight exchange is allowed to finish or fail rather than being killed
and silently retried at the deadline.

This shorter protocol deliberately omits the old ten-minute baseline/reconnect
windows and the later reconnect test. It also does not implement physical
target/DIA confirmation reads or settle firmware-9 activation differences.
Those inputs remain unmeasured and are recorded as such. A failure cannot
isolate a particular missing setup value. The longer enable-only and provision
actions retain their previous gates and must not be mixed into this session.

## Before opening the session

Use only a physically removed Pod that is no longer supplying therapy, remains
Trio's active Pod, and is **already suspended**. The screen reads the raw
detailed-status delivery nibble and refuses a nonsuspended state; it does not
suspend, resume, change the insulin program, or enter Auto mode. Automatic
dosing must already be off. Keep it off until the Pod is normally replaced.

The mutation requires firmware 9.0.4 / BLE 5.0.2, Manual algorithm mode, active
and nonfaulted status, DEFAULT control (255), the recognized empty identity,
the existing validated interface fields, nonempty reservoir, exact saved target
context, a valid provisioned signing policy, and intact logging/feed checks.
Other starting states produce a stopped session, not an alternative command.

Keep phone/watch feeds available and the experiment screen foregrounded.
No new Pod/controller handoff is added. The background-maintenance pause has
the same scope as the prior runner; manual/ordinary commands remain possible.
Avoid concurrent ordinary commands during observation and record any that occur.

## On the phone

Open **Omnipod 5 settings → Removed Pod Experiment**.

1. Confirm the Pod is removed, then **Start session with the active Pod**.
2. In **Short G7 screen**, select **1. Capture short baseline · 2 minutes**.
   It reads status, verifies an export, and observes for two minutes without
   writes. Do not select the earlier ten-minute protocol buttons.
3. Enter the actual G7 code and serial as text, preserving leading zeroes.
4. Select **2. Send G7 batch once · observe 15 minutes**.
   This makes fresh prerequisite reads, durably records one-shot intent, sends
   one application batch `[control-only enable, G7 identity]`, validates both
   replies, sends the recovered post-provision status group, checks diagnostic
   readback, then observes until the send-based deadline.
5. Export **private raw capture** and **redacted session**. Keep private captures
   private. Stop/leave the experiment and deactivate/replace normally.

There is no preliminary standalone enable, desired sensor-type write, full
initializer replay, input rewrite, automatic resend or reconnect experiment.
The result is either a stopped/incomplete attempt, new fresh glucose observed
within the short window, or no new fresh glucose observed within that window.
Absence within 15 minutes does not prove pairing impossible. Fresh samples do
not prove reliability, safe activation, or successful recovery on reconnect.
Legacy `enableVerified`/`receptionObserved` success flags are not set by this
short protocol. Completion disarms and locks further writes; diagnostic reads
and export remain available.

## Failure and capture

Faults override apparently ready/active AID flags. A rejected member, malformed
reply, wrong identity, mode/delivery change, capture failure, target mismatch,
interrupted phone/watch feed, foreground loss or uncertain send stops the run.
An audible alarm has a separate operator marker. A restart retains intent and
pending exchanges and does not permit the batch again. Do not erase the journal
to retry on that Pod.

Retain the exact source/build ID, firmware, starting delivery state, sensor
identity privately, application requests/replies, send-based deadline, actual
duration, fresh sample timestamps, independent feed observations and final
fault status. This capture is limited to the bench adapter, not all app traffic.

## Validation

The portable Swift tests use simulated collaborators, including a deterministic
physical-radio double. They exercise both-member rejection, identity mismatch,
E2 overriding ready status, suspended-state gating, post-send timing, delayed
configuration, missing glucose, interrupted capture/send and restart behavior.
These tests establish software behavior, not acceptance by real Pod firmware.
An iOS Simulator build is also required for the exact Trio submodule pin.
