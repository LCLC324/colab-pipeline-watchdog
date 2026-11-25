#!/usr/bin/env bash
# Desk tests for ~/hooks/scripts/agy-delegation-watchdog.sh with a fake hook
# runtime. Touches nothing outside a mktemp sandbox (no real state, no real
# hook_state). Usage: bash run_tests.sh [script_path]
set -uo pipefail
SCRIPT="${1:-$HOME/hooks/scripts/agy-delegation-watchdog.sh}"
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
pass=0; fail=0

cat > "$SB/runtime.sh" <<'EOF'
hook_state_get() { cat "$SB/hook_state.json" 2>/dev/null || echo '{}'; }
hook_state_set() { printf '%s' "$1" > "$SB/hook_state.json"; }
log() { :; }
silent() { echo "SILENT|$1|$2"; exit 0; }
wake() { echo "WAKE|$1|$2"; if [[ "${FAKE_WAKE_FAIL:-0}" == "1" ]]; then return 1; fi; exit 0; }
EOF
export SB HATCH_HOOK_RUNTIME="$SB/runtime.sh" AGY_WATCHDOG_DIR="$SB/wd"
mkdir -p "$SB/wd/targets" "$SB/work" "$SB/crons"

NOW=$(date +%s)
write_default_target() {
  cat > "$SB/wd/targets/t.json" <<EOF
{"id":"t","state_file":"$SB/state.json","driver_def":"$SB/crons/driver.md",
 "driver_stale_min":25,"work_stale_min":45,"wake_cooldown_min":20,"max_revives":3,
 "phases":{"rebuild":{"progress_paths":["$SB/work","$SB/build*.log"]},
           "meaning":{"progress_paths":["$SB/work_meaning"]}}}
EOF
}
write_default_target
driver() { printf -- '---\nid: d\nenabled: %s\n---\nbody\n' "$1" > "$SB/crons/driver.md"; }
state() { printf '{"phase":"%s","attempts":1,"driver_heartbeat_epoch":%s}' "$1" "$2" > "$SB/state.json"; }
work_age() { touch -d "@$((NOW - $1))" "$SB/work" "$SB/work/f.txt" "$SB/build2.log"; }
run() { AGY_WATCHDOG_NOW="${1:-$NOW}" bash "$SCRIPT" 2>/dev/null; }
check() { # name, expected-prefix, expected-substring, output
  if [[ "$4" == "$2"* && "$4" == *"$3"* ]]; then pass=$((pass+1)); echo "PASS $1";
  else fail=$((fail+1)); echo "FAIL $1"; echo "   got: ${4:0:400}"; fi; }
reset() { rm -f "$SB/hook_state.json" "$SB/wd/watchdog_heartbeat" "$SB/wd/targets/extra.json"; rm -rf "$SB/work_meaning"; write_default_target; }

# 1 normal
reset; driver true; state rebuild $((NOW-300)); work_age 60
check "1 normal: silent" "SILENT" '"kinds": []' "$(run)"
[[ -f "$SB/wd/watchdog_heartbeat" ]] && { pass=$((pass+1)); echo "PASS 1b heartbeat file written"; } || { fail=$((fail+1)); echo "FAIL 1b heartbeat"; }

# 2 work stale (driver fresh)
reset; driver true; state rebuild $((NOW-300)); work_age 3600
check "2 work stale: wake" "WAKE" '"kind": "work_stale"' "$(run)"

# 3 driver heartbeat stale (work fresh)
reset; driver true; state rebuild $((NOW-1800)); work_age 60
check "3 driver stale: wake" "WAKE" '"kind": "driver_stale"' "$(run)"

# 4 phase done (everything stale, driver disabled) -> silent
reset; driver false; state done $((NOW-99999)); work_age 99999
check "4 done: silent" "SILENT" '"status": "terminal"' "$(run)"
# 4b phase failed (final failure already reported by the driver) -> silent
reset; driver false; state failed $((NOW-99999)); work_age 99999
check "4b failed: silent" "SILENT" '"status": "terminal"' "$(run)"

# 5 driver disabled while not terminal
reset; driver false; state rebuild $((NOW-99999)); work_age 60
check "5 driver disabled: wake" "WAKE" '"kind": "driver_disabled"' "$(run)"

# 6 driver def missing
reset; rm -f "$SB/crons/driver.md"; state rebuild $((NOW-300)); work_age 60
check "6 driver missing: wake" "WAKE" '"kind": "driver_missing"' "$(run)"

# 7 state broken
reset; driver true; echo '{broken' > "$SB/state.json"; work_age 60
check "7 state broken: wake" "WAKE" '"kind": "state_broken"' "$(run)"

# 8 escalation ladder: wakes at t0, cooldown, t0+20m, t0+40m, final at t0+60m, then silent
reset; driver true; state rebuild $((NOW-1800)); work_age 60
check "8a wake 1" "WAKE" '"wake_no": 1' "$(run "$NOW")"
check "8b cooldown" "SILENT" '"action": "cooldown"' "$(run $((NOW+300)))"
check "8c wake 2" "WAKE" '"wake_no": 2' "$(run $((NOW+1200)))"
check "8d wake 3" "WAKE" '"wake_no": 3' "$(run $((NOW+2400)))"
check "8e final" "WAKE" '"final": true' "$(run $((NOW+3600)))"
check "8f gave up silent" "SILENT" '"action": "gave_up_silent"' "$(run $((NOW+7200)))"
# 8g recovery clears the incident: heartbeat fresh again -> silent, ladder reset
state rebuild $((NOW+7200)); touch -d "@$((NOW+7250))" "$SB/work" "$SB/work/f.txt" "$SB/build2.log"
check "8g recovered: silent" "SILENT" '"kinds": []' "$(run $((NOW+7300)))"
state rebuild $((NOW+7300-1800))
check "8h new incident starts at wake 1" "WAKE" '"wake_no": 1' "$(run $((NOW+7300)))"

# 9 legacy state without driver_heartbeat_epoch -> mtime fallback
reset; driver true; printf '{"phase":"rebuild","attempts":1}' > "$SB/state.json"; touch -d "@$((NOW-120))" "$SB/state.json"; work_age 60
check "9 no heartbeat field, fresh mtime: silent" "SILENT" '"kinds": []' "$(run)"

# 10 failed wake rolls back -> next poll wakes again (no cooldown consumed)
reset; driver true; state rebuild $((NOW-1800)); work_age 60
FAKE_WAKE_FAIL=1 run >/dev/null
check "10 wake failure rolled back" "WAKE" '"wake_no": 1' "$(run $((NOW+60)))"

# 11 dry run: no hook_state, no heartbeat file
reset; driver true; state rebuild $((NOW-1800)); work_age 60
out="$(HATCH_HOOK_DRY_RUN=1 run)"
if [[ "$out" == WAKE*dry_run* && ! -f "$SB/hook_state.json" && ! -f "$SB/wd/watchdog_heartbeat" ]]; then pass=$((pass+1)); echo "PASS 11 dry-run side-effect free"; else fail=$((fail+1)); echo "FAIL 11 dry-run: ${out:0:300}"; fi

# 12 node_modules is pruned even when mkdir updates parent directory mtime
reset; driver true; state rebuild $((NOW-300)); work_age 3600; mkdir -p "$SB/work/node_modules"; touch "$SB/work/node_modules/x"
check "12 node_modules & dir mtime ignored" "WAKE" '"kind": "work_stale"' "$(run)"
rm -rf "$SB/work/node_modules"

# 13 heartbeat=0 + rescue_epoch write must NOT mask a dead driver via state mtime
reset; driver true
printf '{"phase":"rebuild","attempts":1,"driver_heartbeat_epoch":0,"rescue_epoch":%s}' "$NOW" > "$SB/state.json"
touch -d "@$NOW" "$SB/state.json"; work_age 60
check "13 rescue_epoch does not fake heartbeat" "WAKE" '"kind": "driver_stale"' "$(run)"

# 14 re-enable gap & kind shift keep cooldown and escalate instead of looping forever
reset; driver false; state rebuild $((NOW-1800)); work_age 3600
check "14a driver_disabled wakes 1" "WAKE" '"wake_no": 1' "$(run "$NOW")"
driver true  # recovery re-enabled cron at t+1m, heartbeat hasn't ticked yet
check "14b post-enable heartbeat gap stays in cooldown" "SILENT" '"action": "cooldown"' "$(run $((NOW+300)))"
check "14c still no beat at +20m -> wake 2 (driver_stale)" "WAKE" '"wake_no": 2' "$(run $((NOW+1200)))"
state rebuild $((NOW+2300))  # driver beats, but work is still stale (kind shifts to work_stale)
check "14d kind shift driver_stale->work_stale escalates wake 3" "WAKE" '"wake_no": 3' "$(run $((NOW+2400)))"
state rebuild $((NOW+3500))
check "14e reaches final despite kind shift" "WAKE" '"final": true' "$(run $((NOW+3600)))"

# 15 invalid/undeclared phase raises state_broken without crashing hook
reset; driver true; state typo_phase $((NOW-60)); work_age 60
check "15a undeclared phase -> state_broken" "WAKE" '"state": "invalid_phase"' "$(run)"
reset; driver true; printf '{"phase":["bad"],"driver_heartbeat_epoch":%s}' "$((NOW-60))" > "$SB/state.json"; work_age 60
check "15b non-string phase -> state_broken (no crash)" "WAKE" '"state": "invalid_phase"' "$(run)"

# 16 new phase before progress_paths exist respects last_restart_epoch grace
reset; driver true
printf '{"phase":"meaning","attempts":1,"driver_heartbeat_epoch":%s,"last_restart_epoch":%s}' "$((NOW-60))" "$((NOW-120))" > "$SB/state.json"
check "16a uncreated progress dir within grace: silent" "SILENT" '"kinds": []' "$(run)"
printf '{"phase":"meaning","attempts":1,"driver_heartbeat_epoch":%s,"last_restart_epoch":%s}' "$((NOW-60))" "$((NOW-3600))" > "$SB/state.json"
check "16b uncreated progress dir past grace: work_stale" "WAKE" '"kind": "work_stale"' "$(run)"

# 17 round-robin BFS: >4000 old files in a NEWER-mtime sibling dir must not starve nested fresh file in older-mtime dir
reset; driver true; state rebuild $((NOW-60)); work_age 3600
mkdir -p "$SB/work/old_bulk" "$SB/work/src/deep" "$SB/work/ext_dir"
touch -d "@$NOW" "$SB/work/ext_dir"
ln -s "$SB/work/ext_dir" "$SB/work/dir_link"
ln -s "$SB/work/loop_b" "$SB/work/loop_a"
ln -s "$SB/work/loop_a" "$SB/work/loop_b"
python3 -c '
import os, sys
base, old_t, mid_t, new_t = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
for i in range(4200):
    p = os.path.join(base, "old_bulk", f"f{i}.txt")
    open(p, "w").close()
    os.utime(p, (old_t, old_t))
os.utime(os.path.join(base, "old_bulk"), (mid_t, mid_t))
p_new = os.path.join(base, "src", "deep", "main.py")
open(p_new, "w").close()
os.utime(p_new, (new_t, new_t))
os.utime(os.path.join(base, "src", "deep"), (old_t, old_t))
os.utime(os.path.join(base, "src"), (old_t, old_t))
' "$SB/work" "$((NOW-3600))" "$((NOW-1800))" "$((NOW-30))"
check "17a round-robin BFS finds deep fresh file despite newer-mtime bulk sibling" "SILENT" '"kinds": []' "$(run)"
rm -f "$SB/work/src/deep/main.py"; touch -d "@$((NOW-3600))" "$SB/work/src/deep" "$SB/work/src"
check "17b dir symlink & symlink loop do not fake freshness or crash" "WAKE" '"kind": "work_stale"' "$(run)"
rm -rf "$SB/work/old_bulk" "$SB/work/src" "$SB/work/ext_dir" "$SB/work/dir_link" "$SB/work/loop_a" "$SB/work/loop_b"

# 18 frontmatter enabled parser: body, indented metadata key, BOM, and inline comment
reset; work_age 60; state rebuild $((NOW-60))
printf -- '---\nid: d\n---\nenabled: false\n' > "$SB/crons/driver.md"
check "18a body enabled:false ignored" "SILENT" '"kinds": []' "$(run)"
printf -- '---\nid: d\nmetadata:\n  enabled: false\nenabled: true\n---\nbody\n' > "$SB/crons/driver.md"
check "18b indented nested enabled:false ignored" "SILENT" '"kinds": []' "$(run)"
printf '\xef\xbb\xbf---\nid: d\nenabled: "false" # paused\n---\nbody\n' > "$SB/crons/driver.md"
check "18c BOM + quoted false + comment respected" "WAKE" '"kind": "driver_disabled"' "$(run)"

# 19 missing state_file MUST wake even when driver_def is also missing or disabled
reset; rm -f "$SB/state.json" "$SB/crons/driver.md"
check "19a missing state + missing driver -> state_broken wake" "WAKE" '"kind": "state_broken"' "$(run)"
reset; rm -f "$SB/state.json"; driver false
check "19b missing state + disabled driver -> state_broken wake" "WAKE" '"kind": "state_broken"' "$(run)"

# 20 broken target config raises rate-limited state_broken instead of staying silent forever
reset; driver true; state rebuild $((NOW-60)); work_age 60
echo '{bad json' > "$SB/wd/targets/extra.json"
check "20a unreadable target config wakes state_broken" "WAKE" '"state": "config_unreadable"' "$(run "$NOW")"
check "20b unreadable target config respects cooldown" "SILENT" '"action": "cooldown"' "$(run $((NOW+300)))"
printf '{"id":"extra","enabled":false}' > "$SB/wd/targets/extra.json"
check "20c disabled target config skipped & purged from incidents" "SILENT" '"kinds": []' "$(run $((NOW+600)))"
if grep -q '"extra"' "$SB/hook_state.json"; then fail=$((fail+1)); echo "FAIL 20d stale incident not purged"; else pass=$((pass+1)); echo "PASS 20d stale incident purged"; fi

# 21 delayed rescue (rescue_epoch > last_wake) grants 15m post-rescue grace for revived 10m cron
reset; driver false; state rebuild $((NOW-1800)); work_age 60
check "21a initial driver_disabled wakes 1 at t0" "WAKE" '"wake_no": 1' "$(run "$NOW")"
driver true
printf '{"phase":"rebuild","attempts":1,"driver_heartbeat_epoch":%s,"rescue_epoch":%s}' "$((NOW-1800))" "$((NOW+720))" > "$SB/state.json"
check "21b +20m (only 8m after rescue at +12m) stays in cooldown" "SILENT" '"action": "cooldown"' "$(run $((NOW+1200)))"
check "21c +27m (15m after rescue, still no beat) wakes 2" "WAKE" '"wake_no": 2' "$(run $((NOW+1620)))"

# 22 epoch normalization: string seconds & ms accepted; far-future timestamp rejected
reset; driver true; work_age 60
printf '{"phase":"rebuild","attempts":1,"driver_heartbeat_epoch":"%s"}' "$((NOW-60))" > "$SB/state.json"
check "22a string seconds heartbeat accepted" "SILENT" '"kinds": []' "$(run)"
printf '{"phase":"rebuild","attempts":1,"driver_heartbeat_epoch":%s000}' "$((NOW-60))" > "$SB/state.json"
check "22b millisecond heartbeat normalized" "SILENT" '"kinds": []' "$(run)"
printf '{"phase":"rebuild","attempts":1,"driver_heartbeat_epoch":%s,"rescue_epoch":%s}' "$((NOW+9999999))" "$((NOW-1800))" > "$SB/state.json"
check "22c bogus far-future heartbeat rejected -> driver_stale" "WAKE" '"kind": "driver_stale"' "$(run)"

echo "== $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
