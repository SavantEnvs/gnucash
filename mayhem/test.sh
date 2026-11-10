#!/usr/bin/env bash
#
# mayhem/test.sh — RUN GnuCash's own ctest suite (85 unit/integration tests, built by mayhem/build.sh
# into .build-test with the normal flags). Each test asserts engine, XML/SQL backend, app-utils and guile
# binding behavior with its own checks; the CTRF counts come from ctest's summary.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
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

# ctest builds nothing; a missing tree means build.sh did not run.
[ -f .build-test/CTestTestfile.cmake ] || { echo "missing .build-test: run mayhem/build.sh first" >&2; exit 2; }

junit="$(mktemp)"
ctest --test-dir .build-test --output-junit "$junit" --output-on-failure 2>&1 | tail -n 40
# A test counts as passed only if ctest passed it AND it printed its own "Testing ..."/result output.
# A test binary that was replaced by a no-op exits 0 silently, so it is reported as skipped, not passed.
read -r passed failed skipped < <(python3 - "$junit" <<'PY'
import sys, xml.etree.ElementTree as ET
p = f = s = 0
for tc in ET.parse(sys.argv[1]).getroot().iter("testcase"):
    if tc.find("failure") is not None or tc.find("error") is not None:
        f += 1
    elif tc.find("skipped") is not None or not (tc.findtext("system-out") or "").strip():
        s += 1
    else:
        p += 1
print(p, f, s)
PY
)
rm -f "$junit"
if [ -z "${passed:-}" ] || [ $(( passed + failed + skipped )) -eq 0 ]; then
  echo "ctest produced no results" >&2
  emit_ctrf "cmake-ctest" 0 1 0
  exit 1
fi
emit_ctrf "cmake-ctest" "$passed" "$failed" "$skipped"
