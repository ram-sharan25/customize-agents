#!/bin/sh
# Resolve (and create) the directory an exploration writes into.
#
#   explore-dir.sh --slug SLUG [--task-dir PLANS_TASK_DIR] [--root DIR] [--date YYYY-MM-DD]
#
# Prints the absolute directory on stdout; everything else goes to stderr.
#
# Layout (user decision, 2026-10-28):
#   parent is working on a Plans task  ->  <task-dir>/artifacts/<date>-<slug>/
#   otherwise, the cwd's repo has a Plans project
#                                      ->  Plans/<repo>/artifacts/explorations/<date>-<slug>/
#   otherwise                          ->  refuse (exit 3); the agent asks the user
#
# No shared Plans/explorations/ folder: Plans/AGENTS.md forbids combining
# unrelated efforts in one directory, so an untasked tangent belongs to the
# project of the repo it came from.  The repo name is the main checkout's
# basename (worktrees resolve to it), matched to a Plans project
# case-insensitively with a leading dot dropped and dots turned into dashes
# (~/.emacs.d -> emacs-d).  --root DIR or $EXPLORE_FALLBACK_ROOT override.

set -eu

PLANS_ROOT=${PLANS_ROOT:-/Users/rrimal/Stillness/Agent_Stuffs/Plans}
fallback_root=${EXPLORE_FALLBACK_ROOT:-}

slug=""; task_dir=""; root=""; date=""
usage() { sed -n '2,8p' "$0" | sed -e 's/^# \{0,1\}//' >&2; }
die() { printf 'explore-dir: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --slug) slug=${2:-}; shift 2 ;;
    --task-dir) task_dir=${2:-}; shift 2 ;;
    --root) root=${2:-}; shift 2 ;;
    --date) date=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" 2 ;;
  esac
done

[ -n "$slug" ] || { usage; die "--slug is required" 2; }
printf '%s' "$slug" | grep -Eq '^[a-z0-9][a-z0-9-]{0,47}$' ||
  die "slug must be kebab-case ([a-z0-9-], <= 48 chars): $slug" 2
[ -n "$date" ] || date=$(date +%Y-%m-%d)

if [ -n "$task_dir" ]; then
  task_dir=$(cd -- "$task_dir" 2>/dev/null && pwd -P) ||
    die "--task-dir does not exist: $task_dir"
  case "$task_dir/" in
    "$PLANS_ROOT"/*) ;;
    *) die "--task-dir must be inside the Plans workspace ($PLANS_ROOT): $task_dir" ;;
  esac
  [ -f "$task_dir/plan.org" ] || [ -f "$task_dir/requirements.org" ] ||
    die "--task-dir has no plan.org or requirements.org; is it a Plans task? $task_dir"
  base="$task_dir/artifacts"
elif [ -n "$root" ]; then
  base=$root
elif [ -n "$fallback_root" ]; then
  base=$fallback_root
else
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    die "no --task-dir given and $(pwd) is not in a git repo, so there is no
  Plans project to file this under.  Ask the user where it should go, then
  pass --root DIR." 3
  repo=$(basename -- "$(dirname -- "$common")")
  want=$(printf '%s' "$repo" | sed -e 's/^\.//' -e 's/\./-/g' | tr '[:upper:]' '[:lower:]')
  project=""
  for d in "$PLANS_ROOT"/*/; do
    name=$(basename -- "$d")
    [ "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" = "$want" ] && { project=$name; break; }
  done
  [ -n "$project" ] ||
    die "no --task-dir given and repo '$repo' has no Plans project
  ($PLANS_ROOT/$want/ does not exist).  Ask the user where it should go,
  then pass --root DIR (or --task-dir)." 3
  base="$PLANS_ROOT/$project/artifacts/explorations"
fi

dir="$base/$date-$slug"
n=2
while [ -e "$dir" ]; do
  dir="$base/$date-$slug-$n"; n=$((n + 1))
done
mkdir -p -- "$dir" || die "cannot create $dir"
printf '%s\n' "$(cd -- "$dir" && pwd -P)"
