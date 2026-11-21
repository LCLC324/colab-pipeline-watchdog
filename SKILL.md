---
name: colab-pipeline-watchdog
description: Set up a reusable monitoring kit for long-running, deadline-bound Colab work — a state file as the single source of truth, one persistent LLM driver cron that advances the pipeline one step at a time, an LLM-free watchdog hook that alerts on stalls, and a Google Apps Script dead man's switch on Drive. Generalized from the DLBasics2026 EEG pipeline (2026-11-21). Use when starting a Colab-based project that runs for hours to weeks with a hard deadline (competition training waves, thesis experiments), or when a long background Colab job must not stall silently. Do NOT use for one-off jobs that finish in minutes.
---

# Colab pipeline watchdog: state file + single driver + LLM-free watchdog + external eye

## When to use

- The work runs on Colab for **hours to weeks**, proceeds in stages or
  experiment "waves", and has a **hard deadline** where a silent stall
  costs real time (competition submissions, thesis experiment schedules).
- Someone (the user) must be told when things stop — not discover it by
  asking "進捗は？" hours later.

Do not use for one-off jobs that finish in minutes; the setup cost is not
worth it there.

## Why this shape (the failure it prevents)

The EEG project stalled silently three times: a hung copy nobody noticed
for ~2 hours, a reaped Colab session discovered late, and a ~2-hour gap
between experiment waves because each wave's watcher deleted itself at
the end of its wave and nobody owned starting the next one. A design
review (Claude Code audit + agy Opus 5.5 review, 2026-11-21) found the
common type: **survival depended on a single deletable thing, chaining
was edge-triggered, and checks verified existence instead of progress.**
Every part below exists to kill one of those causes.

## Architecture (4 parts)

1. **State file** (`pipeline_state.json`, template:
   `templates/pipeline_state.template.json`) — the single source of
   truth: state machine phase (SETUP → RUNNING → COLLECT → SUMMARIZE →
   NEXT_DESIGN, terminal LEGIT_STOP), per-experiment progress (last
   epoch, last progress time, retries), deadline milestones, best
   artifact, a TTL lock, and the driver's last-run timestamp. All
   coordination goes through this file; nothing coordinates by chat
   messages or by a job's prose alone.
2. **Single persistent driver** (cron, interval 15m; body template:
   `templates/driver_body.template.md`) — the only actor allowed to
   start experiments. Each run takes the lock, advances exactly one
   step for the current phase (verify setup / judge progress by epoch
   growth / collect results locally / summarize + release the session +
   refresh the always-submittable insurance artifact / design and
   launch the next wave), uploads a copy of the state file to Drive,
   and updates its timestamps. It **never deletes itself** except at
   the terminal condition (LEGIT_STOP with reason SUBMITTED). It sends
   one short survival line per day; silence beyond that means only
   "healthy, nothing to report".
3. **LLM-free watchdog** (hooks platform, poll 60s; script and
   definition templates: `templates/watchdog.template.sh`,
   `templates/watchdog_definition.template.json`) — a plain shell
   script, no LLM, on a different failure path than the cron platform.
   It mechanically checks: state-file freshness per phase, per-phase
   dwell limits, driver last-run staleness (45 min), the driver cron
   definition still existing and enabled, Colab session presence while
   SETUP/RUNNING, a broken/missing state file, an early LEGIT_STOP,
   and the insurance artifact still missing after its required-from
   date. On anomaly it sends a Slack DM to the owner itself
   (rate-limited per kind, 2h), plus one survival DM per day. It
   records a heartbeat in hook_state; the driver checks that heartbeat
   in return (mutual monitoring). The watchdog never restarts anything
   — it only detects and tells.
4. **External eye** (Google Apps Script; code template:
   `templates/apps_script_code.gs.template`) — runs on Google's
   infrastructure, independent of the VM, the cron platform, and the
   LLM. A time-driven trigger reads the state-file copy on Drive and
   emails the owner if `updated_at` is stale by 60+ min,
   `driver_last_run_at` by 75+ min, or LEGIT_STOP was entered more
   than a week before the deadline. If everything on the VM side dies
   at once, the Drive copy stops advancing and this still fires. This
   is the closest thing to a true dead man's switch available without
   registering a new external service.

## Setup

Follow `templates/SETUP_CHECKLIST.md` in order:

1. Create the state file from the template; fill every `{{...}}`.
2. Register the driver cron from the body template; confirm the first
   run stamps `driver_last_run_at` and posts the daily survival line.
3. Install the watchdog script under `~/hooks/scripts/` (edit only via
   tmp file → `bash -n` → `mv`; the platform executes the file
   directly), register the definition, dry-run, enable, confirm the
   heartbeat advances.
4. **Notification drill (mandatory):** backdate `driver_last_run_at`
   by 2 hours and set `watchdog_drill: true` in the state file; verify
   the alert DM actually arrives on the receiving side (read it back
   in Slack — a send log is not proof); then restore both values.
   Note the drill consumes that alert kind's 2h rate-limit window.
5. Create the Drive copy file, wire its ID into both the driver body
   and the Apps Script; create the Apps Script project, set the
   time-driven trigger, approve permissions, confirm the Drive copy's
   timestamp tracks driver runs.
6. Confirm both daily survival signals arrive once (driver line to the
   report chat, watchdog DM to the owner). From then on, a missing
   survival signal is itself the alarm.

## Placeholders

Templates use `{{...}}` throughout. The ones that must agree across
files: `{{PROJECT_SLUG}}` (hook_state key prefix and IDs),
`{{STATE_FILE_PATH}}` (driver body and watchdog config),
`{{DRIVER_CRON_ID}}` (driver body and watchdog's definition glob),
`{{DRIVE_STATE_COPY_FILE_ID}}` (driver body and Apps Script — note the
Apps Script template calls it `{{DRIVE_STATE_FILE_ID}}`; use the same
value), and the deadline dates (state file and driver body).

Project-specific judgement calls stay in the state file / driver body,
not in the watchdog: stop decisions that need a human (e.g. an
insurance-task decision, a pre-submission review) are represented as
LEGIT_STOP with a recorded reason, which both watchers treat as
"intentionally stopped" — except that entering LEGIT_STOP well before
the deadline is itself alerted, since a mistaken LEGIT_STOP would
otherwise be perfectly silent.

## Termination

- Driver: self-removes **only** when phase=LEGIT_STOP and the recorded
  reason is SUBMITTED (final submission recorded in the project
  ledger). Never remove it by hand mid-project; a missing driver
  definition is exactly what the watchdog alerts on.
- Watchdog: disable the hook after the project ends.
- Apps Script: delete the time-driven trigger after the project ends.
- Keep the state file and results in the project folder as the record.

## Lessons baked in (measured, 2026-11-20/21)

- **Judge progress by artifacts, not existence.** A job or session
  "existing" says nothing; epoch growth in logs and metrics files
  landing locally are the progress signal.
- **One persistent driver, never per-wave watchers.** Watchers that
  delete themselves at a wave boundary create unmonitored gaps between
  waves. The driver owns collection, summarizing, and launching the
  next wave.
- **Verify notification delivery with a drill.** An alert path that
  has never been fired end-to-end is a hope, not a mechanism. Check
  arrival on the receiving side.
- **Colab sessions are reaped after ~3.3 hours.** Collect each
  experiment's metrics and logs locally as soon as it finishes; never
  leave the only copy of a result inside a session. Keep a local copy
  of the running log on every driver pass.
- **`colab upload` fails (500) if the remote directory does not
  exist.** Create directories via `colab exec` first. Also: the Colab
  CLI's `--auth oauth2` is a global flag and goes **before** the
  subcommand.
- **Deadline logic uses fixed calendar milestones, not LLM-estimated
  slack.** Point of no return, freeze date, rehearsal deadline — dates
  in the state file. An LLM guessing "how much slack is left" is a
  failure mode, not a feature.
- **Known expiries are common-cause failures.** Auth and login
  expiries (e.g. a tool login expiring before the deadline) belong in
  the state file (`known_expiries`) with a warn-from date and a
  reminder scheduled ahead of the expiry, not discovered on the day.
- **Writes to shared state are atomic-ish:** write to a temp file,
  then `mv`. A half-written JSON state file stops every reader.
