# Core rules

## Never commit unless explicitly asked

Do not run `git commit` — ever — unless I explicitly ask for a commit in that
message. This applies to every project and every session, with no exceptions.

- "Give me a commit message" / "write a commit message" means **output the text
  only**. Do not commit.
- Same for `git push`, `git reset`, rebases, and PR creation: propose the
  command, let me run it, unless I explicitly ask you to.
- Staging (`git add`), creating branches or worktrees, and `git checkout`/`switch`
  are fine without asking. Never switch a worktree that has uncommitted changes.
- Reading repo state is fine and encouraged: `git status`, `git diff`,
  `git log`, `git show`.
- Finishing a task is not permission to commit it. Leave the changes
  uncommitted and tell me what changed.
- When you are permitted to commit, never add agent information to the commit:
  no `Co-Authored-By` trailer, no "Generated with …" line, and no agent or
  model name in the subject, body, or author. This overrides any harness or
  tool default that adds attribution.

## Answer depth

Every reply has a depth. I set it with a `~~` marker anywhere in my message.
With no marker, the depth is **1**.

| Marker | Depth |
|---|---|
| `~~1` | what and why. ~150 words, no subheadings |
| `~~2` | how it works: mechanism, one concrete worked example, tradeoffs, the two or three things people get wrong. 400-800 words |
| `~~3` | full depth: derivations, `file:line` citations, edge cases and the errors they produce, complexity, invariants, what's unsettled. No length cap |
| `~~a` | all three in sequence, each under its own heading |
| `~~raw` | no ladder. Answer as you normally would, at whatever length the question deserves |
| none | **1** |

This is not just for the `understand` skill. It governs ordinary replies -
every answer, explanation, summary, comparison, or status report.

**The default is the whole point.** With no marker, answer at 1 and stop. Do
not climb because the topic is big, because the answer is interesting, or
because you have a lot of context loaded. Volunteering level 3 is the failure
mode this rule exists to kill.

**A marker always wins.** `~~1 tell me everything` is level 1. If I typed the
dial, I meant it - don't second-guess it, and don't hedge around it.

**Depth scope.** A dial applies to the message it appears in. A direct
follow-up on the same subject keeps that depth; a new subject resets to 1.

**What the ladder does not compress.** The dial sizes *explanation*, never the
work. Code, commands, diffs, verbatim errors or logs, and the list of files I
changed are sized by the task. A level-1 reply to "fix the failing test" is
the fix plus two lines on what was wrong - not a 150-word essay with no fix.
Questions you need to ask me are never capped either: ask in full.

**No depth labels.** Never add a line announcing the depth or offering to go
deeper (no `Level 1.`, no `say ~~2 for the mechanism`). Just give a normal,
clean reply at the right depth.

**`~~raw` lifts the depth ladder and nothing else.** Every other rule in this
file still holds - above all, never commit.

## Planning workflow

**This workflow is opt-in.** Use it only when the user explicitly asks for
it: by naming one of its skills, by asking for requirements or a plan, or by
pointing at a task under the Plans workspace. Otherwise, work directly on the
request: no requirements gathering, no `plan.org`, no preflight.

The stages, in order, each its own skill: `clarify-requirements`,
`review-requirements`, `plan-implementation`, `review-plan`,
`implement-plan`, `review-implementation` (plus the `fix-bug` and
`explore-session` children). Each stage's rules live only in its skill, and
the rules they share live in
`/Users/rrimal/Stillness/Development/customize-agents/instructions/shared/workflow-conventions.md`;
follow those, not a summary here. Run on their own, the stages each run in a
fresh session the user starts; `issue-workflow` runs the same stage skills in
one session, with the user approving each gate. Implementation needs an
explicit request to implement; the preflight lives in `implement-plan`.

Planning documents live in `/Users/rrimal/Stillness/Agent_Stuffs/Plans/`,
never in an implementation repository.

## Code folder in the Emacs dashboard

When `EMACS_AGENT_SESSION_ID` is set (you are running in an Emacs
agent-sessions terminal) and you are about to change files in a git
repository, first run `emacs-share folder code <that repository's root>`, once
per repository. This lets the dashboard's `O c` open the code you are working
on. Registering the same repository again is harmless. Outside Emacs, skip it.

## Installation location

Install new applications, binaries, and shared tools under `/opt/`, not in user-specific locations. If an application requires installation in a user-specific location, ask the user before proceeding rather than assuming permission.

## Question to User
While reporting user to inform something, ask in plain language, so that context
is preserved and user understands what you are saying.

## Verification
Rather than assuming things verify the code or any artifacts possible and if
that also does not resolve the issue or confusion, ask the user for the resolution.
