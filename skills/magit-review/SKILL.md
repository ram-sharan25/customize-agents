---
name: magit-review
description: Participate in a local Magit code review alongside the human and the other agent. Use when asked to review a diff, respond to review comments, leave inline feedback on code, resolve or reopen review threads, or drive the human's open Magit review view. Works with Emacs running or stopped.
---

# magit-review

A shared, local code review. One human works in Magit inside Emacs; you and
the other agent take part through the `magit-review` CLI. Everyone reads and
writes the same review, and nothing is published to GitHub.

## Identify yourself

Every write records a fixed author. Use your own identity and no other:

- `pi` — Pi
- `claude-code` — Claude Code
- `Codex` — Codex
- the human's OS username — the human; never write as them

Set it once instead of passing `--author` on every call:

```sh
export MAGIT_REVIEW_AUTHOR=claude-code   # or pi, or Codex: your own identity above
```

## Output and failure

Every command prints JSON on stdout. Add `--text` when a human is reading.
Failures print a JSON object on stderr with a stable `error.code`, and exit
non-zero:

| Exit | Code             | Meaning                                              |
|------|------------------|------------------------------------------------------|
| 2    | `invalid-request`| Bad flags or arguments                                |
| 3    | `not-found`      | No such review, thread, or message                    |
| 4    | `forbidden`      | Not your message, or not a writable identity          |
| 5    | `stale-revision` | Someone else wrote first; re-read and retry           |
| 6    | `no-live-view`   | No Magit buffer is showing this review right now      |
| 7    | `review-closed`  | The review is closed; reopen it to continue           |

## Naming the review

Name a review either by its `--review ID`, or by the repository and target
it covers. Targets:

```sh
--target worktree                 # staged and unstaged together (the default)
--target staged
--target unstaged
--target revision --rev HEAD~2
--target range --range main..HEAD
--target branch --base main --head feature/x
--target pr --pr 42               # or --pr https://github.com/owner/repo/pull/42
```

`--repo PATH` picks the repository; it defaults to the working directory.

## The workflow

### 1. Join or start the review

```sh
magit-review review start --target worktree
```

This attaches to the existing review or creates it. It works with Emacs
closed — when the human later opens that diff in Magit, your comments are
already there. The result carries `review.id` and `review.revision`; keep
both.

### 2. Read what is there

```sh
magit-review review show --review "$ID"
magit-review thread list --review "$ID" --status open
magit-review thread show --review "$ID" --thread "$TID"
```

`review show` returns the whole document: target, threads, anchors,
messages, authors, timestamps, statuses. Read it before writing so your
comments respond to the current state.

### 3. Comment

Bodies are **Org syntax**, not Markdown: `=code=`, `*bold*`, `/italic/`,
`- item`, and `#+begin_src elisp ... #+end_src`. The human reads them
fontified in Emacs.

```sh
# on a line
magit-review comment add --review "$ID" \
  --file src/auth.go --line 128 --side new \
  --body 'This retries forever when the token is malformed.

A malformed token fails every attempt, so =backoff= never terminates.
Bound it, or fail fast on a 400.'

# on a range
magit-review comment add --review "$ID" --file src/auth.go \
  --line 128 --end-line 140 --side new --body '...'

# on a whole file
magit-review comment add --review "$ID" --file src/auth.go --body '...'

# on the review as a whole
magit-review comment add --review "$ID" --body '...'
```

Long bodies read better from a file or stdin:

```sh
magit-review comment add --review "$ID" --file src/auth.go --line 128 --body-file -
```

Sides: `--side new` is the post-change file (the `+` and context lines),
`--side old` is the pre-change file (the `-` lines). Line numbers are in
that side's own file coordinates, which is what the diff shows in its
gutter — not the position within the hunk.

### 4. Reply and nest

```sh
magit-review comment reply --review "$ID" --thread "$TID" --body 'Fixed in the next commit.'
magit-review comment reply --review "$ID" --thread "$TID" --parent "$MID" --body '...'
```

Without `--parent` the reply attaches to the thread root. With it, the
reply nests under that message, to any depth.

### 5. Revise your own words

You may edit and delete **only your own messages**; attempting another
author's fails with `forbidden`.

```sh
magit-review comment edit   --review "$ID" --message "$MID" --body 'Revised.'
magit-review comment delete --review "$ID" --message "$MID"
```

Deleting leaves a tombstone: the message record stays so replies keep their
parent, and only the body goes.

### 6. Resolve

Any participant may resolve or reopen any thread, whoever started it.

```sh
magit-review thread resolve --review "$ID" --thread "$TID"
magit-review thread reopen  --review "$ID" --thread "$TID"
```

Resolve a thread when the point is settled — you fixed it, or the human
agreed it needs nothing. Reply saying what you did before resolving, so the
human sees why the thread closed.

### 7. Close the review

```sh
magit-review review close  --review "$ID"
magit-review review reopen --review "$ID"
```

Closing is allowed with threads still open; nothing is discarded, and the
review stays inspectable. A closed review rejects new comments until it is
reopened.

## Driving the human's view

These work only while a Magit buffer is showing the review. Without one
they fail with `no-live-view` (exit 6) — that is normal when Emacs is
closed, not an error to work around.

```sh
magit-review view list                                     # is anyone watching?
magit-review view navigate --review "$ID" --file src/auth.go --line 128 --side new
magit-review view navigate --review "$ID" --thread "$TID"
magit-review view navigate --review "$ID" --thread "$TID" --focus   # also raise Emacs
magit-review view refresh  --review "$ID"                  # after you changed code
```

**Move the human's point sparingly.** Comments you add appear in their
buffer on their own, without disturbing cursor, folds, or scroll position.
Navigation overrides that and takes their place in the file away. Use it
when you are pointing at something you just asked them to look at, and use
`--focus` only when you genuinely need their attention in Emacs.

Call `view refresh` after you change reviewed code, so the diff regenerates
and anchors re-reconcile.

## Concurrent edits

The daemon serializes every write. If you hold a review you read a moment
ago, pass the revision you saw:

```sh
magit-review comment add --review "$ID" --if-revision 42 ...
```

Exit 5 (`stale-revision`) means someone wrote in between. Re-read with
`review show` and decide again — never retry the same write blindly, and
never pass `--if-revision` with a number you did not just read.

Omit `--if-revision` for an append that cannot conflict, such as adding a
fresh comment.

## Anchors that no longer match

When reviewed code moves, Emacs re-anchors comments on its next refresh and
records the outcome on each thread as `reconciliation.state`:

- `active` — the anchor still matches
- `stale` — it resolved, but the surrounding code changed; read it before
  trusting the line number
- `orphaned` — it could not be found at all; the thread is kept, not deleted

```sh
magit-review thread list --review "$ID" --reconciliation orphaned
```

Do not delete an orphaned thread. Say in a reply that the code moved, and
let the human re-anchor or resolve it.

## Working etiquette

- Read before writing: another participant may have answered already.
- One thread per point. Reply in an existing thread rather than opening a
  second one about the same line.
- Anchor as tightly as the point allows — a line beats a file, a file beats
  the review.
- Say what would change, not just what is wrong.
- Never write as the human or as the other agent.
- Never publish any of this to GitHub. A pull-request review here reads the
  PR's diff and keeps the discussion local.

## Housekeeping

```sh
magit-review review list --all --text
magit-review daemon status --text
magit-review skill path
```

The daemon starts on first need and stops on its own after an idle period.
Review documents are plain JSON under `~/.local/share/magit-review/reviews/`
and can be read directly when you need to inspect state without the CLI.
