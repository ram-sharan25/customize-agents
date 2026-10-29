#!/usr/bin/env bash
# emacs-share folder: argument checks that need no running Emacs.
source "$(dirname "$0")/../skills/lib.sh"
share="$repo/emacs/agent-sessions/bin/emacs-share"

out=$(EMACS_AGENT_SESSION_ID=x "$share" folder bogus /tmp 2>&1); code=$?
[[ $code -eq 2 ]] || fail "folder bogus: expected exit 2, got $code"
[[ "$out" == *Usage* ]] || fail "folder bogus: no usage message: $out"

out=$(EMACS_AGENT_SESSION_ID=x "$share" folder code /no/such/dir 2>&1); code=$?
[[ $code -ne 0 ]] || fail "folder code on a missing path: expected failure"
[[ "$out" == *"no such directory"* ]] || fail "folder code on a missing path: wrong message: $out"

"$share" help | grep -q 'emacs-share folder plans|code PATH' || fail "help does not list the folder verb"
finish
