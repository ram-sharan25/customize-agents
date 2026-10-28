# Core rules

## Never commit unless explicitly asked

Do not run `git commit` — ever — unless I explicitly ask for a commit in that
message. This applies to every project and every session, with no exceptions.

- "Give me a commit message" / "write a commit message" means **output the text
  only**. Do not commit.
- Same for `git push`, `git reset`, `git checkout`/`switch`, branch creation,
  `git add`/staging, rebases, and PR creation: propose the command, let me run it.
- Reading repo state is fine and encouraged: `git status`, `git diff`,
  `git log`, `git show`.
- Finishing a task is not permission to commit it. Leave the working tree as is
  and tell me what changed.
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
