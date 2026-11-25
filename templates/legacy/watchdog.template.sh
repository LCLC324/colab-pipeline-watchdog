#!/usr/bin/env bash
# Hook: no-LLM watchdog for the {{PROJECT_NAME}} experiment pipeline.
# NOTE: the platform executes this file directly every 60s and bash reads it
# incrementally. Edit it only via tmp-file in this directory + bash -n + mv
# (never overwrite it in place: a half-written file could be executed).
#
# Mechanical checks only (state file + cron definitions + colab sessions);
# this script never wakes an agent in real runs. On anomaly it sends a Slack
# DM to the owner directly via the slack connector CLI, rate-limited to one
# message per anomaly kind per 2h (history in hook_state). Every completed
# run records its own heartbeat in hook_state under
# "${WATCHDOG_KEY_PREFIX}_heartbeat", written at the end of the run (after the
# checks and notification attempts) so a fresh heartbeat means the run
# finished end to end; the pipeline driver reads it for mutual
# monitoring. Silent when healthy.
#
# Autorepair (state schema 2): while state.repair is active and
# fresh, progress_stale for repair.exp_id is suspended and the remaining
# repair minutes are added to the stall/phase_dwell limits; new kinds
# repair_overdue / repair_stale / repair_escalated (once per ticket) /
# repairer_def_missing (self-arming, see check below).
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

# ===== 設定欄（プロジェクトごとに書き換える） =====
PROJECT_NAME="{{PROJECT_NAME}}"
PROJECT_SLUG="{{PROJECT_SLUG}}"
STATE_FILE="{{STATE_FILE_PATH}}"
DRIVER_DEF_DIR="{{DRIVER_DEF_DIR}}"            # ドライバ cron 定義の置き場所（goal の crons フォルダ）
DRIVER_DEF_GLOB="{{DRIVER_CRON_ID}}*.md"       # ドライバ定義ファイルの glob
REPAIR_DIR="{{REPAIR_DIR}}"                    # 修理の作業場所（tickets/ を含む）。例: <プロジェクト>/repair
# 修理担当 cron 定義の投影ファイル（DRIVER_DEF_DIR からの相対パス）
REPAIRER_DEF_REL="{{REPAIRER_DEF_REL}}"        # 例: minutely/<repairer-cron-id>__interval@15m.md
REPAIR_FRESH_MIN=20                            # チケット更新がこの分数止まると repair_stale
OWNER_USER_ID="{{OWNER_SLACK_USER_ID}}"        # 通知先の Slack ユーザーID
SLACK_BIN="/path/to/slack"
COLAB_BIN="$HOME/workspace/colab-cli/venv/bin/colab"
WATCHDOG_KEY_PREFIX="{{PROJECT_SLUG}}_watchdog"  # hook_state のキー接頭辞
ALERT_INTERVAL_SEC=7200                        # 同種アラートの間隔（秒）
DRIVER_STALE_MIN=60                            # ドライバ最終実行からこの分数で異常
PROGRESS_STALE_MIN=45                          # RUNNING 中の実験の last_progress_at がこの分数以上古いと異常
SESSION_AGE_MAX_H=3                            # Colab セッション開始からこの時間を超えると異常（回収は約3.3時間）
LEGIT_STOP_LONG_H=48                           # LEGIT_STOP の滞在がこの時間を超えると催促
LOCK_STUCK_MIN=30                              # lock がこの分数以上保持されたままなら異常
INSURANCE_ZIP_REQUIRED_FROM="{{INSURANCE_ZIP_REQUIRED_FROM}}"  # この日（YYYY-MM-DD）以降は成果物 zip 必須。空文字で無効
# 締切前の LEGIT_STOP として正当な理由（legit_stop の値）。SUBMITTED は必ず含める
# 例: '["SUBMITTED", "<人の判断待ちの理由1>", "<理由2>"]'
LEGIT_STOP_OK_REASONS_JSON='{{LEGIT_STOP_OK_REASONS_JSON}}'
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
export PROGRESS_STALE_MIN SESSION_AGE_MAX_H LEGIT_STOP_LONG_H LOCK_STUCK_MIN
export INSURANCE_ZIP_REQUIRED_FROM LEGIT_STOP_OK_REASONS_JSON
export STALL_ALLOWANCES_JSON DWELL_LIMITS_JSON
export RUNNING_DWELL_FALLBACK_MIN RUNNING_DWELL_BUFFER_MIN DRIVER_DEF_GLOB
export REPAIR_DIR REPAIRER_DEF_REL REPAIR_FRESH_MIN

DRY=0
if [[ "${HATCH_HOOK_DRY_RUN:-0}" == "1" ]]; then DRY=1; fi
now_epoch=$(date +%s)

hook_state_raw="$(hook_state_get 2>/dev/null || echo '{}')"
if [[ -z "$hook_state_raw" ]]; then hook_state_raw='{}'; fi

# NOTE: the heartbeat is intentionally NOT written here. It is merged
# into hook_state at the end of the run (see the rate-limit/merge step
# below), so a fresh heartbeat proves the run completed its checks and
# notification attempts instead of merely having started.

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
check_rc=0
STATE_FILE="$STATE_FILE" DRIVER_DEF_DIR="$DRIVER_DEF_DIR" NOW_EPOCH="$now_epoch" \
CREATED_EPOCH="$created_epoch" HOOK_STATE_RAW="$hook_state_raw" \
python3 - "$verdict" <<'PYEOF' || check_rc=$?
import glob, json, os, sys
from datetime import datetime, date
from zoneinfo import ZoneInfo

verdict_path = sys.argv[1]
now = int(os.environ["NOW_EPOCH"])
created = int(os.environ.get("CREATED_EPOCH") or 0)
state_path = os.environ["STATE_FILE"]
state_name = os.path.basename(state_path)
tz = ZoneInfo(os.environ.get("TIMEZONE") or "Asia/Tokyo")
driver_stale_min = int(os.environ.get("DRIVER_STALE_MIN") or 60)
progress_stale_min = int(os.environ.get("PROGRESS_STALE_MIN") or 45)
session_age_max_h = int(os.environ.get("SESSION_AGE_MAX_H") or 3)
legit_stop_long_h = int(os.environ.get("LEGIT_STOP_LONG_H") or 48)
lock_stuck_min = int(os.environ.get("LOCK_STUCK_MIN") or 30)
legit_ok_reasons = tuple(json.loads(os.environ["LEGIT_STOP_OK_REASONS_JSON"]))
driver_def_glob = os.environ["DRIVER_DEF_GLOB"]
repair_fresh_min = int(os.environ.get("REPAIR_FRESH_MIN") or 20)
prefix = os.environ.get("WATCHDOG_KEY_PREFIX") or "watchdog"
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

    # Retired pipeline (final submission done; the driver removes its
    # own cron definition after setting this flag): skip every
    # judgement, including the driver-definition check below -- but
    # only when the state is consistent with a completed submission
    # (phase=LEGIT_STOP with legit_stop=SUBMITTED). A retired flag in
    # any other state is itself an anomaly and does not buy silence.
    if state.get("retired") is True:
        facts["retired"] = True
        raw_retired_reason = state.get("legit_stop")
        if isinstance(raw_retired_reason, dict):
            retired_reason = raw_retired_reason.get("reason") or raw_retired_reason.get("kind")
        else:
            retired_reason = raw_retired_reason
        if phase == "LEGIT_STOP" and retired_reason == "SUBMITTED":
            out = {
                "anomalies": [],
                "facts": facts,
                "session_check": False,
                "session_name": "",
            }
            with open(verdict_path, "w") as f:
                json.dump(out, f, ensure_ascii=False)
            sys.exit(0)
        anomalies.append({
            "kind": "retired_inconsistent",
            "detail": "retired不整合: retired=true だが phase=LEGIT_STOP かつ legit_stop=SUBMITTED の完了状態と一致しません",
        })

    # Repair context (schema 2). A repair is
    # "active" while status is requested/in_progress/applied/verifying.
    # The extension below applies only while the repair is active, before
    # its deadline_at, and while its freshness source is <= REPAIR_FRESH_MIN old.
    # Freshness source: the ticket file mtime (repair/tickets/<ticket>.json);
    # while status=requested, the newer of that and repair.since. The extension
    # never silences driver_stale, driver_def_missing, state_file_broken,
    # session_age, session_missing, lock_stuck or insurance_zip_missing.
    repair = state.get("repair") if isinstance(state.get("repair"), dict) else None
    repair_status = (repair or {}).get("status")
    repair_active = repair_status in ("requested", "in_progress", "applied", "verifying")
    repair_extend = False
    repair_exp = None
    repair_remaining_min = 0
    repair_fresh_age_min = None
    if repair is not None:
        facts["repair_status"] = repair_status
        facts["repair_ticket"] = repair.get("ticket")
    if repair_active:
        repair_exp = repair.get("exp_id")
        r_deadline = parse_ts(repair.get("deadline_at"))
        r_since = parse_ts(repair.get("since"))
        fresh_ts = None
        ticket_id = repair.get("ticket")
        if isinstance(ticket_id, str) and ticket_id and "/" not in ticket_id:
            tpath = os.path.join(os.environ.get("REPAIR_DIR", ""), "tickets", ticket_id + ".json")
            try:
                fresh_ts = int(os.stat(tpath).st_mtime)
            except OSError:
                fresh_ts = None
        # requested: the driver (re)issued the request at repair.since, so
        # the newer of ticket mtime and since counts (a re-request after a
        # failed verification keeps the old ticket file).
        if repair_status == "requested" and r_since is not None:
            fresh_ts = r_since if fresh_ts is None else max(fresh_ts, r_since)
        if fresh_ts is not None:
            repair_fresh_age_min = (now - fresh_ts) // 60
        if r_deadline is not None and now < r_deadline \
                and fresh_ts is not None and now - fresh_ts <= repair_fresh_min * 60:
            repair_extend = True
            repair_remaining_min = max(0, (r_deadline - now) // 60)
        facts["repair_extend"] = repair_extend

        # repair_overdue / repair_stale: the repairer's own work
        # (requested/in_progress/applied). verifying is the driver's rerun
        # and is watched by the normal progress checks instead.
        if repair_status in ("requested", "in_progress", "applied"):
            if r_deadline is None:
                anomalies.append({
                    "kind": "repair_overdue",
                    "detail": f"修理期限不明: repair.status={repair_status} だが deadline_at が無い、または読めません（実験 {repair_exp}）",
                })
            elif now >= r_deadline:
                anomalies.append({
                    "kind": "repair_overdue",
                    "detail": f"修理期限超過: 修理 {ticket_id or '(チケット未作成)'}（実験 {repair_exp}、status={repair_status}）が deadline_at を {(now - r_deadline) // 60} 分超過",
                })
            if fresh_ts is None:
                anomalies.append({
                    "kind": "repair_stale",
                    "detail": f"修理停滞: repair.status={repair_status} だがチケットファイルが見つかりません（実験 {repair_exp}）",
                })
            elif now - fresh_ts > repair_fresh_min * 60:
                what = "チケット未作成のまま依頼から" if (repair_status == "requested" and not ticket_id) else "チケットの最終更新から"
                anomalies.append({
                    "kind": "repair_stale",
                    "detail": f"修理停滞: 修理 {ticket_id or '(未着手)'}（実験 {repair_exp}、status={repair_status}）が{what} {repair_fresh_age_min} 分経過（許容 {repair_fresh_min} 分）",
                })

    # repair_escalated: one DM per ticket (episode flag in hook_state,
    # handled by the merge step via the "episode" key).
    if repair_status == "escalated":
        anomalies.append({
            "kind": "repair_escalated",
            "episode": str((repair or {}).get("ticket") or (repair or {}).get("since") or "unknown"),
            "detail": f"自動修理の打ち切り（人の判断が必要）: 修理 {(repair or {}).get('ticket')}（実験 {(repair or {}).get('exp_id')}）が escalated になりました。repair/tickets/ のチケットを確認してください",
        })

    # Check 1: state stall, per-phase allowance in minutes (LEGIT_STOP and
    # unknown phases are not in the map and are skipped). While a repair
    # extension is in effect, the remaining repair minutes are added.
    allowances = json.loads(os.environ.get("STALL_ALLOWANCES_JSON") or "{}")
    upd = parse_ts(state.get("updated_at"))
    if phase in allowances and upd is not None:
        age_min = (now - upd) // 60
        allow = allowances[phase] + (repair_remaining_min if repair_extend else 0)
        if age_min > allow:
            ext_note = f"、修理延長 {repair_remaining_min} 分を含む" if repair_extend else ""
            anomalies.append({
                "kind": "stall",
                "detail": f"状態滞留: phase={phase} のまま {age_min} 分経過（許容 {allow} 分{ext_note}）",
            })

    # Check 2: driver staleness (DRIVER_STALE_MIN). If the driver has never
    # run, the reference point is the state file's creation time.
    drv = parse_ts(state.get("driver_last_run_at"))
    if drv is not None:
        age_min = (now - drv) // 60
        if age_min >= driver_stale_min:
            anomalies.append({
                "kind": "driver_stale",
                "detail": f"ドライバ停止の疑い: 最終実行から {age_min} 分経過",
            })
    elif created > 0:
        age_min = (now - created) // 60
        if age_min >= driver_stale_min:
            anomalies.append({
                "kind": "driver_stale",
                "detail": f"ドライバ停止の疑い: ドライバ未実行のまま状態ファイル作成から {age_min} 分経過",
            })

    # Check 5: insurance zip still missing on/after the required-from
    # date (project timezone). Empty setting disables this check.
    izf = os.environ.get("INSURANCE_ZIP_REQUIRED_FROM") or ""
    if izf:
        today_local = datetime.fromtimestamp(now, tz).date()
        if artifacts.get("best_submission_zip") is None and today_local >= date.fromisoformat(izf):
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
        dwell_cap = dwell_limits[phase] + (repair_remaining_min if repair_extend else 0)
        if dwell_min > dwell_cap:
            ext_note = f"、修理延長 {repair_remaining_min} 分を含む" if repair_extend else ""
            anomalies.append({
                "kind": "phase_dwell",
                "detail": f"フェーズ滞在超過: phase={phase} に {dwell_min} 分滞在（上限 {dwell_cap} 分{ext_note}）",
            })

    # Additional check: LEGIT_STOP before the final deadline is itself
    # anomalous (the merge step notifies it once per LEGIT_STOP episode).
    if phase == "LEGIT_STOP":
        dl = parse_ts((state.get("deadline") or {}).get("final"))
        if dl is not None and now < dl:
            raw_reason = state.get("legit_stop")
            if isinstance(raw_reason, dict):
                reason = raw_reason.get("reason") or raw_reason.get("kind")
            else:
                reason = raw_reason
            if reason not in legit_ok_reasons:
                anomalies.append({
                    "kind": "legit_stop_early",
                    "detail": "早期のLEGIT_STOP: 締切より前に phase=LEGIT_STOP へ遷移しています（正当な理由の記録なし）",
                })

    # Additional check: phase_since must exist. Without it the dwell
    # judgement silently falls back to updated_at and phase stalls
    # become invisible.
    raw_ps = wave.get("phase_since")
    wave_ps = parse_ts(raw_ps)
    if raw_ps is None or (isinstance(raw_ps, str) and not raw_ps.strip()):
        anomalies.append({
            "kind": "phase_since_missing",
            "detail": "phase_since欠落: wave.phase_since が無いため、フェーズ滞在判定の起点が記録されていません",
        })
    elif wave_ps is None:
        anomalies.append({
            "kind": "phase_since_missing",
            "detail": f"phase_since欠落: wave.phase_since={raw_ps!r} を時刻として解釈できません",
        })

    # Additional check: LEGIT_STOP dwell cap (LEGIT_STOP_LONG_H). Even a
    # legitimate stop gets a nudge when it drags on; a separate kind from
    # legit_stop_early so it is not swallowed by the episode flag.
    # Measured strictly from wave.phase_since (no updated_at fallback;
    # a missing phase_since is reported by phase_since_missing above).
    if phase == "LEGIT_STOP" and wave_ps is not None and now - wave_ps > legit_stop_long_h * 3600:
        ls_dwell_min = (now - wave_ps) // 60
        anomalies.append({
            "kind": "legit_stop_long",
            "detail": f"LEGIT_STOP長期化: LEGIT_STOP のまま {ls_dwell_min // 60} 時間経過（上限 {legit_stop_long_h} 時間）。判断待ちが長引いています",
        })

    # Additional check: RUNNING progress stall. A running experiment
    # whose last_progress_at is PROGRESS_STALE_MIN+ min old is not
    # advancing.
    if phase == "RUNNING":
        for exp in state.get("experiments") or []:
            if not isinstance(exp, dict) or exp.get("status") != "running":
                continue
            # The experiment under an extended repair is not judged here.
            if repair_extend and repair_exp is not None and exp.get("id") == repair_exp:
                continue
            lp = parse_ts(exp.get("last_progress_at"))
            if lp is None:
                continue
            lp_age_min = (now - lp) // 60
            if lp_age_min >= progress_stale_min:
                anomalies.append({
                    "kind": "progress_stale",
                    "detail": f"進捗停滞: 実験 {exp.get('id')} の last_progress_at から {lp_age_min} 分経過（許容 {progress_stale_min} 分）",
                })

    # Additional check: Colab session age. Sessions are reaped at
    # roughly 3.3h, so a session older than SESSION_AGE_MAX_H is living
    # on borrowed time. Skipped while started_at is unknown.
    sess = state.get("session") or {}
    sess_started = parse_ts(sess.get("started_at"))
    if sess_started is not None and now - sess_started > session_age_max_h * 3600:
        sess_age_min = (now - sess_started) // 60
        anomalies.append({
            "kind": "session_age",
            "detail": f"セッション長時間経過: セッション {sess.get('name')} が開始から {sess_age_min // 60} 時間 {sess_age_min % 60} 分経過（上限 {session_age_max_h} 時間）",
        })

    # Additional check: a lock held for LOCK_STUCK_MIN+ min means its
    # holder died mid-run (the driver's own runs finish well within that).
    lock_val = state.get("lock")
    lock_ts = None
    if isinstance(lock_val, dict):
        for lock_key in ("at", "acquired_at", "since", "timestamp", "held_at"):
            lock_ts = parse_ts(lock_val.get(lock_key))
            if lock_ts is not None:
                break
    elif lock_val is not None:
        lock_ts = parse_ts(lock_val)
    if lock_ts is not None:
        lock_age_min = (now - lock_ts) // 60
        if lock_age_min >= lock_stuck_min:
            anomalies.append({
                "kind": "lock_stuck",
                "detail": f"ロック残存: lock が {lock_age_min} 分保持されたままです（保持主体が途中で落ちた可能性）",
            })

# Check 3: driver cron definition exists and is enabled (independent of the
# state file).
defs = glob.glob(os.path.join(os.environ["DRIVER_DEF_DIR"], "*", driver_def_glob))
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
        "detail": f"ドライバ定義の消失: {driver_def_glob} の cron 定義が無い、または enabled: true でない",
    })

# repairer_def_missing: the repairer's cron definition projection
# (DRIVER_DEF_DIR/REPAIRER_DEF_REL) is missing or not enabled.
# Self-arming: the check is armed only after the definition file has been
# seen once (flag "<prefix>_repairer_seen" in hook_state, set by the merge
# step), so it stays silent until the repairer cron is registered, and
# alerts if it later disappears or is disabled. Skipped for schema-1 state
# (no repair field), for a retired pipeline, and when REPAIRER_DEF_REL is
# empty (autorepair not used).
try:
    _hs = json.loads(os.environ.get("HOOK_STATE_RAW") or "{}")
    if not isinstance(_hs, dict):
        _hs = {}
except Exception:
    _hs = {}
rep_rel = os.environ.get("REPAIRER_DEF_REL") or ""
if rep_rel:
    rep_path = os.path.join(os.environ["DRIVER_DEF_DIR"], rep_rel)
    rep_exists = os.path.isfile(rep_path)
    rep_enabled = False
    if rep_exists:
        try:
            with open(rep_path) as f:
                for line in f:
                    if line.strip() == "enabled: true":
                        rep_enabled = True
                        break
        except Exception:
            rep_enabled = False
    facts["repairer_def"] = "enabled" if rep_enabled else ("disabled" if rep_exists else "absent")
    if rep_exists:
        facts["repairer_def_seen"] = True
    rep_armed = bool(_hs.get(f"{prefix}_repairer_seen")) or rep_exists
    if state is not None and isinstance(state.get("repair"), dict) and rep_armed and not rep_enabled:
        anomalies.append({
            "kind": "repairer_def_missing",
            "detail": f"修理担当定義の消失: 修理担当の cron 定義（{rep_rel}）が無い、または enabled: true でない",
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

if [[ "$check_rc" -ne 0 || ! -f "$verdict" ]]; then
    # The judgement itself failed: that is an anomaly, not "healthy".
    python3 - "$verdict" <<'PYEOF' || true
import json, sys
out = {
    "anomalies": [{
        "kind": "watchdog_self_error",
        "detail": "番犬の判定処理が失敗しました: 状態チェックが異常終了したため、この回は正常とみなしていません",
    }],
    "facts": {},
    "session_check": False,
    "session_name": "",
}
with open(sys.argv[1], "w") as f:
    json.dump(out, f, ensure_ascii=False)
PYEOF
    log "state check failed; watchdog_self_error anomaly recorded" "{\"exit_code\": ${check_rc}}"
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
    elif [[ -n "$session_name" ]] && ! SESSIONS_OUT="$sessions_out" SESSION_NAME="$session_name" python3 -c 'import os,sys; name=os.environ.get("SESSION_NAME") or ""; out=os.environ.get("SESSIONS_OUT") or ""; tokens=out.replace("|", " ").replace("[", " ").replace("]", " ").split(); sys.exit(0 if name and name in tokens else 1)'; then
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
# marker. Survival DM: once per local date (last-sent date in hook_state).
# Writes: $new_state (full hook_state incl. tentative send
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

history = hook_state.get(f"{prefix}_alerts")
if not isinstance(history, dict):
    history = {}

# LEGIT_STOP episode flag: cleared whenever the phase is not LEGIT_STOP.
if facts.get("phase") != "LEGIT_STOP":
    hook_state.pop(f"{prefix}_legit_stop_notified", None)

# repair_escalated is notified once per ticket: the notified ticket ids
# are kept in hook_state (bounded to the latest 20).
esc_notified = hook_state.get(f"{prefix}_repair_escalated_notified")
if not isinstance(esc_notified, list):
    esc_notified = []

# Arm repairer_def_missing once the repairer definition has been seen.
if facts.get("repairer_def_seen") and not dry:
    hook_state[f"{prefix}_repairer_seen"] = True

due = []
for a in verdict.get("anomalies", []):
    if a["kind"] == "legit_stop_early":
        if not hook_state.get(f"{prefix}_legit_stop_notified"):
            due.append(a)
        continue
    if a["kind"] == "repair_escalated":
        if a.get("episode") not in esc_notified:
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
            elif a["kind"] == "repair_escalated":
                esc_notified = (esc_notified + [a.get("episode")])[-20:]
                hook_state[f"{prefix}_repair_escalated_notified"] = esc_notified
            else:
                history[a["kind"]] = now
        hook_state[f"{prefix}_alerts"] = history

# Survival DM: first run of each local date.
today_local = datetime.fromtimestamp(now, tz).date().isoformat()
alive_due = 0
if hook_state.get(f"{prefix}_alive_date") != today_local:
    alive_due = 1
    alive = {"channel_id": os.environ["OWNER_USER_ID"],
            "message": f"【{project}番犬】番犬は正常に動いています（{today_local}）"}
    with open(alive_args_path, "w") as f:
        json.dump(alive, f, ensure_ascii=False)
    if not dry:
        hook_state[f"{prefix}_alive_date"] = today_local

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
    if ! timeout 30 "$SLACK_BIN" call-tool --name slack_send_message --arguments-json "$(cat "$alive_args")" >/dev/null 2>&1; then
        log "alive DM send failed" '{}'
        if [[ -f "$new_state" ]]; then
            python3 - "$new_state" "$hook_state_raw" <<'PYEOF' || true
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
    if ! timeout 30 "$SLACK_BIN" call-tool --name slack_send_message --arguments-json "$(cat "$send_args")" >/dev/null 2>&1; then
        log "slack DM send failed" "{\"due\": \"${due_csv}\"}"
        if [[ -f "$new_state" ]]; then
            python3 - "$new_state" "$hook_state_raw" <<'PYEOF' || true
import json, os, sys
new_path, old_raw = sys.argv[1], sys.argv[2]
ALERTS_KEY = (os.environ.get("WATCHDOG_KEY_PREFIX") or "watchdog") + "_alerts"
ESC_KEY = (os.environ.get("WATCHDOG_KEY_PREFIX") or "watchdog") + "_repair_escalated_notified"
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
# Also roll back the once-per-ticket repair_escalated record.
if isinstance(old.get(ESC_KEY), list):
    new[ESC_KEY] = old[ESC_KEY]
else:
    new.pop(ESC_KEY, None)
with open(new_path, "w") as f:
    json.dump(new, f, ensure_ascii=False)
PYEOF
        fi
    fi
fi

# Heartbeat: recorded last, after the checks and all notification
# attempts, stamped with the completion time. If the merge step failed
# and produced no new_state, fall back to the state read at start.
hb_key="${WATCHDOG_KEY_PREFIX}_heartbeat"
hb_epoch=$(date +%s)
if [[ -f "$new_state" ]]; then
    final_state="$(jq --arg k "$hb_key" --argjson now "$hb_epoch" '.[$k] = $now' "$new_state" 2>/dev/null || echo '')"
else
    final_state="$(printf '%s' "$hook_state_raw" | jq --arg k "$hb_key" --argjson now "$hb_epoch" '.[$k] = $now' 2>/dev/null || echo '')"
fi
if [[ -n "$final_state" ]]; then
    hook_state_set "$final_state" 2>/dev/null || true
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
