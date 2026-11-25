#!/usr/bin/env bash
# Hook: agy-delegation-watchdog — generic, no-LLM watchdog for 番頭 delegations.
# NOTE: the platform executes this file directly. Edit only via a tmp file in
# this directory + bash -n + run_tests.sh + mv (never overwrite in place).
# Stat-level checks only (no network, no log parsing, no pgrep, no notifications).
# See ~/bantou/DESIGN.md for the spec.
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

AGY_WATCHDOG_DIR="${AGY_WATCHDOG_DIR:-$HOME/workspace/agy-watchdog}"
DRY="${HATCH_HOOK_DRY_RUN:-0}"
now_epoch="${AGY_WATCHDOG_NOW:-${EPOCHSECONDS:-$(date +%s)}}"
hook_state_raw="$(hook_state_get 2>/dev/null || echo '{}')"
[[ -n "$hook_state_raw" ]] || hook_state_raw='{}'

py_rc=0
py_out="$(
AGY_WATCHDOG_DIR="$AGY_WATCHDOG_DIR" NOW_EPOCH="$now_epoch" DRY="$DRY" HOOK_STATE_RAW="$hook_state_raw" \
python3 -I - <<'PYEOF'
from collections import deque
import glob, json, os

now = int(os.environ["NOW_EPOCH"])
dry = os.environ.get("DRY") == "1"
base = os.environ["AGY_WATCHDOG_DIR"]
PRIORITY = ["state_broken", "driver_missing", "driver_disabled", "driver_stale", "work_stale"]
PRUNE = {
    "node_modules", ".git", ".cache", "__pycache__", ".venv", "venv",
    ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".next", ".nuxt", ".turbo",
}
WALK_CAP, SLICE, RESCUE_GRACE_SEC = 10000, 256, 900

def xp(p):
    return os.path.expanduser(os.path.expandvars(p)) if isinstance(p, str) and p else ""

def mtime(p):
    try:
        return int((p.stat() if hasattr(p, "stat") else os.stat(p)).st_mtime)
    except OSError:
        return 0

def pos_epoch(v):
    if isinstance(v, bool):
        return 0
    try:
        n = int(v.strip()) if isinstance(v, str) else int(v)
    except Exception:
        return 0
    if 10**11 <= n < 10**14:
        n //= 1000
    return n if 0 < n <= now + 300 else 0

def cfg_int(cfg, k, default, lo=0):
    v = cfg.get(k)
    n = default if v is None else int(v)
    if isinstance(v, bool) or n < lo:
        raise ValueError(k)
    return n

def load_dict(path):
    try:
        with open(path, encoding="utf-8") as f:
            obj = json.load(f)
        return obj if isinstance(obj, dict) else None
    except Exception:
        return None

def fresh_since(paths, cutoff):
    """Newest file mtime seen; plain files first, then round-robin BFS up to WALK_CAP."""
    files, q = [], deque()
    for raw in paths:
        p_exp = xp(raw)
        for p in (([p_exp] if os.path.exists(p_exp) else glob.glob(p_exp)) if p_exp else ()):
            (q if os.path.isdir(p) else files).append(p)
    best = 0
    for p in files:
        best = max(best, mtime(p))
        if best > cutoff:
            return best
    seen = 0
    while q and seen < WALK_CAP:
        cur = q.popleft()
        if isinstance(cur, str):
            try:
                with os.scandir(cur) as it:
                    sdirs, fents = [], []
                    for e in it:
                        try:
                            if e.is_dir(follow_symlinks=False):
                                if e.name not in PRUNE:
                                    sdirs.append(e)
                            elif e.is_file():
                                fents.append(e)
                        except OSError:
                            pass
            except OSError:
                continue
            sdirs.sort(key=mtime, reverse=True)
            q.extend(e.path for e in sdirs)
            cur = fents
        for e in cur[:SLICE]:
            seen += 1
            best = max(best, mtime(e))
            if best > cutoff:
                return best
            if seen >= WALK_CAP:
                break
        if len(cur) > SLICE and seen < WALK_CAP:
            q.append(cur[SLICE:])
    return best

def driver_enabled(path):
    """None if missing, else True/False from top-level YAML frontmatter enabled:."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            if f.readline().lstrip("\ufeff").strip() != "---":
                return True
            for i, line in enumerate(f):
                if i > 60 or line.strip() in ("---", "..."):
                    break
                if not line[:1].isspace() and line.startswith("enabled:"):
                    val = line.split(":", 1)[1].split("#", 1)[0].strip().strip("'\"").lower()
                    return val not in ("false", "no", "off", "0")
    except OSError:
        return None
    return True

try:
    hs = json.loads(os.environ.get("HOOK_STATE_RAW") or "{}")
except Exception:
    hs = {}
hs = hs if isinstance(hs, dict) else {}
incidents = hs.get("agy_watchdog_incidents") if isinstance(hs.get("agy_watchdog_incidents"), dict) else {}

active_ids, checked, due = set(), [], []
for cfg_path in sorted(glob.glob(os.path.join(base, "targets", "*.json"))):
    fallback_id = " ".join(os.path.basename(cfg_path)[:-5].split()) or "unknown"
    cfg = load_dict(cfg_path)
    if cfg is not None and not cfg.get("enabled", True):
        continue
    tid = " ".join(str((cfg or {}).get("id") or fallback_id).split()) or fallback_id
    active_ids.add(tid)

    kinds, facts, state, state_path, driver_def = [], {}, None, "", ""
    cooldown, max_revives = 1200, 3
    if cfg is None:
        kinds, facts["state"] = ["state_broken"], "config_unreadable"
    else:
        try:
            raw_term = cfg.get("terminal_phases")
            terminal = set(raw_term) if isinstance(raw_term, list) else {"done", "failed"}
            driver_stale = cfg_int(cfg, "driver_stale_min", 25, 1) * 60
            work_stale = cfg_int(cfg, "work_stale_min", 45, 1) * 60
            cooldown = cfg_int(cfg, "wake_cooldown_min", 20, 0) * 60
            max_revives = cfg_int(cfg, "max_revives", 3, 0)
            state_path, driver_def = xp(cfg["state_file"]), xp(cfg["driver_def"])
            phases_cfg = cfg.get("phases") if isinstance(cfg.get("phases"), dict) else {}
            default_paths = cfg.get("progress_paths") if isinstance(cfg.get("progress_paths"), list) else []
            if not state_path or not driver_def or (not phases_cfg and not default_paths):
                raise ValueError("invalid_cfg")
        except Exception:
            kinds, facts["state"] = ["state_broken"], "config_invalid"

    if not kinds:
        try:
            if not os.path.exists(state_path):
                kinds, facts["state"] = ["state_broken"], "missing"
            else:
                state = load_dict(state_path)
                if state is None:
                    kinds, facts["state"] = ["state_broken"], "unreadable"

            if state is not None:
                phase = state.get("phase")
                facts["phase"] = phase if isinstance(phase, (str, type(None))) else str(phase)
                facts["attempts"] = state.get("attempts")
                if isinstance(phase, str) and phase in terminal:
                    incidents.pop(tid, None)
                    checked.append({"id": tid, "phase": phase, "status": "terminal"})
                    continue

            en = driver_enabled(driver_def)
            if en is None:
                kinds.append("driver_missing")
            elif en is False:
                kinds.append("driver_disabled")

            if state is not None:
                hb = pos_epoch(state.get("driver_heartbeat_epoch"))
                if not hb and not state.get("rescue_epoch"):
                    hb = mtime(state_path)
                facts["driver_age_min"] = (now - hb) // 60 if hb else None
                if en and now - hb > driver_stale:
                    kinds.append("driver_stale")

                p_cfg = phases_cfg.get(phase) if isinstance(phase, str) else None
                p_paths = p_cfg.get("progress_paths") if isinstance(p_cfg, dict) else (p_cfg if isinstance(p_cfg, list) else None)
                paths = p_paths if isinstance(p_paths, list) and p_paths else default_paths
                if not isinstance(phase, str) or not phase.strip() or (phases_cfg and phase not in phases_cfg and not default_paths) or not paths:
                    kinds.append("state_broken")
                    facts["state"], facts["progress_age_min"] = "invalid_phase", None
                else:
                    newest = fresh_since(paths, now - work_stale)
                    facts["progress_age_min"] = (now - newest) // 60 if newest else None
                    if (newest or pos_epoch(state.get("last_restart_epoch"))) <= now - work_stale:
                        kinds.append("work_stale")
        except Exception:
            kinds, facts["state"] = ["state_broken"], "target_check_failed"

    kinds = sorted(set(kinds), key=PRIORITY.index)
    entry = {"id": tid, "kinds": kinds, **facts}
    checked.append(entry)
    if not kinds:
        incidents.pop(tid, None)
        continue
    kind = kinds[0]
    inc = incidents.get(tid)
    if not isinstance(inc, dict):
        inc = {"kind": kind, "since": now, "wakes": 0, "last_wake": 0, "gave_up": False}
    w = inc.get("wakes")
    wakes = w if isinstance(w, int) and not isinstance(w, bool) and w > 0 else 0
    inc["kind"], inc["wakes"] = kind, wakes
    incidents[tid] = inc
    if inc.get("gave_up"):
        entry["action"] = "gave_up_silent"
        continue
    last_wake = pos_epoch(inc.get("last_wake"))
    rescue_ts = pos_epoch(state.get("rescue_epoch")) if state else 0
    if last_wake and (
        now - last_wake < cooldown
        or (kind == "driver_stale" and rescue_ts > last_wake and now - rescue_ts < min(cooldown, RESCUE_GRACE_SEC))
    ):
        entry["action"] = "cooldown"
        continue
    final, cfg_d = wakes >= max_revives, (cfg or {})
    due.append({"id": tid, "kind": kind, "kinds": kinds, "final": final,
                "wake_no": wakes + (0 if final else 1), "max_revives": max_revives,
                "incident_since": inc.get("since", now), "config": cfg_path,
                "state_file": state_path, "driver_def": driver_def,
                "driver_body_file": xp(cfg_d.get("driver_body_file")),
                "recovery_doc": xp(cfg_d.get("recovery_doc")), "facts": facts})

incidents = {k: v for k, v in incidents.items() if k in active_ids}
title, decision = "", {"action": "silent", "checked": checked}
if due:
    due.sort(key=lambda d: PRIORITY.index(d["kind"]))
    pick = due[0]
    inc = incidents[pick["id"]]
    inc["last_wake"] = now
    if pick["final"]:
        inc["gave_up"] = True
    else:
        inc["wakes"] += 1
    title = ("FINAL " if pick["final"] else "recover ") + pick["id"] + ": " + pick["kind"]
    decision = {"action": "wake", "target": pick, "deferred": [d["id"] for d in due[1:]], "checked": checked}
if dry:
    decision["dry_run"] = True

hs["agy_watchdog_incidents"] = incidents
hs["agy_watchdog_heartbeat"] = now
print("\n".join([decision["action"], title, json.dumps(decision, ensure_ascii=False), json.dumps(hs, ensure_ascii=False)]))
PYEOF
)" || py_rc=$?

action="" title="" decision="" new_state=""
if [[ "$py_rc" -eq 0 && -n "$py_out" ]]; then
    { IFS= read -r action || true; IFS= read -r title || true; IFS= read -r decision || true; IFS= read -r new_state || true; } <<< "$py_out"
fi

if [[ "$py_rc" -ne 0 || ( "$action" != "silent" && "$action" != "wake" ) || -z "$decision" ]]; then
    log "agy watchdog checker failed" "{\"rc\": ${py_rc}}"
    silent "agy watchdog checker failed (rc=${py_rc})" "{\"error\": true, \"rc\": ${py_rc}}"
    exit 0
fi

if [[ "$DRY" == "1" ]]; then
    [[ "$action" == "wake" ]] && { wake "dry-run: agy watchdog would wake (${title})" "$decision" || true; }
    silent "dry-run: agy watchdog would stay silent" "$decision"
    exit 0
fi

hook_state_set "$new_state" 2>/dev/null || true
mkdir -p "$AGY_WATCHDOG_DIR" 2>/dev/null || true
hb_tmp="$AGY_WATCHDOG_DIR/.watchdog_heartbeat.$$.tmp"
if printf '%s\n' "$now_epoch" > "$hb_tmp" 2>/dev/null; then
    mv -f "$hb_tmp" "$AGY_WATCHDOG_DIR/watchdog_heartbeat" 2>/dev/null || rm -f "$hb_tmp" 2>/dev/null || true
fi

if [[ "$action" == "wake" ]]; then
    wake "agy watchdog: ${title}" "$decision" || true
    hook_state_set "$hook_state_raw" 2>/dev/null || true
    log "agy watchdog wake failed; incident state rolled back" "{}"
    silent "agy watchdog wake failed (${title})" "$decision"
    exit 0
fi

silent "agy watchdog: no wake" "$decision"
