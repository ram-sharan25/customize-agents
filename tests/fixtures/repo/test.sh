#!/bin/sh
# Full suite for the toy repository.
. "$(dirname "$0")/greet.sh"
fail=0
check() { [ "$1" = "$2" ] || { echo "FAIL: expected '$2', got '$1'"; fail=1; }; }

check "$(greet Ada)" "Hello, Ada!"

[ $fail -eq 0 ] && echo "all tests passed"
exit $fail
