# Assertion helpers for structural checks on skill and instruction text.
# Source this file, call the helpers, then end the script with `finish`.
# Each helper prints one line per failure and returns non-zero, so a check
# script reports every missing item instead of stopping at the first.

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
failures=0

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
  return 1
}

# require_text FILE TEXT — FILE contains TEXT (fixed string).
require_text() {
  grep -qF -- "$2" "$1" 2>/dev/null || fail "$1: missing text: $2"
}

# require_regex FILE REGEX — FILE matches the extended REGEX (case-insensitive).
require_regex() {
  grep -qiE -- "$2" "$1" 2>/dev/null || fail "$1: no match for /$2/"
}

# forbid_text FILE TEXT — FILE does not contain TEXT (fixed string).
forbid_text() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then fail "$1: forbidden text: $2"; fi
}

# forbid_regex FILE REGEX — FILE does not match REGEX (case-insensitive).
forbid_regex() {
  if grep -qiE -- "$2" "$1" 2>/dev/null; then fail "$1: forbidden match /$2/"; fi
}

# require_heading FILE HEADING — a line of FILE starts with HEADING.
require_heading() {
  grep -qE -- "^$(printf '%s' "$2" | sed 's/[][\.*^$+?(){}|/]/\\&/g')" "$1" 2>/dev/null \
    || fail "$1: missing heading: $2"
}

# require_stage_common FILE — the items every stage skill must have.
require_stage_common() {
  require_text "$1" "instructions/shared/workflow-conventions.md"
  require_regex "$1" '\| *Excuse *\| *Reality *\|'
  require_regex "$1" '^[^a-z]*next: /'
  require_text "$1" "emacs-share state"
  require_text "$1" "emacs-share folder plans"
  require_text "$1" "emacs-share folder code"
  forbid_regex "$1" '^[^|]*\b(run|then|and) +`?git commit'
  forbid_regex "$1" '\b(close|exit|kill) (this|your own|its own) (session|terminal)\b[^.]*\.$'
}

finish() {
  if (( failures > 0 )); then
    echo "$(basename "$0"): $failures failure(s)"
    exit 1
  fi
  echo "ok   $(basename "$0")"
  exit 0
}
