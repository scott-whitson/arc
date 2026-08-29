#!/usr/bin/env bash
# Run every ERT suite in this directory. Exits non-zero if any suite fails.
set -uo pipefail
cd "$(dirname "$0")/.."
export ARC_VEC0_PATH="${ARC_VEC0_PATH:-/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so}"
if [ ! -f "$ARC_VEC0_PATH" ]; then
  echo "ARC_VEC0_PATH does not exist: $ARC_VEC0_PATH" >&2
  exit 2
fi
fail=0
for f in test/test-*.el; do
  echo "== $f"
  emacs -Q -batch -L . -l "$f" -f ert-run-tests-batch-and-exit || fail=1
done
exit "$fail"
