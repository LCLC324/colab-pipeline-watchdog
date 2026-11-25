---
name: colab-pipeline-watchdog
description: Run 番頭 (Bantou), the unified never-stall supervision system for any long-running delegation (>15 min or producing deliverables — agy, Claude Code, or multi-hour/multi-week Colab pipelines). Provides the mandatory agy launch gate, attachment to the shared LLM-free `agy-delegation-watchdog` hook + persistent driver + atomic state file, plus the Colab-specific adapter kit (session reaping guard, Drive evacuation, Apps Script dead man's switch, bounded autorepair). Do NOT use the full watch setup for quick consultations finishing in minutes.
---

# 番頭（ばんとう）: unified delegation supervision + Colab pipeline adapter

## One system (unified 2026-11-24, the owner's instruction)

**番頭（ばんとう）** is the single never-stall supervision system: one atomic state file as source of truth, one persistent driver cron, one shared LLM-free watchdog, and silent bounded recovery that escalates only when its ladder is exhausted or blocked on auth/quota/rules. Workers differ (agy, Claude Code, Colab); only the worker adapter changes.

- **Canonical spec & contracts (single source of truth):** `~/bantou/DESIGN.md` (detection rules, revive ladder, target JSON schema, state keys, worker launch/stop contract; driver template: `driver_body.md`). Do not duplicate contract rules across prompts — reference `DESIGN.md` §5.
- **Standard delegations (agy, Claude Code, local jobs):** create the state file + persistent 10m driver per `DESIGN.md` §5 and add one `~/bantou/run/targets/<id>.json`. Never create a per-project watchdog script (`~/hooks/scripts/agy-delegation-watchdog.sh` watches all targets).
- **Colab adapter:** add the Colab kit below only when work runs on Colab across hours/weeks under session reaping (~3.3h) and hard deadlines.
- **Grandfathered:** one legacy run keeps its dedicated watchdog until its submission; nothing new is built on it.

## Attaching an agy delegation (the launch gate)

Apply every time `agy` is launched, resumed, or monitored. Quick consultations finishing in minutes need only steps 1, 3 (direct run OK if synchronous), and 4; anything >15 min or producing deliverables gets all 5 steps.

1. **Conversation continuity:** resume the existing conversation for the same theme (`--conversation <id>` / `-c`) and record IDs in project notes. Start fresh only when the theme changes or history is too heavy (and on driver hang/crash restarts) — passing a file-backed brief so `-p` stays well under ~120KB.
2. **Install watch before launch (same turn):** write the initial state file, register the persistent driver cron (`driver_body.md`), and register `~/bantou/run/targets/<id>.json` per `DESIGN.md` §5. Never rely on a one-off timer as the sole watch.
3. **Launch via `launch_worker.sh` (flags first, `-p` last; never bare `nohup`/`setsid`):**
   ```bash
   ~/bantou/launch_worker.sh \
     <id> <workdir> <log_file> <max_runtime_sec> \
     /bin/bash -c 'exec ~/.local/bin/agy --model <model> --dangerously-skip-permissions -p "$(cat brief.md)"'
   ```
4. **Verify start (~2s after launch):** confirm `systemctl show bantou-<id>.service -p ActiveState -p MainPID --value` reports `active` and `MainPID > 0`, `<log>.exit.json` is absent, and `<log_file>` has no instant error; record `worker_unit`, `worker_pid`, and `last_restart_epoch` in state.
5. **Operate & retire per `DESIGN.md` §5:** check `<log>.exit.json` + log tail on unexpected exit, escalate auth/quota/rule blockers immediately without auto-repair, judge completion strictly by deliverables, and write `phase=done` (or `failed`) before disabling the driver.

---

## Colab adapter kit (for multi-hour / multi-week Colab pipelines)

### When to add the Colab adapter

Add this adapter when staged/wave experiments run on **Colab for hours to weeks** under a **hard deadline**, where ~3.3h Colab session reaping or VM-wide failure could lose work silently.

### Components (`templates/` in this skill directory)

1. **Wave & deadline state (`templates/pipeline_state.template.json`, 番頭型, 2026-11-25):** 番頭 §5 のトップレベルキー (`phase` / `attempts` / `worker_unit` / `worker_pid` / `driver_heartbeat_epoch` / `last_restart_epoch` / `note`, 終端は `done` / `failed`) に `colab.*` を足したもの。波フェーズは `setup` → `running` → `collect` → `summarize` → `next_design`。`colab.session_started_at`（~3.3h 回収時計）、`colab.drive_evac_verified`（実験開始前の Drive 退避疎通確認）、epoch 進捗、固定の `colab.deadline.*`（`NORMAL` / `FREEZE` / `DEGRADED`）、保険成果物、`drive_copy`（任意・検出専用）、60分 TTL の `lock` を持つ。更新は一時ファイル→`mv`。
2. **Wave driver (`templates/driver_body.template.md`, 10m cron):** sole actor touching Colab or state. Advances one phase step per tick (3-strike setup cap, epoch-growth progress check, Drive evacuation before ~3.3h reaping with 2.5h early-evacuation and 3.0h no-new-experiment gates, collect with local verification, summarize + session release + insurance refresh, next wave launch), updates `deadline.mode` once daily, and retires by writing `phase=done` (or `failed`) first, then disabling the driver. Colab-specific checks (session age, epoch stall, deadline) live in the driver, not in a watchdog.
3. **Watchdog attachment:** the shared `agy-delegation-watchdog` only — add one `~/bantou/run/targets/<id>.json` (example: `templates/bantou-colab-target.example.json`). Per-project watchdog scripts are retired (`templates/legacy/`); never create one.
4. **External eye (`templates/apps_script_code.gs.template`, optional, detector-only):** VM-independent Google Apps Script trigger on Drive, only when `colab.drive_copy.enabled=true`. Reads 番頭 keys (`driver_heartbeat_epoch`, `phase`, `colab.deadline`); see `templates/SETUP_CHECKLIST_delta.md` §5 for the key remapping.
5. **Optional bounded autorepair (`templates/repairer_body.template.md`, `templates/run_rerun.sh.template`):** post-hoc only, as a driver + independent repairer cron — never attached to the shared watchdog. Repairs crashed own scripts under hard caps (2 tickets/exp, 4/wave, 6 agy calls/day, 60m & 2 tries/ticket; disabled in `FREEZE`). Repairer writes only `repair/tickets/<id>.json`, `repair/<id>/`, and its lock:
   - **B** (plain script bug): unified diff ≤80 lines, no test/label/split/seed/submission edits, `patch --dry-run` + `py_compile`/`bash -n` + `SMOKE=1`, sha256 backup/restore.
   - **B'** (OOM / DataLoader hang / missing pip): fixed recipe.
   - **C** (auth, quota, NaN, out-of-scope, near deadline): escalate immediately.
   - **Wave script contract:** `SMOKE=1`, per-epoch `ckpt_last.pt` + `--resume`, runnable via `run_rerun.sh expN`, and machine-written `error.json`.

### Setup, CLI pitfalls & retirement

Follow **`templates/SETUP_CHECKLIST.md`** for placeholder substitution, then apply the migration deltas in **`templates/SETUP_CHECKLIST_delta.md`** (番頭方式への載せ替え：共有番犬のみ、10分周期、終端 `done` / `failed`、Apps Script は任意の検出専用、案件別番犬は廃止). Keep two Colab CLI rules in mind throughout:

- Always create remote directories via `colab exec` (`mkdir -p`) **before** `colab upload` (missing remote parent dir triggers HTTP 500).
- Place `--auth oauth2` **before** the `colab` subcommand.
