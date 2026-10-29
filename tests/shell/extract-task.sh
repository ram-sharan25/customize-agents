#!/usr/bin/env bash
# extract-task PLAN N prints exactly the *** Task N subtree.
source "$(dirname "$0")/../skills/lib.sh"
x="$repo/skills/plan-implementation/scripts/extract-task"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/plan.org" <<'ORG'
* Global constraints
- one
* Phases and tasks
** TODO Phase 1 — A
*** TODO Task 1 — First
- Files: a
*** DONE Task 2 — Second
- Files: b
**** Evidence
| x |
** TODO Phase 2 — B
*** TODO Task 12 — Twelfth
- Files: c
* Self-review
ORG

out=$("$x" "$tmp/plan.org" 2) || fail "task 2: exit $?"
expected='*** DONE Task 2 — Second
- Files: b
**** Evidence
| x |'
[[ "$out" == "$expected" ]] || fail "task 2: got: $out"

out=$("$x" "$tmp/plan.org" 1) || fail "task 1: exit $?"
[[ "$out" == $'*** TODO Task 1 — First\n- Files: a' ]] || fail "task 1 (must not match Task 12): got: $out"

out=$("$x" "$tmp/plan.org" 12) || fail "task 12: exit $?"
[[ "$out" == $'*** TODO Task 12 — Twelfth\n- Files: c' ]] || fail "task 12: got: $out"

"$x" "$tmp/plan.org" 7 >/dev/null 2>&1 && fail "missing task: expected non-zero exit"
"$x" "$tmp/nope.org" 1 >/dev/null 2>&1 && fail "missing plan: expected non-zero exit"
"$x" "$repo/tests/fixtures/plans/sample-task/plan.org" 1 | grep -q -- "--shout" || fail "fixture plan task 1"
finish
