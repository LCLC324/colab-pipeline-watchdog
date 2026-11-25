# Bantou (番頭) — never-stall supervision for delegated work

A unified supervision system for long-running delegated work — coding agents
(agy, Claude Code) and multi-hour/multi-week Google Colab pipelines — designed
so a delegation never stalls silently. Every stall ends in exactly one of two
places: silent automatic recovery, or a single final-failure report.

"Bantou" is the head clerk who runs the shop while the owner is away.

## How it works

Four parts, one of them code:

1. **State file** (one JSON per delegation) — the single source of truth:
   phase (`running` / `done` / `failed`), attempts, the worker's systemd unit
   name, the driver's heartbeat, restart timestamps. Written atomically
   (temp file → `mv`).
2. **Persistent driver** (a cron-run agent following a written body,
   `driver_body.md`) — checks the worker's liveness *and* actual progress
   (file/output growth, not process existence), restarts a hung worker a
   bounded number of times, and reports only on completion or final failure.
3. **Shared watchdog** (`watchdog/agy-delegation-watchdog.sh`, the only code) —
   an LLM-free bash+python hook that polls every 5 minutes, stats the state
   files of *all* delegations (target configs in `~/bantou/run/targets/`),
   and wakes a recovery agent only on anomaly, on a bounded ladder
   (3 wakes with cooldowns, then one final wake that reports). Terminal
   phases are always silent. It also writes its own heartbeat, which the
   drivers watch back — mutual monitoring.
4. **Worker launcher** (`launch_worker.sh`) — starts each worker as a
   **systemd transient unit**. This is load-bearing: processes spawned inside
   a cron run are killed when that run ends, and neither `nohup` nor `setsid`
   prevents it (verified by controlled experiment). A systemd unit survives.
   The launcher passes the environment explicitly (systemd units do not
   inherit it), records the exit status to `<log>.exit.json`, and stops the
   whole unit cgroup on `systemctl stop`.

## The Colab adapter

For work that runs on Colab across hours/weeks under a hard deadline, the
driver body and state file gain Colab-specific fields and checks
(`templates/`): the ~3.3h session-reaping guard (evacuate at 2.5h, no new
experiments at 3.0h), Drive evacuation verified *before* experiments start,
progress judged by epoch growth, deadline countdown modes, and an
always-submittable insurance artifact. An Apps Script "external eye" on
Drive is an optional, detector-only add-on for VM-wide failure.
Per-project watchdog scripts are retired — see `templates/legacy/` and
`templates/SETUP_CHECKLIST_delta.md` for the migration.

## Verification

- `tests/run_tests.sh` — 48 desk assertions against the watchdog script
  (sandboxed, fake clock): **48 passed, 0 failed**.
- `REVIEW_carbon.md` — an independent review of the whole system by a second
  model, which found 10 issues (3 high-severity silent blind spots) and
  fixed them in place; the fixes are what the 48 tests cover.
- The systemd launch route was proven by controlled experiment: workers
  launched by `nohup`/`setsid` from inside a cron run died with the run;
  the systemd-launched worker survived, and a hang-injection test confirmed
  the driver detects, stops, and restarts a hung worker.

## Contents

- `DESIGN.md` — the canonical spec and contracts (§5 is the single source
  of truth for state keys, launch/stop, terminal order, escalation).
- `SKILL.md` — the operating playbook, including the launch gate: install
  the state file, driver, and watchdog target *before* launching a worker.
- `driver_body.md` — the generic driver template.
- `launch_worker.sh` — the systemd worker launcher.
- `watchdog/` — the shared watchdog script and its hook definition
  (the definition targets the author's agent runtime; the script itself is
  plain bash + python3).
- `tests/run_tests.sh` — the watchdog test suite.
- `REVIEW_carbon.md` — the independent review record.
- `templates/` — the Colab adapter kit (driver body, state, target example,
  setup checklist + migration delta, Apps Script template, optional
  repairer), with the retired per-project watchdog under `legacy/`.

In the documents, `~/bantou` is the system's home directory and
`~/bantou/run` its runtime state directory; adapt both to your layout.

## History

This repository previously published the Colab-only kit ("colab-pipeline-
watchdog"). Bantou is its successor: the Colab kit became the Colab adapter
of one unified system that also supervises local agent delegations.
