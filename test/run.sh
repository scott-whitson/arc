#!/usr/bin/env bash
# Run every ERT suite in this directory. Exits non-zero if any suite fails.
set -uo pipefail
cd "$(dirname "$0")/.."
# No hardcoded machine-specific fallback here: each suite locates its own
# vec0 extension via test/arc-test-vec0.el (ARC_VEC0_PATH first, then a
# handful of common install locations) and skips itself cleanly, with a
# clear message, if it finds none. Only a user-supplied ARC_VEC0_PATH that
# points nowhere is treated as a hard error -- that is a real mistake worth
# failing loudly on, not something to fall back away from; arc-test-vec0.el
# also enforces this itself now, for a suite run directly rather than
# through this script.
if [ -n "${ARC_VEC0_PATH:-}" ] && [ ! -f "$ARC_VEC0_PATH" ]; then
  echo "ARC_VEC0_PATH does not exist: $ARC_VEC0_PATH" >&2
  exit 2
fi
fail=0
total_tests=0
skipped=0
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
for f in test/test-*.el; do
  echo "== $f"
  emacs -Q -batch -L . -l "$f" -f ert-run-tests-batch-and-exit 2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  [ "$status" -eq 0 ] || fail=1
  if grep -q '^SKIP:' "$log"; then
    skipped=$((skipped + 1))
  else
    # last "Ran N tests" line in this suite's own output, not a stray
    # match from an earlier suite -- each suite gets a fresh $log.
    n=$(grep -oP 'Ran \K[0-9]+(?= tests)' "$log" | tail -1)
    total_tests=$((total_tests + ${n:-0}))
  fi
done
# A suite skipped for want of a vec0 extension still exits 0 -- on
# purpose, that is not a failure -- so without this line, running 83 of
# 149 tests and running all 149 print exactly the same "exit 0" and are
# not otherwise distinguishable from the shell's own exit status alone.
echo "---"
echo "arc test summary: ${total_tests} test(s) run across $(( $(ls test/test-*.el | wc -l) - skipped )) suite(s), ${skipped} suite(s) skipped (no vec0 extension found), exit ${fail}"
exit "$fail"
