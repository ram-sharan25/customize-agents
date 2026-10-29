# Workflow conventions

Rules shared by every stage skill of the planning workflow. Each skill points
here and keeps only its own stage's rules. A skill's own text wins where it is
more specific.

The stages, in order, each its own skill:

| Stage | Skill | Writes | Dashboard state while working | Waiting state |
|---|---|---|---|---|
| Clarify requirements | `clarify-requirements` | `requirements.org`, `decisions.org` | `PLANNING` | `PLAN-REVIEW` |
| Review requirements | `review-requirements` (child) | a findings file | none | none |
| Plan | `plan-implementation` | `plan.org` | `PLANNING` | `PLAN-REVIEW` |
| Review plan | `review-plan` (child) | a findings file | none | none |
| Implement | `implement-plan` | code (staged), Evidence in `plan.org` | `IMPLEMENTING` | `IMPL-REVIEW` |
| Review implementation | `review-implementation` (child) | a findings file | none | none |

Side children, opened only when the user asks: `explore-session` (questions,
including why-not explorations of a decision) and `fix-bug`.

Run on their own, the stages each run in a fresh session the user starts, and
work from the files only. `issue-workflow` is the one exception: it runs the
same stage skills in sequence in one session. Either way, no stage starts the
next one, and the user approves every gate.

## A path given at invocation is confirmed

When the user starts a stage with a task folder or document path in the same
message (`/plan-implementation /Users/rrimal/Stillness/Agent_Stuffs/Plans/<task>/`),
that path is confirmed. Resolve it, say in one line which documents you found
and their `#+status:`, and start. Ask only when no path was given, when the
path matches nothing, or when it matches more than one task. Never choose
between candidates yourself.

Every task is a package under `/Users/rrimal/Stillness/Agent_Stuffs/Plans/`:
`requirements.org`, `decisions.org`, `plan.org`, and an optional `artifacts/`,
whether or not it starts from an issue. Follow the workspace's `AGENTS.md`.
Planning documents never go into an implementation repository.

## The documents are self-sufficient

A fresh session knows only what the documents say, so everything a later
stage needs is written there, and every stage reads it from there:

- `#+issue:` and, once the user shares one, `#+pr:` — the issue and PR links.
- `#+implementation-repository:` — one line per repository (`N/A` when there
  is none), each followed by its own `#+baseline:` commit.
- `#+status:` — `DRAFT`, `READY-FOR-REVIEW`, `FINAL`, or `RECONCILED`.
- Pointers to review findings: each findings file is linked from the document
  it reviewed (`requirements.org` under `* Open questions`, `plan.org` under
  `* Progress notes`) with its date and whether it is resolved.

At the start of every stage:

1. Read the headers of all three documents. When they disagree, report it.
2. For each repository, check its recorded baseline:
   `git -C <repo> merge-base --is-ancestor <baseline> HEAD`. Say in one line
   whether HEAD is at the baseline, ahead of it, or unrelated to it (a
   different branch or a rewritten history). Unrelated is something to raise
   with the user before you work, not to fix.
3. Register on the dashboard (next section).

When a stage learns something the next stage needs (a repository, a baseline,
a PR link, a findings file), it writes it into the documents before it stops.

## Register on the dashboard

Only when `EMACS_AGENT_SESSION_ID` is set (the Emacs dashboard opened this
terminal). Run, at the start of the stage:

```sh
emacs-share state <STATE>                          # the stage's working state
emacs-share folder plans <task folder>
emacs-share folder code <repository>               # once per #+implementation-repository:
emacs-share link linear|pr <url>                   # only when #+issue: (or #+pr:) is set
```

- `<STATE>` comes from the table above. At the stage's end, set its waiting
  state. A review child sets no workflow state.
- A planning session registers each `#+implementation-repository:` as a code
  folder. An implementing session registers the worktree(s) it works in.
- `emacs-share link` takes `linear` for a Linear issue URL and `pr` for a pull
  request; skip an issue that is only an ID, and say so.
- When a command fails, say so in one line and carry on. Registration helps
  the user find things; it never blocks the stage.

## Children and report-back

A child is a separate session the user asked for: a review, an exploration, or
a bug fix. Open it through the core launcher, which is on every dashboard
session's PATH:

```sh
agent-launch --child --skill <skill> --task <task folder> \
  --slug <skill> --dir <task folder>/artifacts/<YYYY-MM-DD>-<skill> \
  --brief <that dir>/brief.md --no-focus
```

1. Write `brief.md` in that directory first: the task folder, the documents
   to read, the output directory, and the question when there is one. Give
   pointers, never transcript. A review child's brief adds nothing about what
   the author thinks of the work.
2. `agent-launch` refuses (exit 2) outside tmux and Emacs; tell the user and
   do nothing else.
3. Tell the user in two lines what opened and where its findings will land.
   Then stop watching it.

The child, when its work is done (a review), or when the user says "report
back" (an exploration or a bug fix):

1. Writes its findings file (format below) and a `summary.md` of at most 12
   lines in the same directory: `What:`, `Where:` (absolute paths), `Open:`.
2. Sends the parent exactly one line:
   `<skill> <slug> done — ready to bring in (<dir>)`
   - `EXPLORE_PARENT_PID` set (a Claude parent opened it): the `SendMessage`
     tool, to the name `parent-address.sh --pid $EXPLORE_PARENT_PID --field name`
     prints (`~/.claude/skills/explore-session/scripts/`).
   - Pi: the `report_to_parent` tool.
   - Otherwise, `EMACS_AGENT_PARENT` set (the user opened it from Emacs):
     `emacs-agent send --to "$EMACS_AGENT_PARENT" --type done --subject "<the line>" --files <dir>/summary.md`.
3. When `EMACS_AGENT_PARENT` is set, also runs
   `emacs-share file --to "$EMACS_AGENT_PARENT" <dir>/summary.md "<skill> <slug>: ready to bring in"`,
   which is what the dashboard's `y` (bring in) lists.
4. Tells the user it was sent, and stays open.

Bring in, in the parent, only when the user says so (or `y` typed it):
read `summary.md`, relay it as is, then open the findings file when you start
working through it with the user.

## When a review child's notice arrives

While a review child works, the parent's row shows `REVIEW`: set
`emacs-share state REVIEW` when opening the child. When the child's one-line
notice arrives, the parent at once sets `emacs-share state PLAN-REVIEW` for a
requirements or plan review, or `emacs-share state IMPL-REVIEW` for an
implementation review, so the dashboard shows it is the user's move. It then
acknowledges the notice in one line, e.g. "review-plan done — say *bring in*
when you want the findings", and then does
nothing else with it until the user says "bring in". It does not read the
files and does not start fixing.

If no notice comes (the child crashed or the user closed it), the row stays
`REVIEW`. The user can see that on the dashboard and move the row on with `t`;
the findings file, if any, is still in `artifacts/`.

## Findings files

Every review saves its findings in the task's `artifacts/`, in the directory
it was given, as `findings.md`:

```markdown
# <Review kind> — <task name>
Reviewed: <absolute paths, with #+status: of each> · <date> · <reviewer: skill, agent>

## Findings
### [BLOCKER] <short title>
Where: <Org heading, file and function, or command>
Problem: <what is wrong, grounded in the documents or code>
Why it matters: <the concrete effect>
Suggested fix: <one or two lines, or "the user decides">

### [HIGH] …

## Declined to judge
- <what was noticed but set aside as out of scope> — <why>
```

- One scale for every review: `BLOCKER` (cannot go on safely: contradiction,
  infeasible, unsafe, unverifiable), `HIGH`, `MEDIUM`, `LOW` (minor, or only
  as a pattern). When a borrowed checklist says Critical / Important / Minor,
  map them to `BLOCKER`-or-`HIGH` / `MEDIUM` / `LOW`.
- Most severe first. No findings is a valid result; say so, and never make up
  findings to fill the list.
- `Declined to judge` is always present, even if it says `- nothing`.
- A review writes only inside its own directory. It never edits the reviewed
  documents or code.

## Mark who decided

Every choice in a document says who made it:

- *(user, "<decisions.org entry title>")* — decided or confirmed by the user;
  the entry lives in `decisions.org`.
- *(agent: <reason>)* — suggested by the agent and open to change at review.
- In `requirements.org`, anything the agent filled in rather than the user
  said is marked *(agent's guess: <reason>)*.

Only the user's explicit confirmation moves a choice into `decisions.org`.
Agents never change, weaken, or work around a `decisions.org` entry without
asking the user.

## Every choice records why

- Each `decisions.org` entry has a `Why:` line.
- Each choice in `plan.org` carries its reason in its marking.
- Each `* Implementation decisions` entry has the choice, `Why:`, and
  `Cost if wrong:`.
- Why-not (the rejected alternatives) is not written by default. When the user
  wants a choice grilled, they open an explore child for it (see the
  explore-session skill, "Why-not explorations"); its findings are linked from
  the decision only with the user's okay.

## Statuses and gates

- A document is `DRAFT` while it is written or changed, `READY-FOR-REVIEW`
  when the user agrees to hand it to review, `FINAL` only when the user
  explicitly finalizes it, and `RECONCILED` after implementation describes the
  as-built result. A material change to a `FINAL` or `READY-FOR-REVIEW`
  document returns it to `DRAFT`.
- `decisions.org` follows `requirements.org` until a plan exists, then
  `plan.org`.
- Agreeing with content is not approval to write, finalize, or advance. A
  bypass names the gate it skips ("plan from the draft requirements", "go
  forward and implement"); "continue" is not a bypass. Record a bypass in the
  document it affects, with the date and the user's words.

## End with the next command

Every stage ends by printing, as its last line, the exact command for the next
stage, ready to paste, e.g.:

```
next: /review-plan /Users/rrimal/Stillness/Agent_Stuffs/Plans/<task>/
```

Before it, in a few lines: the documents and their `#+status:`, what is still
open, and what the user decides next. When the next step is the user's (a
review to read, a finalization to give), say that and still print the `next:`
line for the step after it.

## Never close the session

A finished stage stays open at its waiting state. No skill exits, closes, or
kills its own session or terminal, and no skill starts the next stage. The
user closes sessions when they choose.

The git boundary in `core.md` holds in every stage: never commit, push, reset,
rebase, or open a PR; stage with `git add` and propose a commit message
instead.
