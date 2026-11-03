#!/bin/sh
# Forwards Antigravity CLI (agy) hook events to rsr/agent-hook-notify via
# emacsclient.  Wired into ~/.gemini/config/hooks.json by
# `rsr/agent-sessions-install', one entry per event with the event name as $1:
# agy's payload does not name its event, and its keys are camelCase, so the
# name is added here as `hook_event_name' for the shared notify path.  Gated
# on EMACS_AGENT_SESSION_ID like the Claude forwarder.
#
# agy runs hooks synchronously and reads a JSON answer from stdout, so this
# answers first ("no opinion") and hands Emacs the payload without waiting.
event=${1:-unknown}
case "$event" in
  Stop) printf '{"decision":""}\n' ;;
  *) printf '{}\n' ;;
esac
payload=$(cat)
case "$payload" in
  *'{'*) ;;
  *) exit 0 ;;
esac
if [ -z "$EMACS_AGENT_SESSION_ID" ] || ! command -v emacsclient >/dev/null 2>&1; then
  exit 0
fi
emacs_hook_payload_file=$(mktemp "${TMPDIR:-/tmp}/emacs-agent-hook.XXXXXX")
# Splice the event name in as the object's first key (no comma before an
# empty object's closing brace).
rest=${payload#*\{}
case "$(printf '%s' "$rest" | tr -d ' \t\n')" in
  '}'*) sep="" ;;
  *) sep="," ;;
esac
printf '{"hook_event_name":"%s"%s%s' "$event" "$sep" "$rest" > "$emacs_hook_payload_file"
emacsclient --no-wait -e "(rsr/agent-hook-notify \"${EMACS_AGENT_SESSION_ID}\" \"agy\" \"${emacs_hook_payload_file}\")" >/dev/null 2>&1 \
  || rm -f "$emacs_hook_payload_file"
exit 0
