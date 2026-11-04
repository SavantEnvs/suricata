#!/usr/bin/env bash
#
# mayhem/test.sh — run Suricata's own unit-test suite (suricata -u, built by mayhem/build.sh with the
# project's normal flags and stashed at build/suricata-ut) and assert known-answer CLI output.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


UT="$SRC/build/suricata-ut"
[ -x "$UT" ] || { echo "test.sh: $UT missing (mayhem/build.sh builds it)" >&2; exit 2; }

LOGDIR="$(mktemp -d)"
trap 'rm -rf "$LOGDIR"' EXIT

passed=0; failed=0
fail() { echo "FAIL: $*" >&2; failed=$((failed + 1)); }

# 1) the whole built-in unit-test suite; every test prints "Test <name> : pass|FAILED"
"$UT" -u -l "$LOGDIR" > "$LOGDIR/ut.out" 2> "$LOGDIR/ut.err"
ut_rc=$?
ut_pass=$(sed -n 's/^PASSED: \([0-9][0-9]*\)$/\1/p' "$LOGDIR/ut.out" | tail -n 1)
ut_fail=$(sed -n 's/^FAILED: \([0-9][0-9]*\)$/\1/p' "$LOGDIR/ut.out" | tail -n 1)
if [ -z "$ut_pass" ] || [ -z "$ut_fail" ]; then
  fail "no '==== TEST RESULTS ====' summary from suricata -u (exit $ut_rc)"
elif [ "$ut_fail" -ne 0 ] || [ "$ut_rc" -ne 0 ]; then
  grep -v ': pass$' "$LOGDIR/ut.out" | tail -20 >&2
  failed=$((failed + ut_fail)); [ "$ut_fail" -eq 0 ] && fail "suricata -u exited $ut_rc"
  passed=$((passed + ut_pass))
elif [ "$ut_pass" -lt 2000 ]; then
  fail "unit-test suite ran only $ut_pass tests, expected >= 2000"
else
  passed=$((passed + ut_pass))
fi

# 2) known-answer probes of the same binary (a neutered binary prints nothing)
one=$("$UT" -u -l "$LOGDIR" -U '^CIDRFromMaskTest01$' 2> /dev/null | sed -n 's/^Test \(CIDRFromMaskTest01\) *: \(.*\)$/\1 \2/p;s/^PASSED: \(.*\)$/passed \1/p')
if [ "$one" = "$(printf 'CIDRFromMaskTest01 pass\npassed 1')" ]; then passed=$((passed + 1)); else fail "-U CIDRFromMaskTest01 gave: $one"; fi

protos=$("$UT" --list-app-layer-protos 2> /dev/null | head -8 | paste -sd,)
if [ "$protos" = "=========Supported App Layer Protocols=========,http,ftp,smtp,tls,ssh,imap,smb" ]; then
  passed=$((passed + 1)); else fail "--list-app-layer-protos gave: $protos"; fi

kw=$("$UT" --list-keywords 2> /dev/null | sed -n '1,5p' | paste -sd,)
if [ "$kw" = "=====Supported keywords=====,- sid,- priority,- rev,- classtype" ]; then
  passed=$((passed + 1)); else fail "--list-keywords gave: $kw"; fi

emit_ctrf "suricata-unittests" "$passed" "$failed" 0
