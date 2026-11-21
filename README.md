# colab-pipeline-watchdog

A reusable monitoring kit for long-running, deadline-bound work on Google Colab — designed so a pipeline never stalls silently.

## What it is

Four parts that watch each other, plus an optional bounded autorepair:

1. **State file** (`pipeline_state.json`) — the single source of truth: state-machine phase, per-experiment progress, deadline milestones, best artifact, a TTL lock, and the driver's last-run timestamp.
2. **Single persistent driver** (cron, every 15 min) — the only actor allowed to start experiments. Each run takes the lock, advances the pipeline exactly one step (verify setup / judge progress by actual output growth / collect results locally / summarize and refresh the always-submittable insurance artifact / design and launch the next wave), and uploads a copy of the state file to Drive. It never deletes itself except at the terminal condition.
3. **LLM-free watchdog** (a plain shell hook, poll 60s) — mechanically checks state-file freshness, per-phase dwell limits, driver staleness, session presence, and a missing insurance artifact, and alerts the owner directly. No LLM, on a different failure path than the driver. With autorepair it also watches the repair itself (overdue / stale tickets, one alert per escalation, the repairer cron disappearing) and extends stall limits only while a repair is fresh.
4. **External eye** (Google Apps Script on a time trigger) — reads the state-file copy on Drive and emails the owner if updates stop. A dead man's switch that survives even if the whole local platform dies. A daily heartbeat file on Drive lets the driver confirm the external eye is still alive.
5. **Autorepair (optional)** — a separate cron that picks up crashed experiments the driver has flagged, classifies the failure mechanically (auto-fix / fixed prescription / escalate to a human), asks a coding agent for a minimal diff only, passes it through a mechanical gate (allow-listed files, size cap, forbidden words, metrics keys preserved, patch dry-run) and local checks, and hands it back to the driver, which alone touches the Colab session and reruns the experiment. Hard limits per experiment, per wave, per day, and per ticket.

## When to use it

Work that runs on Colab for hours to weeks, proceeds in stages or experiment "waves", and has a hard deadline where a silent stall costs real time (competition training, thesis experiments). Not worth it for one-off jobs that finish in minutes.

## Contents

- `SKILL.md` — the full playbook: architecture, setup/teardown procedure, and the lessons behind each part.
- `templates/` — fill-in templates for every part: `pipeline_state.template.json`, `driver_body.template.md`, `watchdog.template.sh`, `watchdog_definition.template.json`, `apps_script_code.gs.template`, `repairer_body.template.md`, `run_rerun.sh.template`, and `SETUP_CHECKLIST.md`.
- `templates/run_rerun.sh.template` — the single-experiment rerun script used by autorepair: one experiment at a time (flock), refuses while the chain or another experiment runs, moves the previous train.log / metrics.json / error.json to `attempts/`, logs START / END rc= to rerun.log, and passes extra args through to the experiment script.
