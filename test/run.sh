#!/usr/bin/env bash
# Run every ERT suite in this directory. Exits non-zero if any suite fails.
set -uo pipefail
cd "$(dirname "$0")/.."
# No hardcoded machine-specific fallback here: each suite locates its own
# vec0 extension via test/arc-test-vec0.el (ARC_VEC0_PATH first, then a
# handful of common install locations) and skips itself cleanly, with a
# clear message, if it finds none. Only a user-supplied ARC_VEC0_PATH that
# points nowhere is treated as a hard error -- that is a real mistake worth
# failing loudly on, not something to fall back away from.
if [ -n "${ARC_VEC0_PATH:-}" ] && [ ! -f "$ARC_VEC0_PATH" ]; then
  echo "ARC_VEC0_PATH does not exist: $ARC_VEC0_PATH" >&2
  exit 2
fi
fail=0
for f in test/test-*.el; do
  echo "== $f"
  emacs -Q -batch -L . -l "$f" -f ert-run-tests-batch-and-exit || fail=1
done
exit "$fail"
