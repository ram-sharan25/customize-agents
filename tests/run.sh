#!/usr/bin/env bash
# Full suite: every structural and shell check, then the ERT tests in batch.
# Exits non-zero when anything fails.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
emacs_bin="${EMACS_BIN:-/Applications/Emacs.app/Contents/MacOS/Emacs}"
status=0

for check in "$here"/skills/*.sh "$here"/shell/*.sh; do
  [[ -e "$check" && "$(basename "$check")" != lib.sh ]] || continue
  bash "$check" || status=1
done

ert_files=()
for f in "$repo"/emacs/agent-sessions/*-test.el; do ert_files+=(-l "$f"); done
if ! ert_out=$(cd "$repo/emacs/agent-sessions" && "$emacs_bin" -Q --batch \
    --eval '(progn (setq package-user-dir (expand-file-name "~/.emacs.d/elpa")) (package-initialize))' \
    -L . "${ert_files[@]}" -f ert-run-tests-batch-and-exit 2>&1); then
  echo "$ert_out" | grep -E 'FAILED|unexpected|Error|error' | head -40
  status=1
fi
echo "$ert_out" | grep -E '^Ran [0-9]+ tests'

if (( status == 0 )); then echo "SUITE: PASS"; else echo "SUITE: FAIL"; fi
exit $status
