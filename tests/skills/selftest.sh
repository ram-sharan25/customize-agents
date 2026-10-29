#!/usr/bin/env bash
# Checks the assertion helpers themselves.
source "$(dirname "$0")/lib.sh"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf 'alpha\n* Heading\n' > "$tmp"

expect_fail() { if ( "$@" ) >/dev/null 2>&1; then fail "expected failure: $*"; fi; }

require_text "$tmp" "alpha"
expect_fail require_text "$tmp" "missing"
forbid_text "$tmp" "missing"
expect_fail forbid_text "$tmp" "alpha"
require_heading "$tmp" "* Heading"
expect_fail require_heading "$tmp" "* Other"

finish
