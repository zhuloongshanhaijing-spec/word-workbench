#!/bin/zsh
# Regression Firewall — runs the full auto-test suite and compares against baseline.
#
# Usage:
#   zsh tools/regression-firewall.sh                    # run and check against baseline
#   zsh tools/regression-firewall.sh --baseline          # record current results as baseline
#   zsh tools/regression-firewall.sh --quick             # quick check (skip Anki, skip restart)
#
# Exit codes:
#   0 — all tests pass, no regressions
#   1 — test failures (but no new regressions vs baseline)
#   2 — new regression detected
#   3 — infrastructure error (build/app/Anki not available)

set -eu
here="${0:A:h}"
workspace="${here:h}"
logdir="$workspace/.harness-local/test-logs"
mkdir -p "$logdir"

ts="$(date '+%Y-%m-%dT%H%M%S')"
run_log="$logdir/run-$ts.log"
report_json="$logdir/report-$ts.json"
baseline_json="$logdir/baseline-report.json"
diff_report="$logdir/diff-$ts.txt"

mode="full"
baseline_mode=0
for arg in "$@"; do
  case "$arg" in
    --baseline) baseline_mode=1 ;;
    --quick) mode="quick" ;;
  esac
done

# ------------------------------------------------------------
# Phase 0: Build
# ------------------------------------------------------------
print "=== Regression Firewall ===" | tee "$run_log"
print "Timestamp: $ts" | tee -a "$run_log"
print "Mode: $mode" | tee -a "$run_log"
print "" | tee -a "$run_log"

print "[0/4] Building app..." | tee -a "$run_log"
cachedir="$workspace/work/build-cache"
if ! (cd "$workspace/outputs" && zsh build.sh >> "$run_log" 2>&1); then
  print "FATAL: build failed" | tee -a "$run_log"
  exit 3
fi
print "  Build OK" | tee -a "$run_log"

print "[0/4] Compiling auto-test..." | tee -a "$run_log"
swiftc -module-cache-path "$workspace/work/harness-module-cache" -parse-as-library \
  "$workspace/tools/auto-test.swift" -o /tmp/wwb-auto-test >> "$run_log" 2>&1 || {
  print "FATAL: auto-test compile failed" | tee -a "$run_log"
  exit 3
}
print "  auto-test OK" | tee -a "$run_log"

# ------------------------------------------------------------
# Phase 1: Ensure Anki
# ------------------------------------------------------------
print "[1/4] Checking Anki..." | tee -a "$run_log"
if ! curl -s -m 3 -X POST http://127.0.0.1:8765 -d '{"action":"version","version":6}' | grep -q '"result"'; then
  anki_root="$workspace/.harness-local"
  anki_bin="$anki_root/anki-app/Anki.app/Contents/MacOS/anki"
  if [[ -x "$anki_bin" ]]; then
    print "  Starting Anki..." | tee -a "$run_log"
    nohup "$anki_bin" -b "$anki_root/anki-temp/base" -l en > /tmp/anki-firewall.log 2>&1 &
    for i in $(seq 1 30); do
      curl -s -m 3 -X POST http://127.0.0.1:8765 -d '{"action":"version","version":6}' | grep -q '"result"' && break
      sleep 1
    done
  fi
fi
if curl -s -m 3 -X POST http://127.0.0.1:8765 -d '{"action":"version","version":6}' | grep -q '"result"'; then
  print "  Anki OK" | tee -a "$run_log"
else
  print "  WARNING: Anki not available — A2 tests will be skipped" | tee -a "$run_log"
fi

# ------------------------------------------------------------
# Phase 2: Launch app
# ------------------------------------------------------------
print "[2/4] Launching app..." | tee -a "$run_log"
pkill -9 -f WordWorkbench 2>/dev/null || true
for i in $(seq 1 10); do pgrep -f WordWorkbench >/dev/null || break; sleep 0.5; done
open "${WWB_APP_PATH:-$HOME/Applications/每日录词工作台.app}"
for i in $(seq 1 15); do
  sleep 1
  if pgrep -q WordWorkbench 2>/dev/null; then break; fi
done
print "  App launched" | tee -a "$run_log"

# ------------------------------------------------------------
# Phase 3: Run tests
# ------------------------------------------------------------
print "[3/4] Running auto-test..." | tee -a "$run_log"
/tmp/wwb-auto-test 2>&1 | tee -a "$run_log"
exit_code=$?
cp /tmp/wwb-autotest-report.json "$report_json" 2>/dev/null || true
print "  Exit code: $exit_code" | tee -a "$run_log"

# ------------------------------------------------------------
# Phase 4: Diff against baseline
# ------------------------------------------------------------
if [[ "$baseline_mode" == "1" ]]; then
  cp "$report_json" "$baseline_json"
  print "[4/4] New baseline recorded: $baseline_json" | tee -a "$run_log"
  print "" | tee -a "$run_log"
  print "=== BASELINE SAVED ===" | tee -a "$run_log"
  exit 0
fi

print "[4/4] Comparing against baseline..." | tee -a "$run_log"
if [[ ! -f "$baseline_json" ]]; then
  cp "$report_json" "$baseline_json"
  print "  No baseline found — current results saved as baseline." | tee -a "$run_log"
  exit $exit_code
fi

# Compare: auto-test report format is a summary {total, passed, failed}
python3 -c "
import json, sys

report = json.load(open('$report_json'))
try:
    baseline = json.load(open('$baseline_json'))
except:
    baseline = {}

r_total = report.get('total', 0)
r_passed = report.get('passed', 0)
b_total = baseline.get('total', 0)
b_passed = baseline.get('passed', 0)

print(f'Result: {r_passed}/{r_total} passed (baseline {b_passed}/{b_total})')

if r_total == 0:
    print('REGRESSIONS DETECTED: report empty — auto-test did not run')
    sys.exit(2)

if r_passed < r_total:
    print(f'REGRESSIONS DETECTED: {r_total - r_passed} check(s) failing now')
    sys.exit(2)

if b_total and r_passed < b_passed:
    print(f'REGRESSIONS DETECTED: passed count dropped {b_passed} -> {r_passed}')
    sys.exit(2)

print('NO REGRESSIONS')
sys.exit(0)
" > "$diff_report" 2>&1
diff_exit=$?

cat "$diff_report" | tee -a "$run_log"

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
print "" | tee -a "$run_log"
print "=== COMPLETE ===" | tee -a "$run_log"
print "Run log:     $run_log" | tee -a "$run_log"
print "Report JSON: $report_json" | tee -a "$run_log"
print "Diff:        $diff_report" | tee -a "$run_log"

if [[ "$diff_exit" == "2" ]]; then
  print "REGRESSION DETECTED — review diff" | tee -a "$run_log"
  exit 2
fi
exit $exit_code