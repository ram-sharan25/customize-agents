#!/bin/sh
# Print a live Claude Code session's messaging address from its registry entry.
#
#   parent-address.sh [--pid PID] [--field name|session_id|tmux|cwd|status|all]
#
# Claude Code keeps ~/.claude/sessions/<pid>.json for every live session
# (verified on 2.1.308: pid, sessionId, cwd, name, nameSource, tmux,
# messagingSocketPath, status).  `name` is the address the SendMessage tool
# takes.  PID defaults to $CLAUDE_PID, which Claude exports to its Bash tool,
# so run with no arguments inside the parent to learn your own address, and
# with --pid <parent pid> inside a child to re-check the parent's current name
# (it changes if the user runs /rename there).
#
# Output is key=value lines (or the bare value with --field).  Exit 1 when
# the registry entry is missing: the session is gone or was never interactive.

set -eu

pid=${CLAUDE_PID:-}; field=all
die() { printf 'parent-address: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pid) pid=${2:-}; shift 2 ;;
    --field) field=${2:-all}; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed -e 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" 2 ;;
  esac
done

[ -n "$pid" ] || die "no pid: pass --pid or run inside a Claude Code session (\$CLAUDE_PID)" 2
file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$pid.json"
[ -r "$file" ] || die "no live Claude session registry entry at $file"

python3 -I - "$file" "$field" <<'PY'
import json, sys
path, field = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
out = {
    "name": d.get("name", ""),
    "pid": d.get("pid", ""),
    "session_id": d.get("sessionId", ""),
    "cwd": d.get("cwd", ""),
    "tmux": d.get("tmux", ""),
    "status": d.get("status", ""),
    "socket": d.get("messagingSocketPath", ""),
}
if field == "all":
    for k, v in out.items():
        print(f"{k}={v}")
elif field in out:
    print(out[field])
else:
    sys.exit(f"parent-address: unknown field {field}; one of {', '.join(out)}")
PY
