# agent-sessions — design notes

A dashboard for Claude Code / Codex sessions running in terminal buffers. The
code says *what* it does; this file records *why*, so the intent survives edits.

## Orientation (just enough to navigate)

- `agent-sessions.el` — everything; `agent-sessions-codex-hook.sh` — Codex event
  forwarder. The Claude forwarder lives outside the repo
  (`~/.orca/agent-hooks/claude-hook.sh`, wired via `~/.claude/settings.json`).
  Pi needs neither: its extension is TypeScript in-process, so
  `agent-sessions-pi-hook.ts` is the forwarder itself, copied into
  `~/.pi/agent/extensions/` by `rsr/agent-sessions-install`.
- `bin/` — commands agents run *inside* a session terminal: `emacs-share`
  (see "Shared files") and `emacs-agent` (see "Orchestration"). On every session
  terminal's PATH.
- `agent-workflow.el` — the planning workflow's keys (see "Workflow keys").
- `bin/agent-launch` — the core launcher (see "Workflow keys").
- `skills/orca/` — the `/orca` skill an agent loads to learn orchestration, and
  the two guides `emacs-agent guide` serves.
- `orchestration/` — notes on how *Orca* (the app) does the same thing; read
  before redesigning this, not as a description of what is here.
- Wiring/config is in `../agent-session-config.el`.

## Live Emacs safety

**Never kill, signal, restart, or force-quit the user's Emacs process or server.**
This includes sending `SIGINT` to interrupt a hung diagnostic. If an
`emacsclient` call hangs, stop only that client invocation or leave it alone;
do not target the Emacs process with `kill`, `pkill`, or `killall`. Stop live
diagnostics and tell the user if the server is unresponsive. Continue with
isolated batch Emacs tests where possible, leaving the user's live sessions
untouched.

## Why it's built this way

**Zero-friction tracking beats an explicit launcher.** Rather than a wrapper
command you must remember to use, every terminal buffer gets a unique id
injected into its shell env, so *any* `claude`/`codex` you type in *any*
eat/vterm is tracked automatically. The cost is that we advise the terminal
packages' internals — accepted deliberately in exchange for never having to
think about launching sessions specially.

**A tmux agent is represented by a proxy buffer.** With the `tmux` backend an
agent runs in a window of its repository's tmux session, so it can be watched
from Emacs, Ghostty or nowhere; it has no Emacs terminal buffer of its own. It
gets a stand-in buffer (`rsr/agent-tmux-mode`, agent-sessions-tmux.el) instead,
because everything here keys on a buffer: identity, buffer-local state, hook
routing, rows, cleanup, the log. Re-keying all of that on a "terminal handle"
would touch most of the file; a proxy confines tmux to the terminal layer
(open, I/O, running command, screen, jump, liveness). Consequences worth
knowing: the injected environment goes through `env` in the window's command,
because tmux replaces a `new-window -e PATH=` with the client's PATH; liveness
is read once per render (`list-panes`) and dead proxies are killed just after
it, never inside it; and the composer checks read the window with
`capture-pane -e`, turning faint runs into a face so inline completions still
read as not-a-draft.

**The per-buffer id is the identity, not the agent's own session id.** Sessions
sharing a worktree must still resolve to the right buffer, and the agent's own
UUID isn't known until a hook fires (and isn't in every payload). So the stable
key is the injected `EMACS_AGENT_SESSION_ID`; the agent's UUID is tracked
separately, only for resume/branch/links.

**The dashboard is ephemeral; the record of what happened is not.** Rows are
rebuilt from live buffers on every render and nothing on disk feeds them —
that is what stops a dead session ever being displayed as alive, which was the
original point of the rule. What *is* persisted lives in one SQLite file
(`rsr/agent-sessions-db-file`), and the bar for adding to it is that it must be
either something the user chose, or something they cannot reconstruct once it
is gone:

- **notes** (`e`) and **manual order** (`M-n`/`M-p`) — things the user wrote or
  arranged by hand; evaporating on restart would make them useless.
- **the session log** — observed session state, which the rule above would
  otherwise forbid. It earns its place because a session id is the one thing
  you cannot get back after a crash, and because it records endings as
  faithfully as beginnings. A log that knows a session died isn't lying about
  it; it is the only way `R` and `rsr/agent-sessions-restore-previous` can offer
  it back. What would break the rule is letting it populate rows.

One store, not three files, because the log forced the issue: it is
append-heavy, queried by recency, and unbounded, so the old rewrite-the-file
approach didn't fit it — and once a database existed, a second and third
persistence format was pure cost. Notes and order are still read through their
hash tables; **the render path must never query the database.** Load once,
write on change.

Two consequences of persisting things keyed by identity: a note keyed on a
session id outlives the session that had it (nothing prunes it — a stale row
is invisible and cheap, and guessing that a session is gone *for good* is
exactly the kind of lying the ephemerality rule exists to avoid), and note
keys are type-tagged (`("repo" …)` vs `("worktree" …)`) because a repo's main
worktree has the same canonical path as the repo itself and would otherwise
share its note. The order table carries the same tag as `kind`, and its scope
columns default to `''` rather than `NULL` — SQLite treats `NULL`s as distinct
under a primary key, so a `NULL` scope would silently turn every upsert into a
duplicate insert.

**A session that reports under a Claude event name rides every existing path.**
Pi has no hooks.json — extensions are whole files — so its forwarder translates
its own events (`agent_end` → `Stop`, `before_agent_start` → `UserPromptSubmit`,
`session_shutdown` → `SessionEnd`) into the vocabulary the status table already
keys on, and delivers them through the same `rsr/agent-hook-notify` channel. That
is why `rsr/agent-session-status-alist` grows a two-line `pi` entry instead of a
parallel pipeline: an agent that speaks the common event language gets attention
tracking, the session log, and restore for free, and cannot drift out of sync
with them. What pi deliberately does not get: fork parentage (Claude-only,
transcript-based) and native queueing (no known-safe composer moment, so
mail to a pi agent stays unread for `emacs-agent wait`).

**How a session ended is inferred from which hook fired, not from a flag.**
Emacs runs `kill-emacs-hook` on exit but does *not* run `kill-buffer-hook` for
live buffers at that point (verified, not assumed). That asymmetry is the whole
scheme, and it is why `k` needs no special case: it is a plain `kill-buffer`,
so it and `C-x k` land in the same place.

| ending | what fired | means |
|---|---|---|
| `killed` | `kill-buffer-hook` | you closed it |
| `agent-exit` | `SessionEnd` | agent quit, terminal lives on |
| `superseded` | a new agent id in the same terminal | previous one ended unheard |
| `emacs-exit` | `kill-emacs-hook` | Emacs quit with it running |
| `crash` | nothing — found open at the next startup | Emacs died |

restore-previous offers only the last two ("it was taken from you"), as one
batch. `R` lists every ended session and shows the ending as a note, so the
reason never hides a session from it.

**The `R` picker shows what a session was about, from what is already keyed
to it.** The log only has a worktree label and the agent's last title, which
is missing for an unused session and repeated for workflow stages
(`plan-implementation`). So each line adds the workflow state and the start of
the agent session id, and the annotation the Plans folder, code folders and
note — all read through the same `--session-note-keys` lookups the dashboard
uses, with a stand-in session holding just the agent id. The id is not
decoration: the picker looks the choice up by the line's text, and before it
was there two sessions with the same label and title collapsed into one line,
leaving the other unreachable. A session with nothing to resume is dimmed, not
hidden, so the list still accounts for everything the log knows. The list is
unfiltered; `C-c C-r` inside it narrows to one repo and widens again, an opt-in
lens rather than a default that hides sessions. The table declares an identity
sort, or a completion UI sorting by history or length would undo newest-first. A
`t` rename is written to the log at once (`--log-title`) rather than at the
next hook, so a session renamed and closed straight away keeps its new name;
the agent's own title changes still wait for a hook, because they include a
spinner that would otherwise write on every frame. **Crash detection asks whether the owning Emacs is
still running.** A row left open belongs to a dead Emacs only if the pid at the
front of its terminal id (`PID-COUNTER`) no longer names a running Emacs. The
first version assumed a single Emacs and reaped every open row, and a second
Emacs did open the file: a batch test run, from one test that wrote to the
real log. Every such run closed the live Emacs's sessions as `crash`. Their
terminals never reopen a closed row, so those sessions dropped out of the log
for good. restore-previous later missed them, and killing one could no longer
be recorded, so `R` offered sessions back that had been closed by hand. The
check costs one `process-attributes` per open Emacs, still with no instances
table. Because a crash runs no code, close *times* come from a periodic
heartbeat in `meta` — the last moment Emacs is known to have been alive.

**A reorder writes two rows, not the group.** `M-n`/`M-p` are adjacent
transpositions, and `--merge-order` turns one into a list differing from the
saved one in exactly two slots, so `--order-write-group` diffs old against new
and upserts only what moved. Positions stay contiguous forever without
renumbering, because a transposition preserves the *set* of positions and only
exchanges which member holds which. Note what this depends on: if a
"move to top" or drag-to-position operation is ever added, arbitrary placement
between two neighbours is where gap or fractional positions start to earn their
keep — `position` can become `REAL` without touching the read path.

**Hooks are unordered and untrusted for sequencing.** Hook invocations are
independent async processes with no delivery-order guarantee, so an
informational event can land *after* a `Stop`. The status map therefore only
promotes known events and leaves everything else untouched — status must never
be clobbered back to "running" by a straggler. This is the single most
important invariant when editing the status logic.

**`running` means mid-turn, and two guards keep it that way.**
`SessionStart` maps to `stopped` for pi and Claude — both fire it when the TUI
opens at an idle prompt (Claude also on `--resume`), so without the mapping a
fresh session fell through to the `running` default in `rsr/agent-hook-notify`
and read as mid-turn while sitting at its prompt. Codex deliberately gets no
mapping: its `SessionStart` fires lazily on the first prompt, in the same
instant as `UserPromptSubmit`, so mapping it could clobber `running` under
unordered delivery. The other hole is an agent killed mid-turn — no shutdown
hook fires, so the status freezes at `running` forever.
`rsr/agent-sessions--reconcile-status` demotes that to `stopped` at display
time when the terminal can name a foreground group (`tpgid` present in
`process-attributes`) and the group is empty — the shell then owns the pty, so
no turn can be in progress. An idle pi still holds the foreground with its
TUI, which is why the SessionStart mapping exists at all. Demotion is
display-time only, on a copy, exactly like the unread mark — the registry
stays the hook's record.

**Notifications fire on the transition into attention, once.** A session that
sits waiting must not re-announce on every subsequent event. If you add states,
preserve "edge-triggered, not level-triggered."

**The manual unread mark (`u`) rides on the buffer, not on the status.** It
makes a row *look* like needs-attention (face, marker, sort bucket, `N`/`P`)
without ever being written into the registry, for three reasons: a plain
terminal that no hook has fired for has no registry entry to write to; hook
status computation falls back to the *previous* status for informational
events, so a written-in `needs-attention` would outlive the thing the user
wanted to be reminded of; and inventing a registry entry for a bare terminal
would suppress fork auto-detection, which is guarded on the session being new.
So the flag is buffer-local and applied at display time on a *copy* of the
plist — never mutate the registry entry from the render path. It clears the
same way a real one does, by focusing the session, and is deliberately not
persisted: it's session state, which by the rule above evaporates on restart.

**A row with no registry entry names whatever is running, from the kernel.**
Hooks can't be relied on to say what a terminal is running, because Codex
creates its session *lazily*: its `SessionStart` fires on the first prompt
submission, in the same instant as `UserPromptSubmit`, not when the process
starts (measured, not assumed — a fresh Codex TUI sat drawn at its prompt for
~90s emitting nothing, and wrote no rollout file either, so watching
`~/.codex/sessions` is the same dead end). Claude fires `SessionStart` on
`--resume`, so before this, a batch of restored sessions left every Codex row
reading `eat` while the Claude rows read `claude`.

`rsr/agent-sessions--foreground-command` instead asks the pty for its
*foreground process group* (`tpgid` from `process-attributes`) and names that
job. Why this shape:

- **It generalises past the two agents.** Any command shows its own name, and
  the label returns to the backend when it exits, with no state to keep in
  sync. A python REPL reads `Python`; `sleep 40` reads `sleep`.
- **It is self-correcting, which a launch-time tag is not.** The first attempt
  here stamped the agent onto the buffer at spawn; a terminal where Codex had
  since been replaced by Claude kept the stale label, and no amount of care in
  the spawn path fixes that class of bug.
- **`args`, never `comm`.** Claude's executable lives in a version-numbered
  directory, so its `comm` reads `2.1.231`.
- **No subprocess.** `process-attributes` is a kernel read, not a `ps` fork —
  which is what makes this affordable at all.
- **Cached exactly, never on a timer.** Uncached this took a warm hook-tick
  refresh from 23ms to 41ms — nearly double, exactly the hot-path cost the git
  note below exists to prevent. Reading the *command line* is the expensive
  half, so the name is cached and reused while `tpgid` is unchanged: an exact
  test, not a heuristic, since the same foreground group is the same job. That
  alone brings it to ~+3ms. A 0.3s time-based layer on top was tried and
  **removed**: it saved only the remaining ~3.6ms of group reads (12 terminals
  × one kernel read; `--live-entries` runs once per render, so there is no
  duplicate work to collapse) and paid for it with a label up to a third of a
  second stale. For a display whose purpose is showing what is running now,
  that is the wrong trade — and `g` already costs ~1.4s, so this was never the
  expensive thing on the path. If this ever does need to be cheaper, cut the
  number of rows or the refresh rate, not the freshness.

`:status` stays `idle` for these rows rather than being promoted to `running`:
knowing a process holds the terminal says nothing about whether the agent is
working or waiting, and inventing that is the kind of lying the rules here
exist to prevent. Registry rows are untouched — a hook that has reported
carries its agent type *and* real status, which the process table cannot give
once the process is gone.

The corollary, learned the hard way: **a row's status is whatever was
rendered, so nothing may re-derive it from the registry.** `N`/`P` did exactly
that (`gethash` on `rsr/agent-sessions`) and so navigated past every row `u` had
marked, while the face, marker and sort bucket — all fed by `--live-entries`,
which applies the overlay — agreed the row needed attention. The render now
records `(line-pos . status)` into `rsr/agent-sessions--row-status` as it draws,
and navigation reads that. Any future consumer of "what state is this row in"
belongs on that list, not on a second lookup.

**Row order must not depend on anything that changes while a session runs.**
The dashboard re-renders on *every* hook event, so ordering by `:updated-at`
made two concurrently busy sessions swap places several times a second — the
row you were aiming at moved out from under point. The default order therefore
uses only keys that are stable under activity: a coarse attention bucket
(error → needs-attention → running → rest), then buffer creation time, then
buffer name as a deterministic final tie-break (hash iteration order must never
leak into the layout). A row *does* move when its status changes — that's a
rare, meaningful event, unlike a tool call. Repos and worktrees are alphabetical.
Folder view rows start with a dynamically sized worktree column. Recency sort
survives behind `s`
for when you want it; don't make it the default again.

**Manual order overrides the automatic one per group, and only per group.**
`M-n`/`M-p` move the repo, worktree, folder, or row at point within its siblings and
persist that group's key list. Design points worth keeping: items with no
recorded key keep the automatic order and sort *after* the placed ones, so a new
session never displaces a slot the user chose; rewriting a group splices the
visible keys back into the saved list instead of replacing it, so a repo or
session whose terminal is closed doesn't lose its remembered slot; and
keys are stable identities (canonical paths, buffer name for a row) rather than
display labels, which change on a branch checkout. Reordering acts on the flat
per-repo list that `--insert-entries` then nests, so moving a *fork* row
past a sibling of its parent's group may not visibly move it — the nesting wins.
Manual order is disabled while `s` (recency) is active; those two orderings
would fight, and recency should stay a temporary lens.

**Folders belong to repos.** The default view is repo → worktree → session, with
the session's folder shown on its row. `f` gives repo → folder → session,
including a No folder group under each repo. Folder view rows put the worktree
name first and the branch after the title; the non-folder view has neither on
session rows because its worktree heading provides that context. `Shift+TAB`
advances one
hierarchy level at a time: repos, folders or worktrees, sessions, then files
and links. At the deepest level it cycles back to repos only. The cycle skips
absent levels and survives a dashboard refresh.
Manual TAB expansion of an individual section also survives refresh: Magit's
visibility cache records it, so a hook-driven render must not reapply the
global Shift+TAB level over those individual choices.
`F` on a row moves it to a folder in that repo and creates an unmatched name.
`F` on a folder heading renames or deletes that repo's folder. Folder names may
repeat in different repos. SQLite schema version 3 migrates the old global
assignments using the session log's repo root, splitting a global folder when
its members belong to multiple repos. A legacy assignment with no logged repo
is claimed by its repo when that session next appears.
A fork (`b`, or an auto-detected one) starts in its parent's folder. The parent's
folder is copied onto the child's terminal at its first hook, the same moment
parentage is decided, and is then persisted like any other folder choice. It is
a default, not a rule: it never overrides a folder already chosen for the
terminal, never crosses repos, and is not re-applied later, so moving the child
out of the folder sticks.

**A stray key closes the dispatch menu instead of trapping you in it.** `RET`
on a repo/worktree heading opens project.el's switch menu, whose own
`project--switch-project-command` loops until it reads a key it recognises —
fine when you deliberately invoked `project-switch-project`, wrong here, where
`RET` is a glance at what's available and every *other* dashboard key is a
one-shot action. `rsr/agent-sessions--switch-project` therefore swaps in a
one-shot reader (returning `ignore` for unknown input) via `cl-letf`, scoped to
that single call so the looping behaviour survives everywhere else. Build the
keymap and prompt from project.el's own `project-switch-commands` /
`project-prefix-map` / `project--menu-prompt` rather than a private list, so a
user's customised menu keeps working.

**A note follows the most durable identity its subject has.** Repos and
worktrees are keyed by canonical path, as above, but a *session* prefers the
agent's own session id and falls back to the buffer name only for a plain
terminal that has no id yet — otherwise renaming a terminal (which the `t`
title flow encourages) would silently orphan its note. Both keys are read, and
writing collapses them to the preferred one, so a note typed into a bare
terminal survives `claude` starting inside it.

**Re-rendering has to re-apply fold state itself.** Notes render as their own
magit subsection (first line as heading, rest as body) so `TAB` collapses a
long one. Magit caches visibility per section identity and revives it into the
new sections' `hidden` slots, but nothing applies it to the freshly inserted
*text* — `magit-refresh-buffer` does that with a `magit-section-show` pass over
the root, and since this dashboard erases and rebuilds by hand it must do the
same. Without that pass a folded note silently springs open on the next hook
event.

**Re-rendering is on the hot path, so git is cached aggressively.**
`magit-list-worktrees` and repo-info each spawn git subprocesses; doing that per
refresh made trivial actions (sorting, a hook tick) slow. Hence the worktree /
repo-info / transcript-uuid caches. The tension is freshness vs. speed: the
internal refresh trusts the caches; only `g` re-reads git from disk. Keep new
per-refresh work off the git path.

## Orchestration — an agent spawning and talking to other agents

`bin/emacs-agent` lets an agent start another agent in another worktree and
block until it reports. Its verbs are spawn, send, send-and-wait, done, ask,
check, wait, list, and worktrees. It reaches Emacs the way `emacs-share`
does, and returns its failures as the printed value for the same reason.

**Emacs owns only what an agent cannot do for itself.** There are no task rows,
no dependency graph and no scheduler, and adding them is the obvious wrong turn.
The orchestrator is an agent with a context window; that context *is* the plan,
and a second copy in a table would be a second thing to keep honest — with the
table losing, because only the agent knows why it changed its mind. What is left
is the part an agent genuinely cannot do: start a terminal, address a live one,
and wait for it.

**Several workers may share a worktree, and nothing here stops them.** The
constraint is not one agent per checkout — parallel readers (research, review,
audit) writing findings to separate files want the *same* tree, and a checkout
each would be overhead that also gives each a different view of a dirty tree.
What actually collides is concurrent writes to one file, and git state: the
index and HEAD belong to the worktree, so a co-tenant running `git add` stages
everyone's half-finished edits. So `spawn` deliberately has no exclusivity
check — adding one would forbid the cheapest useful case — and the rule lives
where it can be stated with its exception: the launch preamble tells every
worker to touch only the files its task names and to leave git alone unless the
task says the worktree is its own, and the coordinator guide tells the
orchestrator to say which of those it is.  `emacs-agent worktrees` reports the
count of agents in each worktree rather than free/busy for the same reason: the
caller needs the facts, not our verdict on whether it may work there.

**A worker learns who it is from its environment, not from its launch command.**
The id a worker is addressed by is minted inside the vterm/eat advice that
builds its environment, so at the moment we assemble the command there is no id
to write into it. Hence `rsr/agent-sessions--extra-terminal-env`, bound around
the create call: role, coordinator and brief path ride in alongside
`EMACS_AGENT_SESSION_ID`, and `emacs-agent` reads them so the worker never has
to be told its own name.

**The task is passed at launch, as a file the shell reads.** `claude "$(cat
BRIEF)"` rather than starting the agent and sending the task afterwards: a TUI
that is still booting silently drops input, and a two-kilobyte multi-line prompt
as one quoted argument is exactly the line a TUI mangles. The brief file is kept
after launch — it is the only record of what a worker was actually told, and
re-running that one line reproduces the launch by hand.

**A model is a hole in the launch command, not another agent type.** Before
`--model`, running a worker on a different model meant the human adding a whole
type to `rsr/agent-orchestration-launch-commands` (`claude-opus`, `claude-haiku`,
…), which multiplies types by models and hides a per-spawn choice in a config
file. So the template grew placeholders — `%b` for the brief, `%m` for the model
flag — and a second alist says how each type *spells* that flag. Two knobs
rather than one because the two facts are independent: how to start an agent, and
what that agent calls the option. A type absent from the flag alist takes no
model and a spawn naming one is refused, rather than being launched with a
guessed flag: an unknown CLI rejecting `--model` exits on its usage message, and
what the orchestrator would see is a worker that never reports — the failure
this whole path is built to avoid. Model *names* are not validated for the same
reason a list of them would be wrong within a release; the spawn line echoes the
model instead, so a worker that dies at launch has a spelling to check. Old
single-`%s` templates still render, since `format-spec` is only reached when the
template actually uses the new placeholders.

**Spawning restores the window configuration.** `+` showing its new terminal is
right because the user asked for it; three background spawns rearranging the
layout the user is reading is not. Same `save-window-excursion` the restore path
uses, for the same reason.

**Mail is persisted, and keyed by durable identity — not by the address it was
sent to.** Unread mail is exactly what the persistence rule above is for: the
recipient cannot reconstruct a message it never saw, and a crash between a
worker reporting and its coordinator reading would otherwise lose the report
silently. A caller may address mail by current terminal id, raw agent session
id, or a complete `agent-session:' link. Resolution turns each form into the
current terminal or the metadata needed to revive the conversation; the record
then files the message under the same identity a note or shared file uses: the
agent's own session id, falling back to the terminal id. That fallback is
deliberately not the buffer name that notes fall back to — a name is reused by a
later terminal, and inheriting a stranger's unread mail (which is then *pasted
into its prompt*) is a different order of wrong than inheriting a stale note.
Mail under a terminal key therefore never survives a restart, which is correct:
nothing can resume a bare shell.

So there are two structures, and they answer different questions. The hash table
is the working copy, keyed the way mail is addressed, and it is what the render
path reads — the render path must never query the database. The `mail` table is
the record; `rsr/agent-orchestration--hydrate` copies unread rows into the working
copy at the two moments a session's durable identity becomes known: a hook event
(which is also how a session restored with `R` gets its mail back, attached to
the conversation rather than to the terminal that used to hold it) and an
explicit inbox read. Hydration is idempotent by message id, and ids carry the
minting Emacs's pid so a restored message cannot collide with a new one. Reads
write `read_at` through, or a restart would redeliver mail the agent has already
acted on. A killed terminal drops its working copy in
`rsr/agent-session--cleanup`, never the record.

One consequence worth stating: a message can outlive the terminal that sent it,
so the sender is resolved through its durable key at display time. The reply
command names the durable agent session id when one exists, whether or not its
terminal is currently live; only mail from a bare terminal falls back to an
ephemeral address and becomes unreplyable when that terminal dies.

**A durable or killed address revives its conversation on the next send.** A
raw session id is resolved from the live registry and then the session log; a
full `agent-session:' link is self-contained even when the log lacks a row. An
old terminal id falls back to the newest resumable session logged under it. Each
path first follows the durable agent-session key to an already-restored terminal,
avoiding a duplicate; otherwise it resumes the conversation and supplies the
formatted mail as the CLI's initial prompt. Passing the prompt at launch is what
makes this reliable for Codex, whose first hook does not fire until its first
prompt. The message is persisted and marked read because launch itself delivered
it, and the send result names the replacement terminal id. Revival also installs
the sender as the new terminal's coordinator and parent, including the worker
environment, so the dashboard nests the revived session under the agent that
brought it back. A bare terminal has no agent-session key and therefore remains
unaddressable after death.

**Waiting polls from the shell, not from Emacs.** An emacsclient call runs on
Emacs's only thread, so a blocking wait inside Emacs would freeze the editor for
its whole duration — which for this feature is minutes. `emacs-agent wait` loops
over cheap `check` calls instead.  A wait reads and consumes every message; its
type filter only decides whether a batch ends the wait.  This distinction lets a
coordinator see progress without stale `status' mail accumulating, while it
continues polling until an actionable message arrives.  Emacs snapshots,
classifies and consumes the batch in one call, avoiding the race where a
terminal message arrives between a peek for matching types and a separate
consume-all call.  The actionable filter includes `answer' because follow-up
work after a worker's lifecycle `done' replies with that type.

`send-and-wait' composes the existing shell-side send and poll operations.  It
defaults to the common conversational pair — outgoing `question', incoming
`answer' — while preserving their independent type overrides.  Because the
send must succeed before polling begins, address routing, revival, persistence,
timeout behavior and incremental status output remain owned by their existing
chokepoints.  `ask' uses the same composition for its coordinator-directed
question flow.

**Agent mail preserves the human's terminal composer.** Codex has a native
session queue, so its mail never touches the terminal. Claude Code does not
expose a session-addressed CLI queue. Its rendered prompt is therefore the
safety boundary: delivery proceeds only when the current composer is known not
to contain an unsent draft. If it does contain a human draft, mail stays unread
and the draft is never moved. The next `UserPromptSubmit` hook proves that the
human has sent that draft; delivery then bracket-pastes the mail into the
available composer and invokes `chat:queueSubmit`, putting it behind the
human's message.
The queue-submit key bytes are customizable as
`rsr/agent-orchestration-claude-queue-submit-key` for users who rebind that
Claude action.

Claude's inline Tab completion also occupies the composer, but it is not a
draft until the human accepts or edits it. Claude renders that suggestion with
the terminal's ANSI faint attribute; Eat preserves it as `eat-term-faint`.
Agent-sessions therefore treats a composer whose entire non-whitespace body is
faint as empty. A typed prefix is non-faint, so mixed typed-plus-suggested text
continues to block delivery.

Claude does not always clear submitted text from the rendered composer before
the hook callback tries delivery; it can retain that text through the turn or
until the next edit. `UserPromptSubmit` includes the authoritative
`user_prompt`, so the session remembers it. A non-empty composer whose
whitespace-normalized text still equals that submitted prompt is safe; changed
text is a new human draft and remains protected. This comparison also absorbs
visual hard wrapping. Without it, a Stop or mail-arrival check can see the old
prompt, withhold mail, and receive no further event until the human submits
again.

An hour-long turn is exactly when a question, answer, blocked report, or done
report must not wait for `Stop'. When one of those types arrives for a running
conversation, delivery queues all pending mail in order. For Codex it calls
`codex queue --thread … --message …`; for Claude it uses the TUI action sequence
above. Codex keeps the actionable-type steering policy: a plain `status' does
not trigger its native queue, but an earlier status rides along with later
actionable mail so delivery cannot reorder the inbox. Claude instead queues all
pending types whenever its composer is known to be safe. Its hook status can
remain `running' while the main chat is waiting on background work, so using
message type or status there would strand ordinary mail despite an available
composer. Codex must acknowledge the queue before messages are consumed;
failure leaves them unread for `check' or a later retry. Resting Codex sessions
use the same native queue: terminal paste would share the human's composer, so
a half-written human prompt could otherwise be submitted as part of agent mail.
Resting Claude sessions use the same composer gate. An unrecognized Claude
display is treated conservatively as non-empty and waits for the next user
submission. Other agents keep the idle behavior because typing into a busy TUI
is not a portable queue API.

Idle delivery fires on the `Stop` hook (via
`rsr/agent-orchestration-deliver`) and on arrival. It requires both a non-running
status and something holding the terminal's foreground, and is only the fallback
for agents without a known queue action. Inbox reads, queue acceptance, and
idle delivery consume mail on Emacs's single thread, so whichever gets a message
first owns it and the others see no pending mail.

Both gates are phrased as exclusions on purpose. Enumerating the states
that *are* fine has already failed once: the first version listed `idle' and
`needs-attention', and `needs-attention' becomes `stopped' the moment the user
looks at the terminal, so delivery quietly stopped for exactly the session an
orchestrator is most likely to be watched in. And the foreground test is not
tidiness — with the shell's own prompt in front, a paste plus Enter is not
reaching a TUI at all, it is the shell *running the message as a command line*,
where the message was written by another agent. Mail for a bare shell stays
queued for `emacs-agent check' instead.
Idle delivery is one bracketed paste plus a delayed Enter: typed plainly, every
newline in the message would submit, firing the agent's turn on the first line.

**Every rendered message identifies `$orca (/orca)' in its header.** The
recipient may be a peer agent that was never spawned by the sender and has not
loaded the skill, so "orchestration mail" or a coordinator/worker label is not
enough context. Naming the skill in the payload makes both pushed mail and
explicit inbox reads self-routing while the sender line states the relationship
that actually exists.

**Pre-trusting the spawn directory is a deliberate widening, not a convenience.**
Both agent CLIs gate a directory they have never run in behind an interactive
trust prompt, and a worker stopped there never reads its brief — so for the case
this feature exists for, spawning into a just-allocated worktree, every spawn
would be a wait for a report that cannot come. `spawn` therefore registers the
directory with the agent first, additively and idempotently, leaving an existing
entry alone even when it says untrusted. The cost is that any directory an
orchestrator spawns into becomes trusted for that agent from then on, which is
why it is a defcustom and why each registration is reported in what `spawn`
prints rather than done quietly.

**The dashboard needed almost nothing.** A worker records its coordinator in the
same `:branched-from` slot a `b`-branch uses, so the existing nesting renders it
under its parent (same worktree) or tags it `↳ from …` (elsewhere), and its task
becomes the row's title override. The only addition is the `✉N` badge, which
reads the in-memory mailbox — the render path stays off the database, as the
rule above requires.

**An exploration child is opened by Emacs when Emacs owns the parent, and by
tmux otherwise.** The `explore-session` skill (`skills/explore-session/`) spins
one tangent off into a new window of the parent's own tmux session, with no
dependency on Emacs: its `open-window.sh` runs `tmux new-window` itself. A child
opened that way never reaches the dashboard — no proxy, no `@agent-session-id`
tag, and no `EMACS_AGENT_SESSION_ID` in its environment (tmux windows inherit
the *server's* environment), so its hooks exit before forwarding and even a
later reattach cannot recognise it. Adopting such a window afterwards does not
help: the agent's environment is fixed by then, so it would be a row that never
hears a hook. The split therefore has to happen at the moment the window is
opened. When the parent's shell has `EMACS_AGENT_SESSION_ID`, the script asks
`rsr/agent-sessions-explore-spawn` to open the window; when it has not, or
Emacs does not answer, or this Emacs does not know the id, plain tmux opens
exactly the same child. The script keeps ownership of everything that is not
Emacs's to decide — the child's command, its environment, the `@explore-*`
window options, the folder layout — and Emacs adds only what the agent cannot
give itself: a tracked id in the environment, the proxy, the nesting and the
brief as an attachment. That is the same line "Emacs owns only what an agent
cannot do" draws for orchestration.

Three details follow from that. The parent's tmux *session* is passed in and
bound as `rsr/agent-tmux--target`, because the skill's rule is "same session as
the parent" while `--tmux-open` would derive one from the child's directory (and,
outside a git checkout, would stop to ask in the minibuffer — from an
emacsclient call, with the agent waiting). The window is opened `:silent`, in a
`save-window-excursion`, for the reason spawn is: the user is looking at a tmux
client, and an agent's action must not rearrange Emacs; `--no-focus` maps to
`new-window -d` on top. And the attachments split by reader: `brief.md` and
`findings.md` go under the child (what it was told, what it found), while
`summary.md` goes under the *parent* through `emacs-share file --to`, since an
unread row under the parent is what "ready to bring in" looks like on this
dashboard. The child's one-line notice stays on the agents' native channel
(Claude's SendMessage, pi's socket) and is deliberately not also sent as
`emacs-agent` mail: Claude mail is pasted into the recipient's composer and
queue-submitted, which would deliver the same sentence twice and start a turn.
If the user later wants the notice in the mailbox too, it is a single
`emacs-agent send --to "$EMACS_AGENT_PARENT"` line in the skill's report step;
nothing here needs to change.

**The skill is a stub; the guide ships with the tool.** `/orca` (and `/orca
--main`) tell an agent when to engage and to run `emacs-agent guide [--main]`;
the guides themselves live next to the command and are symlinked, not copied,
into `~/.claude/skills` and `~/.codex/prompts`. Two copies of a protocol, one of
them cached in a config directory, is how a skill ends up describing flags the
command no longer has. This is the one idea worth keeping from Orca's own design
(`orchestration/provenance.md`).

**Org links are composed by Org and pasted by the terminal backend.** `C-c C-l`
in vterm and Eat's default semi-char mode runs `org-insert-link' in a temporary
Org buffer, preserving the normal stored-link completion and description
prompt. The finished Org markup is then bracket-pasted into the terminal input
without Enter, so an agent-session link can be copied from the dashboard and
included in a prompt without either teaching the terminal Org syntax or
submitting a half-finished message. The bracketed-paste implementation is shared
with orchestration delivery; terminal-specific string handling has one owner.

## Fork/branch tracking — the one place with no ground truth

There is **no hook event or transcript field that names a fork's parent** (this
was verified, not assumed — Claude's `SessionStart` `source` has no "fork", and
the child transcript carries no parent id). Three consequences shaped the
design:

- **We infer parentage from evidence, not authority.** A fork copies the
  parent's transcript verbatim, so the child's message uuids contain (nearly)
  all of the parent's and share the same root. Auto-detection is a *heuristic*
  built on that fact — good enough to be worth doing automatically, but with
  honest failure modes (misses a fork if you keep working in the parent before
  the child's first hook; Claude-only). It's a convenience, not a source of
  truth.
- **Manual `B` is the escape hatch, not a fallback afterthought.** Because
  detection is heuristic, there must always be a way to state the relationship
  by hand (Codex forks, closed parents, mis-detections).
- **A fork briefly *is* its parent.** At `SessionStart`, `--fork-session`
  reports the resumed (parent) id before minting its own, so a fresh child's
  session id transiently equals its parent's. This is why nesting resolves a
  parent to a *different entry* carrying the id, and why cycle-safety comes from
  a visited set — **not** from a `sid == parent-sid` rejection. That check looks
  like a reasonable simplification and would silently break fork nesting; don't
  add it back.

  The transient also reaches the session log, which briefly records the parent's
  id against the child's terminal. `--log-supersede` cleans that up by asking
  the *log* whether the same id is open on another row — if so the row is an
  artifact of the fork and is deleted rather than offered by `R` as a resumable
  duplicate. Note where that test lives: in the log, on log rows. It is exactly
  the `sid == parent-sid` reasoning the bullet above forbids, and it is only
  safe because it never touches parentage detection. Keep it that side of the
  line.

## Shared files and work links — an inbox, not a file manager

`emacs-share file FILE ["why"]` lets an agent hand the user something to read;
it lands as a fourth level of the tree, under the agent that sent it, and stays
highlighted until opened. It exists because a terminal is a bad inbox: "look at
/tmp/plan.md" scrolls away, and is only seen at all if you are already in that
buffer.

`emacs-share link linear|pr URL [LABEL]` uses the same UI
for the external work that explains a session. A session can have multiple
Linear tickets and PRs; each URL has its own row. Exact re-registration is a
true no-op and preserves the read state; changing a URL's label marks that row
unread again while keeping its position. A new URL adds a new row.

`emacs-share state STATE|--clear` sets the session's workflow state, the same
field `t` cycles. The middle of `rsr/agent-sessions-states` is the
issue-workflow skill's phases, so an agent running it reports each transition
and the column shows whose turn it is; the *-REVIEW states and `PR-OPEN` are the
skill's gates, where the agent has stopped for the user. **One field, last
writer wins.** The agent overwrites a state the user set by hand on its next
transition, and the user can override the agent at any time with `t`; a
separate agent-owned column would show two answers to "where is this session"
and leave the user to reconcile them. A state outside the list is refused, not
stored, because an agent typo would otherwise render as a plausible-looking
unstyled state that no `t` cycle passes through.

**It is attached to the session, by the session's most durable identity.** The
key is `--session-note-keys` reused verbatim — the agent's own session id when
it has one, the buffer name otherwise, reading both and collapsing onto the
first on write. So renaming a terminal keeps its attachments, one added to a
bare shell survives `claude` starting in it, and a session brought back with
`R` gets them back. The *caller* passes the terminal id, because that is what
the shell environment has; `rsr/agent-sessions-share-file` and
`rsr/agent-sessions-share-link` resolve it to a session, the same split the hook
path makes. Like a note, a row outlives the session that owned it and nothing
prunes it — the same trade, for the same reason.

**Re-sharing a path means "I changed it, look again", not "add it twice".**
This is why the table carries two timestamps. `visited_at` is cleared so the
row lights up exactly as it did the first time, but `shared_at` — the sort key
— is left at the original share, so the row does not move. That is the
ordering rule the dashboard already lives by: a row may move when something
meaningful changes, and a row jumping to the bottom of its list is precisely
the thing the user was trying to aim at moving out from under them.

**Submitting refreshes an open buffer only when it has no unsaved changes.**
The Emacs entry point looks for a buffer already visiting the submitted path
and reverts it from disk, so an open plan immediately shows the version the
agent just handed over. It does not open a buffer merely to revert it, and a
modified visiting buffer is left exactly as it is: sharing a file must never
discard the user's edits.

**`k` detaches and never touches disk.** This list is an inbox; clearing an
item out of it must not be able to destroy the thing it points at. There is
deliberately no prefix argument that deletes the file — if that is ever added,
it is a different key, not a modifier on this one.

**An unopened attachment borrows the needs-attention face, deliberately.** An
unread file or link and a waiting session are the same claim on the user's
attention, and the dashboard should not make anyone learn two highlights for
it. The rows push onto `--row-status` like every other row, which is what makes
`N`/`P` walk to them; see that variable's docstring for why status is recorded
at render time rather than looked up.

**Reading clears it, however the file was opened.** `RET` is the common path;
`d` opens the newest commit touching the file in a Magit revision buffer
filtered to that path, and clears it only after the diff opens successfully.
The focus hook that already clears the `u` mark also matches the selected
window's `buffer-file-truename` against the shared paths, so a file shared by
one path and opened by another still counts as read. That hook runs at every
buffer switch, so the check is a set lookup and is gated on the database being
already open — which it is whenever a terminal has ever existed, and is not in
an Emacs with no sessions.

**`u` toggles here, where on a session it sets.** Both directions are wanted
for an attachment — lighting one up to re-read, and dismissing one you have
decided not to read at all — and an attachment row, unlike a session, has
somewhere to read its current state back from. `RET` and `v` browse an external
link, and `k` detaches it without affecting the remote issue or pull request.

**A Linear link opens in Emacs first, the app second, the browser last.** `RET`
jumps to the issue's heading in `rsr/agent-sessions-linear-org-file` (the
`linear.org` that linear-emacs pulls into), matched on the `ID-LINEAR`
property against the identifier in the URL — not the URL itself, because the
pulled `:LINK:` drops the workspace segment the shared URL carries. `v` shows
that heading in another window. You are in Emacs when you press `RET`, and the
heading already carries the description and state, so staying is the cheap
default. The file is a snapshot of issues assigned to the user as of the last
pull, so a miss is normal, not an error: a ticket that is not there opens in
`rsr/agent-sessions-linear-app`. `V` is the way out of Emacs, so it always
opens the app, even when the heading exists. Without the app — nil, not
installed, or not macOS — both fall to `browse-url`. agent-sessions reads the
Org file directly and never requires linear-emacs, so the jump works in an
Emacs that has not loaded it, and a missing file only costs the jump.

**The sharing command fails loudly, unlike the hook forwarders.** Those exit 0 into the
void by design: a hook firing into a dead Emacs must not break the agent's
turn. This one is the opposite — an agent that believes it has handed over a
file when it has not will go on to tell the user about it — so a missing file,
a terminal outside Emacs, an unreachable server and a refusal from Emacs each
print to stderr and exit non-zero. `rsr/agent-sessions-share-file` therefore
*returns* its failures as strings rather than signalling: emacsclient's printed
value is the only channel back to the agent. `emacs-share-file` is a symlink to
`emacs-share` that selects file mode implicitly, so already-running agents keep
working while new instructions use the unified command.

**PATH injection is additive by construction.** The terminal env sets
`PATH=<our bin>:<the PATH the terminal was going to inherit anyway>`, read from
`process-environment`. Building it from any other source could silently shrink
the shell's PATH.

## Wiring is self-owned and additive, never authoritative

`rsr/agent-sessions-install` / `-uninstall` manage the hook entries in
`~/.claude/settings.json` and `~/.codex/hooks.json`. The design constraints,
which are the whole point of these commands existing:

- **Own our forwarders, depend on nothing external.** The package ships its own
  `agent-sessions-{claude,codex}-hook.sh` and points the configs at them, so it
  works with orca absent/removed. (The machine this was written on happened to
  be wired through orca's script; that's incidental, not required.)
- **Only ever touch our own entries.** Add/remove is keyed by the forwarder
  *filename* in the command string, so any other hook (orca's, the user's) is
  invisible to us. Install and uninstall are therefore both safe to run blind,
  and both idempotent. Install self-heals stale entries (moved package, edited
  event list) by stripping ours and re-adding. This is why several hooks can
  coexist forwarding the same events — double-forwarding is harmless (status is
  edge-triggered), and not-clobbering-others matters more than deduping.
- **Round-trip the config losslessly.** Parse/emit uses the *native* JSON with
  arrays as **vectors** — a Lisp list would be re-serialized as an alist/plist
  object and corrupt the file. Everything not ours (permissions, model, …) must
  survive untouched; verify round-trips by equality against the original, not by
  eyeballing. A `.bak` is written before each change.

Setup does **not** auto-run install — it writes user config files, so it stays
an explicit `M-x`. Point users there rather than editing the JSON by hand.

## Workflow keys — a layer on top, not part of the dashboard

`agent-workflow.el` holds the planning workflow's commands: the `C-c i w`
map (bound in `~/.emacs.d/modules/personal/ai-sessions-config.el`), the
dashboard's `c` (child of the row's session), `y` (bring in) and `o` (open
the row's code or Plans folder). It is a separate file because it only *uses*
the dashboard: everything it needs from `agent-sessions.el` is a public
entry point or a small helper, and keeping it out stops the 6,800-line
dashboard file from absorbing a workflow that may change on its own schedule.

**One launcher.** Every session a key opens goes through `bin/agent-launch`,
the same script agents use to open review, bug-fix and exploration children
(`explore-session`'s `open-window.sh` is a thin wrapper over it). The script
decides the command and environment; Emacs only opens the window
(`rsr/agent-sessions-launch-spawn`, which `rsr/agent-sessions-explore-spawn`
now delegates to), so a plain-tmux fallback opens the same session. Keys run
the script asynchronously (`make-process`, reported from the sentinel) with
`EMACS_SOCKET_NAME` set to this Emacs's socket, so the request comes back to
the Emacs that asked. It must stay asynchronous: under `call-process` Emacs
cannot answer the script's `emacsclient`, and both wait forever.

**Registered folders are stored, never derived.** `emacs-share folder plans|code
PATH` writes the `registered_folders` table under the same durable session
identity as notes and links (`--session-note-keys`), so a folder registered
on a bare terminal survives the agent getting an id. A session has one Plans
folder (a new one replaces it) and any number of code folders (one per
repository of a multi-repository task). `o c` asks which one when there are
several; it never falls back to the session's directory, because a planning
session's directory is the Plans folder and opening it in magit would be a
guess. The table is not `session_folders`: that name was already the
dashboard's own folder-grouping table.

## Editing

**A schema addition needs the load-time re-migration to be reachable.**
`--db` runs the schema only when it *opens* the file and then caches the handle
for the life of the Emacs, so adding a table left every running Emacs querying
one its connection had never created — a flood of `no such table`, not a clean
failure. The top-level `when (sqlitep …)` form after `--db` re-runs the
statements against an already-open handle; every statement is `IF NOT EXISTS`,
so it is free, and it makes a reload behave like a restart. Keep it in step
with the schema list. Note what it does *not* do: it cannot alter an existing
table, so a change that is not a pure addition needs a real migration keyed on
`meta.schema_version`. Shared links moved from one row per kind to one row per
URL in version 2; `--db-migrate` handles existing databases, including reloads
into a running Emacs.

Reload into the running server after any change (definitions don't hot-swap):
`emacsclient -e '(load-file ".../agent-sessions/agent-sessions.el")'`. A
`-L modules` batch byte-compile mis-resolves `(require 'magit)` against the
sibling `modules/magit.el` config file, so trust the live load for validation.
