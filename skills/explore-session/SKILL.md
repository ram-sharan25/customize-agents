---
name: explore-session
description: >-
  Spin a tangent off into a separate agent session in a new tmux window, and
  later bring its findings back without polluting this conversation. Use when
  the user says "open a new session to explore/understand/learn this", "spin
  this off", "look into this on the side", "fork this into a new session";
  when the user in a child exploration session says "report back", "return
  the findings to the parent", "send it to the parent"; and when the user in
  the parent says "bring in the exploration", "go ahead and bring it in",
  "pull in the findings". Claude Code and Pi; needs tmux.
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/explore-dir.sh *) Bash(${CLAUDE_SKILL_DIR}/scripts/open-window.sh *) Bash(${CLAUDE_SKILL_DIR}/scripts/parent-address.sh *) Bash(tmux show-option *) Bash(tmux display-message *) Bash(emacs-share file *)
---

# explore-session

One tangent, one child session, one new tmux window in the **same** tmux
session. The child starts from a **curated brief** (topic, minimal context,
file pointers), not from this transcript. A full-context fork happens only
when the user explicitly says "fork". Findings live in files; the parent gets
a one-line notice first and reads a 12-line summary only when told to.
No database: tmux plus each agent's own features. When the parent runs in a
terminal the Emacs agent-sessions dashboard opened, the child is tracked
there too (see Mechanics); when it does not, nothing changes.

Scripts live in `${CLAUDE_SKILL_DIR}/scripts/` (Claude substitutes that; in
Pi it is the directory of this file, `~/.pi/agent/skills/explore-session`, and
the Pi extension `explore-session.ts` calls the scripts for you).

## Which role am I in?

- `EXPLORE_SLUG` / `EXPLORE_DIR` / `EXPLORE_PARENT_*` set in the environment,
  or your first prompt was an "Exploration brief" → you are a **child**.
- Otherwise you are a **parent** (or a plain session).

## A. Open an exploration (parent)

Default mode is a brief. Use `--fork` only if the user said "fork".

**In Pi:** call the `open_exploration_session` tool (topic, goal, context,
files, optional slug / task_dir / fork / focus / start_now). It does steps
1–4 below. Then do step 5.

**In Claude Code:**

1. Pick a kebab-case slug (≤ 48 chars, from the topic).
2. Decide where it lives. If this conversation is about a task under
   `/Users/rrimal/Stillness/Agent_Stuffs/Plans/<project>/<task>/` (plan.org /
   requirements.org in play, or cwd inside it), pass that directory:
   ```
   DIR=$(${CLAUDE_SKILL_DIR}/scripts/explore-dir.sh --slug <slug> --task-dir <that dir>)
   ```
   Otherwise run it without `--task-dir`: it files the exploration under the
   cwd repo's Plans project (`Plans/<repo>/artifacts/explorations/`). If it
   exits 3 (not in a repo, or the repo has no Plans project), relay its
   message to the user, ask where it should go, and rerun with `--root DIR`
   (do not pick a directory yourself). In Pi, pass that as the tool's `root`.
3. Write `$DIR/brief.md` from `${CLAUDE_SKILL_DIR}/brief-template.md`, filling
   every `{{…}}`:
   - `parent_agent`: `claude`.
   - `parent_address`: run `${CLAUDE_SKILL_DIR}/scripts/parent-address.sh` and
     write `session name <name>, pid <pid>, session id <session_id>`.
   - `parent_tmux`: the `tmux` value from the same output.
   - `topic`, `goal`: in the user's words, one short paragraph each.
   - `context`: at most 10 lines of pointers and facts the child cannot get
     from the files. Never paste transcript, tool output, or file contents.
   - `files`: absolute paths, with line ranges or symbols when you know them.
   - `constraints`: bullets, or `- none beyond the shared rules`.
   - `dir`: `$DIR`; `slug`: the slug.
   - `report_instruction`:
     `Use the SendMessage tool with to = the parent's session name. Re-check the name first: ${CLAUDE_SKILL_DIR}/scripts/parent-address.sh --pid <parent pid> --field name (the user may have run /rename in the parent).`
   - `start`: `Acknowledge this brief in at most two lines and wait for the user.`
     or, when the user asked the child to start on something right away,
     `Start now: <task>. Report progress to the user here, not to the parent.`
4. Open the window:
   ```
   ${CLAUDE_SKILL_DIR}/scripts/open-window.sh --agent claude --slug <slug> --dir "$DIR" [--fork] [--no-focus]
   ```
   It refuses (exit 2) when this session is not inside tmux; tell the user
   and do nothing else. Its `via:` line says whether Emacs or plain tmux
   opened the window; a note on stderr explains a fallback. Either is fine.
5. Reply in two or three lines: the window index/name, `$DIR`, and that you
   will keep working here. Do not read the brief back. Do not watch the child.

## B. Report back (child; only when the user says so)

1. Write or refresh `$EXPLORE_DIR/findings.md` (any length).
2. Write `$EXPLORE_DIR/summary.md`, at most 12 lines, in the format from your
   brief (`# Exploration summary: <slug>`, `What:`, `Where:` with absolute
   paths, `Open:`). Conclusion first; no pasted contents.
3. Send the parent **exactly one line**:
   `exploration <slug> done — ready to bring in (<EXPLORE_DIR>)`
   - Claude: `SendMessage` with `to` = the parent's current session name
     (`parent-address.sh --pid $EXPLORE_PARENT_PID --field name`).
   - Pi: call the `report_to_parent` tool (it checks `summary.md` exists,
     sends the line over the parent's inbox socket, and leaves a copy in the
     inbox directory if the parent is unreachable).
4. If `EMACS_AGENT_SESSION_ID` is set in your environment (Emacs opened this
   window), also hand the files to the dashboard:
   ```
   emacs-share file "$EXPLORE_DIR/findings.md" "exploration <slug>: findings"
   emacs-share file --to "$EMACS_AGENT_PARENT" "$EXPLORE_DIR/summary.md" "exploration <slug>: ready to bring in"
   ```
   `findings.md` lands under your own row; `summary.md` under the parent's,
   highlighted until the user opens it. If either command fails, tell the
   user in one line and carry on; the notice above already went out.
5. Tell the user it was sent. Stay here; the user may continue with you.

## C. Bring in (parent; only when the user says so)

1. Find the directory: it is in the notice line. If several explorations are
   pending, list them with
   `tmux show-option -wqv -t "$TMUX_PANE" @explore-children` (entries are
   `@window=slug`) and ask which one.
2. Read **only** `<dir>/summary.md`. Do not read `findings.md` or the other
   files unless the user asks for a specific one.
3. Relay the summary as-is (≤ 12 lines), then continue the original work.
   Anything under `Open:` is a pending decision for the user; keep it visible.

## When a notice arrives (parent)

A line `exploration <slug> done — ready to bring in (<dir>)` arrives as a
cross-session message (Claude) or a custom message (Pi). Reply with one line,
e.g. "Noted — say *bring in <slug>* when you want the summary." Do not open
any file and do not summarize anything yet.

## Mechanics worth knowing

- Same tmux session: `open-window.sh` identifies this pane through
  `$TMUX_PANE` and runs `tmux new-window -t "=<session>:"`. The new window is
  focused by default; `--no-focus` leaves you here.
- The child's first prompt is the brief (`claude -n explore-<slug> "$(cat
  brief.md)"`, `pi -n … "$(cat brief.md)"`); the window keeps a login shell
  after the agent exits. The brief file stays on disk as the record of what
  the child was told.
- Fork mode: Claude `claude --resume <parent id> --fork-session` (parent
  untouched; costs the parent's whole live context as a cache write; permission
  grants are not inherited). Pi: the extension copies the current branch to a
  new session file (`parentSession` header) and starts `pi --session <file>`.
- Window options `@explore-parent`, `@explore-dir`, `@explore-slug`,
  `@explore-agent` on the child and `@explore-children` on the parent link
  the two without any database.
- Emacs, when it owns the parent: a parent terminal that the agent-sessions
  dashboard opened has `EMACS_AGENT_SESSION_ID`, and `open-window.sh` then
  asks Emacs (`rsr/agent-sessions-explore-spawn`) to open the window instead
  of running `tmux new-window` itself. The child gets its own tracked id
  (hooks, session log, restore, `emacs-share`), a row titled
  `explore: <slug>` nested under the parent, `brief.md` attached to it, and
  `EMACS_AGENT_PARENT` (the parent's terminal id) for step B.4. Same command
  and environment as the plain path; `--no-focus` additionally leaves the
  parent's window selected. Any failure falls back to plain tmux. The one-line
  notice stays native (SendMessage / Pi socket) on purpose: `emacs-agent`
  mail would paste the same line into the parent's composer a second time.
  If that is ever wanted, it is one more line in B.3:
  `emacs-agent send --to "$EMACS_AGENT_PARENT" --type done --subject "exploration <slug>" --files "$EXPLORE_DIR/summary.md"`.
- Codex: deferred. `open-window.sh` has the extension point (`child_command`);
  the return path would be `codex queue --thread <parent> --message "<notice>"`.
