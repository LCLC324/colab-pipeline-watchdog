#!/usr/bin/env bash
# launch_worker.sh — 番頭（委任見張りシステム）共通の作業者起動窓口。
# systemd transient service として起動し、cron / hook 実行終了時の cgroup 片付けから分離する。
set -euo pipefail

SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# --- ExecStopPost 内部フックモード -----------------------------------------
if [[ "${1:-}" == "--finish-hook" ]]; then
  shift
  exec /usr/bin/python3 -I - "$@" <<'PY'
import datetime, json, os, signal, sys, tempfile
unit_svc, log_file, exit_file, started_at = sys.argv[1:5]
res = os.environ.get("SERVICE_RESULT", "")
code = os.environ.get("EXIT_CODE", "")
status = os.environ.get("EXIT_STATUS", "")
rc, sig = None, None
if code == "exited":
    try: rc = int(status)
    except ValueError: pass
elif code in ("killed", "dumped"):
    sig = status
    try: rc = 128 + int(getattr(signal, "SIG" + status))
    except (AttributeError, TypeError): pass
finished_at = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
rec = {
    "unit": unit_svc, "rc": rc, "signal": sig,
    "service_result": res, "exit_code": code, "exit_status": status,
    "started_at": started_at, "finished_at": finished_at, "log": log_file,
}
d = os.path.dirname(exit_file)
fd, tmp = tempfile.mkstemp(prefix=".exit.", suffix=".tmp", dir=d)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(rec, f, ensure_ascii=False, indent=2); f.write("\n")
    f.flush(); os.fsync(f.fileno())
os.chmod(tmp, 0o660)
os.replace(tmp, exit_file)
with open(log_file, "a", encoding="utf-8") as f:
    f.write(f"=== bantou_exit {finished_at} unit={unit_svc} rc={rc} result={res} signal={sig} ===\n")
PY
fi

# --- 通常起動モード --------------------------------------------------------
die() { echo "launch_worker: ERROR: $1" >&2; exit "${2:-1}"; }

[[ $# -ge 5 ]] || die "usage: launch_worker.sh <id_or_unit> <workdir> <log_file> <max_runtime_sec> <command...>" 2
RAW_NAME="$1"; WORKDIR_ARG="$2"; LOG_ARG="$3"; MAX_RT="$4"; shift 4

RAW_NAME="${RAW_NAME%.service}"
[[ ! "$RAW_NAME" =~ ^eeg- ]] || die "eeg-* ユニットは対象外のため操作禁止: '$RAW_NAME'" 2
if [[ "$RAW_NAME" == bantou-* ]]; then
  UNIT="$RAW_NAME"
else
  UNIT="bantou-$RAW_NAME"
fi
[[ "$UNIT" =~ ^bantou-[A-Za-z0-9][A-Za-z0-9_.-]{0,60}$ ]] || die "不正なユニット識別子: '$RAW_NAME'" 2
UNIT_SVC="${UNIT}.service"
[[ "$MAX_RT" =~ ^[1-9][0-9]*$ ]] || die "max_runtime_sec は正の整数: '$MAX_RT'" 2

[[ -d "$WORKDIR_ARG" ]] || die "作業ディレクトリが存在しない: '$WORKDIR_ARG'" 2
WORKDIR="$(cd "$WORKDIR_ARG" && pwd)"
case "$LOG_ARG" in
  /*) LOG_FILE="$LOG_ARG" ;;
  *)  LOG_FILE="$WORKDIR/$LOG_ARG" ;;
esac
LOG_DIR="$(dirname "$LOG_FILE")"
mkdir -p "$LOG_DIR"
LOG_FILE="$(cd "$LOG_DIR" && pwd)/$(basename "$LOG_FILE")"
EXIT_FILE="${LOG_FILE}.exit.json"

# 1. 二重起動の拒否
state="$(systemctl show "$UNIT_SVC" -p ActiveState --value 2>/dev/null || true)"
case "$state" in
  active|activating|deactivating|reloading|refreshing)
    die "ユニット '$UNIT_SVC' は稼働中（ActiveState=$state）。二重起動を拒否" 3 ;;
  failed)
    systemctl reset-failed "$UNIT_SVC" 2>/dev/null || true ;;
esac

# 2. 前回の終了記録を .prev に退避
[[ -e "$EXIT_FILE" ]] && mv -f "$EXIT_FILE" "${EXIT_FILE}.prev"

# 3. 環境変数の準備（値を引数展開せず -E NAME で安全に引き継ぐ）
export HOME="${HOME:-/home/user}"
export TZ="${TZ:-Asia/Tokyo}"
export LANG="${LANG:-C.UTF-8}"
export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

ENV_NAMES="HOME PATH LANG TZ \
  http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
  REQUESTS_CA_BUNDLE SSL_CERT_FILE CURL_CA_BUNDLE NODE_EXTRA_CA_CERTS AWS_CA_BUNDLE NODE_USE_ENV_PROXY \
  ${BANTOU_SETENV:-}"
SETENV_ARGS=()
for n in $ENV_NAMES; do
  [[ "$n" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "BANTOU_SETENV に不正な変数名: '$n'" 2
  if [[ -n "${!n+x}" ]]; then
    SETENV_ARGS+=(-E "$n")
  fi
done

LAUNCHED_AT="$(date -Iseconds)"
printf '=== bantou_launch %s unit=%s max_runtime=%ss cwd=%s ===\n' \
  "$LAUNCHED_AT" "$UNIT_SVC" "$MAX_RT" "$WORKDIR" >> "$LOG_FILE"

# 4. systemd-run 実行（--no-block を付けず fork/exec 完了まで ~20ms 同期し MainPID を確定させる）
if ! systemd-run --quiet \
      --unit="$UNIT" \
      --description="Bantou worker $UNIT" \
      --collect \
      --expand-environment=no \
      --working-directory="$WORKDIR" \
      -p UMask=0007 \
      -p RuntimeMaxSec="$MAX_RT" \
      -p TimeoutStopSec=15s \
      -p StandardOutput="append:$LOG_FILE" \
      -p StandardError="append:$LOG_FILE" \
      -p "ExecStopPost=/bin/bash \"$SELF_PATH\" --finish-hook \"$UNIT_SVC\" \"$LOG_FILE\" \"$EXIT_FILE\" \"$LAUNCHED_AT\"" \
      "${SETENV_ARGS[@]}" \
      -- "$@" >> "$LOG_FILE" 2>&1; then
  die "systemd-run が失敗（詳細は $LOG_FILE）" 4
fi

MAIN_PID="$(systemctl show "$UNIT_SVC" -p MainPID --value 2>/dev/null || echo 0)"
ACTIVE_STATE="$(systemctl show "$UNIT_SVC" -p ActiveState --value 2>/dev/null || echo unknown)"
if [[ "$ACTIVE_STATE" != "active" || "${MAIN_PID:-0}" -le 0 ]]; then
  die "起動直後にユニットが終了（ActiveState=$ACTIVE_STATE, MainPID=$MAIN_PID, exit_file=$EXIT_FILE）" 5
fi

/usr/bin/python3 -I - "$UNIT_SVC" "$MAIN_PID" "$ACTIVE_STATE" "$LOG_FILE" "$EXIT_FILE" "$LAUNCHED_AT" <<'PY'
import json, sys
u, pid, st, log, exf, ts = sys.argv[1:7]
print(json.dumps({
    "unit": u, "worker_pid": int(pid), "active_state": st,
    "log": log, "exit_file": exf, "started_at": ts,
}, ensure_ascii=False))
PY
