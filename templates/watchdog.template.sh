#!/usr/bin/env bash
# Hook: no-LLM watchdog for the {{PROJECT_NAME}} experiment pipeline.
# NOTE: the platform executes this file directly every 60s and bash reads it
# incrementally. Edit it only via tmp-file in this directory + bash -n + mv
# (never overwrite it in place: a half-written file could be executed).
#
# Mechanical checks only (state file + cron definitions + colab sessions);
# this script never wakes an agent in real runs. On anomaly it sends a Slack
# DM to the owner directly via the slack connector CLI, rate-limited to one
# message per anomaly kind per 2h (history in hook_state). Every run records
# its own heartbeat in hook_state under "${WATCHDOG_KEY_PREFIX}_heartbeat" (the
# pipeline driver reads it for mutual monitoring). Silent when healthy.
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

# ===== 設定欄（プロジェクトごとに書き換える） =====
PROJECT_NAME="{{PROJECT_NAME}}"
PROJECT_SLUG="{{PROJECT_SLUG}}"
STATE_FILE="{{STATE_FILE_PATH}}"
DRIVER_DEF_DIR="{{DRIVER_DEF_DIR}}"            # ドライバ cron 定義の置き場所（goal の crons フォルダ）
DRIVER_DEF_GLOB="{{DRIVER_CRON_ID}}*.md"       # ドライバ定義ファイルの glob
OWNER_USER_ID="{{OWNER_SLACK_USER_ID}}"        # 通知先の Slack ユーザーID
SLACK_BIN="/opt/hatch/bin/slack"
COLAB_BIN="$HOME/workspace/colab-cli/venv/bin/colab"
WATCHDOG_KEY_PREFIX="{{PROJECT_SLUG}}_watchdog"  # hook_state のキー接頭辞
ALERT_INTERVAL_SEC=7200                        # 同種アラートの間隔（秒）
DRIVER_STALE_MIN=45                            # ドライバ最終実行からこの分数で異常
INSURANCE_ZIP_REQUIRED_FROM="{{INSURANCE_ZIP_REQUIRED_FROM}}"  # この日（YYYY-MM-DD）以降は成果物 zip 必須。空文字で無効
TIMEZONE="Asia/Tokyo"
# phase ごとの状態滞留の許容（分）。LEGIT_STOP と未知の phase は対象外
STALL_ALLOWANCES_JSON='{"SETUP": 90, "RUNNING": 40, "COLLECT": 40, "SUMMARIZE": 60, "NEXT_DESIGN": 120}'
# phase 滞在の上限（分）。RUNNING は experiments の expected_minutes 合計＋
# RUNNING_DWELL_BUFFER_MIN で機械見積りし、揃わなければ FALLBACK を使う
DWELL_LIMITS_JSON='{"SETUP": 120, "COLLECT": 60, "SUMMARIZE": 90, "NEXT_DESIGN": 120}'
RUNNING_DWELL_FALLBACK_MIN=300
RUNNING_DWELL_BUFFER_MIN=60
# ===== 設定欄ここまで =====

export PROJECT_NAME PROJECT_SLUG WATCHDOG_KEY_PREFIX TIMEZONE DRIVER_STALE_MIN
export INSURANCE_ZIP_REQUIRED_FROM STALL_ALLOWANCES_JSON DWELL_LIMITS_JSON
export RUNNING_DWELL_FALLBACK_MIN RUNNING_DWELL_BUFFER_MIN DRIVER_DEF_GLOB

DRY=0
if [[ "${HATCH_HOOK_DRY_RUN:-0}" == "1" ]]; then DRY=1; fi
now_epoch=$(date +%s)

hook_state_raw="$(hook_state_get 2>/dev/null || echo '{}')"
if [[ -z "$hook_state_raw" ]]; then hook_state_raw='{}'; fi

# Heartbeat first (best-effort jq merge, same pattern as slack-yama-dispatch),
# so liveness is recorded even if a later check fails.
hb_key="${WATCHDOG_KEY_PREFIX}_heartbeat"
hb_state="$(printf '%s' "$hook_state_raw" | jq --arg k "$hb_key" --argjson now "$now_epoch" '.[$k] = $now' 2>/dev/null || echo '')"
if [[ -n "$hb_state" ]]; then
    hook_state_set "$hb_state" 2>/dev/null || true
    hook_state_raw="$hb_state"
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
verdict="$workdir/verdict.json"

# State-file creation time (birth; fall back to mtime) for the
# driver-never-ran case of check 2.
created_epoch="$(stat -c %W "$STATE_FILE" 2>/dev/null || echo 0)"
if [[ ! "$created_epoch" =~ ^[0-9]+$ || "$created_epoch" == "0" ]]; then
    created_epoch="$(stat -c %Y "$STATE_FILE" 2>/dev/null || echo 0)"
fi

# --- Checks 1/2/3/5: state stall, driver staleness, driver definition, ---
# --- insurance zip. Pure file/JSON inspection in python.               ---
STATE_FILE="$STATE_FILE" DRIVER_DEF_DIR="$DRIVER_DEF_DIR" NOW_EPOCH="$now_epoch" \
CREATED_EPOCH="$created_epoch" \
python3 - "$verdict" <<'PYEOF' || true
import glob, json, os, sys
from datetime import datetime, date
from zoneinfo import ZoneInfo

verdict_path = sys.argv[1]
now = int(os.environ["NOW_EPOCH"])
created = int(os.environ.get("CREATED_EPOCH") or 0)
state_path = os.environ["STATE_FILE"]
state_name = os.path.basename(state_path)
tz = ZoneInfo(os.environ.get("TIMEZONE") or "Asia/Tokyo")
stale_min_limit = int(os.environ.get("DRIVER_STALE_MIN") or 45)
anomalies = []
facts = {}

def parse_ts(v):
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return int(v)
    if isinstance(v, str):
        try:
            return int(datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp())
        except Exception:
            return None
    return None

state = None
if os.path.isfile(state_path):
    try:
        with open(state_path) as f:
            state = json.load(f)
    except Exception:
        state = None

if state is None:
    facts["state_file"] = "missing_or_unparseable"
    if os.path.isfile(state_path):
        anomalies.append({
            "kind": "state_file_broken",
            "detail": f"状態ファイル破損: {state_name} の JSON が読めません",
        })
    else:
        anomalies.append({
            "kind": "state_file_broken",
            "detail": f"状態ファイル不在: {state_name} が存在しません",
        })
else:
    wave = state.get("wave") or {}
    phase = wave.get("phase")
    artifacts = state.get("artifacts") or {}
    facts["wave"] = wave.get("id")
    facts["phase"] = phase
    facts["updated_at"] = state.get("updated_at")
    facts["best_val"] = artifacts.get("best_val")
    facts["zip"] = artifacts.get("best_submission_zip")
    facts["deadline"] = (state.get("deadline") or {}).get("final")
    facts["session_name"] = (state.get("session") or {}).get("name")
    facts["drill"] = bool(state.get("watchdog_drill"))

    # Check 1: state stall, per-phase allowance in minutes (LEGIT_STOP and
    # unknown phases are not in the map and are skipped).
    allowances = json.loads(os.environ.get("STALL_ALLOWANCES_JSON") or "{}")
    upd = parse_ts(state.get("updated_at"))
    if phase in allowances and upd is not None:
        age_min = (now - upd) // 60
        if age_min > allowances[phase]:
            anomalies.append({
                "kind": "stall",
                "detail": f"状態滞留: phase={phase} のまま {age_min} 分経過（許容 {allowances[phase]} 分）",
            })

    # Check 2: driver staleness (DRIVER_STALE_MIN). If the driver has never run, the
    # reference point is the state file's creation time.
    drv = parse_ts(state.get("driver_last_run_at"))
    if drv is not None:
        age_min = (now - drv) // 60
        if age_min >= stale_min_limit:
            anomalies.append({
                "kind": "driver_stale",
                "detail": f"ドライバ停止の疑い: 最終実行から {age_min} 分経過",
            })
    elif created > 0:
        age_min = (now - created) // 60
        if age_min >= stale_min_limit:
            anomalies.append({
                "kind": "driver_stale",
                "detail": f"ドライバ停止の疑い: ドライバ未実行のまま状態ファイル作成から {age_min} 分経過",
            })

    # Check 5: insurance zip still missing on/after the required-from
    # date (project timezone). Empty setting disables this check.
    izf = os.environ.get("INSURANCE_ZIP_REQUIRED_FROM") or ""
    if izf:
        today = datetime.fromtimestamp(now, tz).date()
        if artifacts.get("best_submission_zip") is None and today >= date.fromisoformat(izf):
            anomalies.append({
                "kind": "insurance_zip_missing",
                "detail": f"保険zip未作成: best_submission_zip が null（{izf} 以降）",
            })

    # Additional check: per-phase dwell limit, measured from phase entry
    # (phase_since if present, else updated_at as the fallback).
    entry = parse_ts(state.get("phase_since")) or parse_ts(wave.get("phase_since")) or upd
    dwell_limits = json.loads(os.environ.get("DWELL_LIMITS_JSON") or "{}")
    if phase == "RUNNING":
        exps = state.get("experiments") or []
        exp_vals = [e.get("expected_minutes") for e in exps if isinstance(e, dict)]
        if exps and all(isinstance(v, (int, float)) for v in exp_vals):
            dwell_limits["RUNNING"] = int(sum(exp_vals)) + int(os.environ.get("RUNNING_DWELL_BUFFER_MIN") or 60)
        else:
            dwell_limits["RUNNING"] = int(os.environ.get("RUNNING_DWELL_FALLBACK_MIN") or 300)
    if phase in dwell_limits and entry is not None:
        dwell_min = (now - entry) // 60
        if dwell_min > dwell_limits[phase]:
            anomalies.append({
                "kind": "phase_dwell",
                "detail": f"フェーズ滞在超過: phase={phase} に {dwell_min} 分滞在（上限 {dwell_limits[phase]} 分）",
            })
    
    # Additional check: LEGIT_STOP before the final deadline is itself
    # anomalous (the merge step notifies it once per LEGIT_STOP episode).
    if phase == "LEGIT_STOP":
        dl = parse_ts((state.get("deadline") or {}).get("final"))
        if dl is not None and now < dl:
            anomalies.append({
                "kind": "legit_stop_early",
                "detail": "早期のLEGIT_STOP: 締切より前に phase=LEGIT_STOP へ遷移しています",
            })
    
# Check 3: driver cron definition exists and is enabled (independent of the
# state file).
defs = glob.glob(os.path.join(os.environ["DRIVER_DEF_DIR"], "*", os.environ["DRIVER_DEF_GLOB"]))
enabled_found = False
for path in defs:
    try:
        with open(path) as f:
            for line in f:
                if line.strip() == "enabled: true":
                    enabled_found = True
                    break
    except Exception:
        pass
    if enabled_found:
        break
if not defs or not enabled_found:
    anomalies.append({
        "kind": "driver_def_missing",
        "detail": "ドライバ定義の消失: ドライバの cron 定義が無い、または enabled: true でない",
    })

session_check = bool(state) and facts.get("phase") in ("SETUP", "RUNNING") \
    and bool(facts.get("session_name"))
out = {
    "anomalies": anomalies,
    "facts": facts,
    "session_check": session_check,
    "session_name": facts.get("session_name") or "",
}
with open(verdict_path, "w") as f:
    json.dump(out, f, ensure_ascii=False)
PYEOF

if [[ ! -f "$verdict" ]]; then
    echo '{"anomalies": [], "facts": {}, "session_check": false, "session_name": ""}' > "$verdict"
    log "state check failed; verdict defaulted" '{}'
fi

# --- Check 4: Colab session presence (only while SETUP/RUNNING). ---
# A failing/timing-out colab call is inconclusive: log it and skip the
# check this cycle rather than alerting on missing evidence.
need_session="$(python3 -c 'import json,sys; print("1" if json.load(open(sys.argv[1])).get("session_check") else "0")' "$verdict" 2>/dev/null || echo 0)"
if [[ "$need_session" == "1" ]]; then
    session_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("session_name") or "")' "$verdict" 2>/dev/null || echo "")"
    set +e
    sessions_out="$(timeout 60 "$COLAB_BIN" --auth oauth2 sessions 2>/dev/null)"
    sessions_code=$?
    set -e
    if [[ "$sessions_code" -ne 0 ]]; then
        log "session check inconclusive" "{\"exit_code\": ${sessions_code}}"
    elif [[ -n "$session_name" && "$sessions_out" != *"$session_name"* ]]; then
        python3 - "$verdict" "$session_name" <<'PYEOF' || true
import json, sys
path, name = sys.argv[1], sys.argv[2]
with open(path) as f:
    v = json.load(f)
v["anomalies"].append({
    "kind": "session_missing",
    "detail": f"セッション不在: phase={v['facts'].get('phase')} だが colab sessions に {name} が含まれない",
})
with open(path, "w") as f:
    json.dump(v, f, ensure_ascii=False)
PYEOF
    fi
fi


# --- Rate limiting, DM building, hook_state merge. ---
# Anomaly DMs: at most one per kind per 2h (history in hook_state), except
# legit_stop_early, which is sent once per LEGIT_STOP episode (flag in
# hook_state, cleared when the phase leaves LEGIT_STOP). If the state file
# carries watchdog_drill=true, the anomaly DM is prefixed with a drill
# marker. Survival DM: once per JST date (last-sent date in hook_state).
# Writes: $new_state (full hook_state incl. heartbeat and tentative send
# records), $send_args / $alive_args (slack arguments-json, only when that
# DM is due), $due_file / $count_file / $alive_file (shell control values).
new_state="$workdir/new_state.json"
send_args="$workdir/slack_args.json"
alive_args="$workdir/alive_args.json"
due_file="$workdir/due.txt"
count_file="$workdir/count.txt"
alive_file="$workdir/alive.txt"
HOOK_STATE_RAW="$hook_state_raw" NOW_EPOCH="$now_epoch" DRY="$DRY" \
OWNER_USER_ID="$OWNER_USER_ID" ALERT_INTERVAL_SEC="$ALERT_INTERVAL_SEC" \
python3 - "$verdict" "$new_state" "$send_args" "$alive_args" "$due_file" "$count_file" "$alive_file" <<'PYEOF' || true
import json, os, sys
from datetime import datetime
from zoneinfo import ZoneInfo

verdict_path, new_state_path, send_args_path, alive_args_path, due_path, count_path, alive_path = sys.argv[1:8]
with open(verdict_path) as f:
    verdict = json.load(f)
try:
    hook_state = json.loads(os.environ.get("HOOK_STATE_RAW") or "{}")
    if not isinstance(hook_state, dict):
        hook_state = {}
except Exception:
    hook_state = {}
now = int(os.environ["NOW_EPOCH"])
dry = os.environ.get("DRY") == "1"
interval = int(os.environ["ALERT_INTERVAL_SEC"])
facts = verdict.get("facts", {})
prefix = os.environ.get("WATCHDOG_KEY_PREFIX") or "watchdog"
project = os.environ.get("PROJECT_NAME") or "pipeline"
tz = ZoneInfo(os.environ.get("TIMEZONE") or "Asia/Tokyo")

hook_state[f"{prefix}_heartbeat"] = now
history = hook_state.get(f"{prefix}_alerts")
if not isinstance(history, dict):
    history = {}

# LEGIT_STOP episode flag: cleared whenever the phase is not LEGIT_STOP.
if facts.get("phase") != "LEGIT_STOP":
    hook_state.pop(f"{prefix}_legit_stop_notified", None)

due = []
for a in verdict.get("anomalies", []):
    if a["kind"] == "legit_stop_early":
        if not hook_state.get(f"{prefix}_legit_stop_notified"):
            due.append(a)
        continue
    last = history.get(a["kind"])
    if not isinstance(last, (int, float)) or now - int(last) >= interval:
        due.append(a)

if due:
    lines = [f"【{project}番犬アラート】実験パイプラインに異常があります"]
    if facts.get("drill"):
        lines[0] = "【訓練】" + lines[0]
    for a in due:
        lines.append(f"- {a['detail']}")
    zip_state = "作成済み" if facts.get("zip") else "未作成"
    lines.append(
        f"状態: wave={facts.get('wave')} phase={facts.get('phase')} "
        f"updated_at={facts.get('updated_at')} best_val={facts.get('best_val')} "
        f"zip={zip_state} deadline={facts.get('deadline')}"
    )
    args = {"channel_id": os.environ["OWNER_USER_ID"], "message": "\n".join(lines)}
    with open(send_args_path, "w") as f:
        json.dump(args, f, ensure_ascii=False)
    if not dry:
        for a in due:
            if a["kind"] == "legit_stop_early":
                hook_state[f"{prefix}_legit_stop_notified"] = True
            else:
                history[a["kind" ]] = now
        hook_state[f"{prefix}_alerts"] = history

# Survival DM: first run of each JST date.
today_jst = datetime.fromtimestamp(now, tz).date().isoformat()
alive_due = 0
if hook_state.get(f"{prefix}_alive_date") != today_jst:
    alive_due = 1
    alive = {"channel_id": os.environ["OWNER_USER_ID"],
            "message": f"【{project}番犬】番犬は正常に動いています（{today_jst}）"}
    with open(alive_args_path, "w") as f:
        json.dump(alive, f, ensure_ascii=False)
    if not dry:
        hook_state[f"{prefix}_alive_date"] = today_jst

with open(new_state_path, "w") as f:
    json.dump(hook_state, f, ensure_ascii=False)
with open(due_path, "w") as f:
    f.write(",".join(a["kind"] for a in due))
with open(count_path, "w") as f:
    f.write(str(len(verdict.get("anomalies", []))))
with open(alive_path, "w") as f:
    f.write(str(alive_due))
PYEOF

due_csv=""
anomaly_count=0
alive_due=0
if [[ -f "$due_file" ]]; then due_csv="$(cat "$due_file")"; fi
if [[ -f "$count_file" ]]; then anomaly_count="$(cat "$count_file")"; fi
if [[ -f "$alive_file" ]]; then alive_due="$(cat "$alive_file")"; fi

# Survival DM (real runs only). If the send fails, roll back the recorded
# date so the next cycle retries.
if [[ -f "$alive_args" && "$DRY" == "0" ]]; then
    if ! "$SLACK_BIN" call-tool --name slack_send_message --arguments-json "$(cat "$alive_args")" >/dev/null 2>&1; then
        log "alive DM send failed" '{}'
        if [[ -f "$new_state" ]]; then
            WATCHDOG_KEY_PREFIX="$WATCHDOG_KEY_PREFIX" python3 - "$new_state" "$hook_state_raw" <<'PYEOF' || true
import json, os, sys
new_path, old_raw = sys.argv[1], sys.argv[2]
ALIVE_KEY = (os.environ.get("WATCHDOG_KEY_PREFIX") or "watchdog") + "_alive_date"
try:
    new = json.load(open(new_path))
except Exception:
    sys.exit(0)
try:
    old = json.loads(old_raw)
except Exception:
    old = {}
if isinstance(old.get(ALIVE_KEY), str):
    new[ALIVE_KEY] = old[ALIVE_KEY]
else:
    new.pop(ALIVE_KEY, None)
with open(new_path, "w") as f:
    json.dump(new, f, ensure_ascii=False)
PYEOF
        fi
    fi
fi

# Send the DM (real runs only). If the send fails, roll back the alert
# timestamps recorded above so the next cycle retries instead of waiting
# out the 2h rate limit.
if [[ -f "$send_args" && "$DRY" == "0" ]]; then
    if ! "$SLACK_BIN" call-tool --name slack_send_message --arguments-json "$(cat "$send_args")" >/dev/null 2>&1; then
        log "slack DM send failed" "{\"due\": \"${due_csv}\"}"
        if [[ -f "$new_state" ]]; then
            WATCHDOG_KEY_PREFIX="$WATCHDOG_KEY_PREFIX" python3 - "$new_state" "$hook_state_raw" <<'PYEOF' || true
import json, os, sys
new_path, old_raw = sys.argv[1], sys.argv[2]
ALERTS_KEY = (os.environ.get("WATCHDOG_KEY_PREFIX") or "watchdog") + "_alerts"
try:
    new = json.load(open(new_path))
except Exception:
    sys.exit(0)
try:
    old = json.loads(old_raw)
except Exception:
    old = {}
if isinstance(old.get(ALERTS_KEY), dict):
    new[ALERTS_KEY] = old[ALERTS_KEY]
else:
    new.pop(ALERTS_KEY, None)
with open(new_path, "w") as f:
    json.dump(new, f, ensure_ascii=False)
PYEOF
        fi
    fi
fi

if [[ -f "$new_state" ]]; then
    hook_state_set "$(cat "$new_state")" 2>/dev/null || true
fi

log "watchdog check" "{\"anomalies\": ${anomaly_count}, \"due\": \"${due_csv}\", \"dry_run\": ${DRY}, \"alive_due\": ${alive_due}}"

if [[ "$DRY" == "1" ]]; then
    if [[ -n "$due_csv" ]]; then
        wake "dry-run: ${PROJECT_SLUG} watchdog would send Slack DM" "{\"dry_run\": true, \"due_kinds\": \"${due_csv}\", \"anomalies\": ${anomaly_count}}"
    else
        silent "dry-run: no anomalies" "{\"dry_run\": true, \"anomalies\": ${anomaly_count}}"
    fi
elif [[ "$anomaly_count" -gt 0 ]]; then
    silent "${PROJECT_SLUG} pipeline anomalies handled by watchdog (DM sent or rate-limited)" "{\"anomalies\": ${anomaly_count}, \"due\": \"${due_csv}\"}"
else
    silent "${PROJECT_SLUG} pipeline healthy" '{"anomalies": 0}'
fi
