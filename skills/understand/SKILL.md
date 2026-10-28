---
name: understand
description: Explain anything at a chosen depth - a concept, a paper, a file, a function, an error, a system. Depth is set by a `~~` marker - `~~1` overview, `~~2` mechanism, `~~3` full depth, `~~a` all three - defaulting to `~~1` when none is given. Use whenever the user types `~~1`/`~~2`/`~~3`/`~~a` anywhere in a message, or asks what something is, how it works, or to explain or walk through something.
---

# understand

Explain one thing at one depth. The depth is a dial the user sets; your job is
to read that dial correctly and then not exceed it.

## Step 1 - Read the dial

Depth is set by an explicit marker: `~~` followed by a level.

| Marker | Level |
|---|---|
| `~~1` | 1 - what and why |
| `~~2` | 2 - how it works |
| `~~3` | 3 - how to build, extend or debug it |
| `~~a` | all three, in sequence, each under its own heading |
| `~~raw` | no ladder - answer as you normally would |
| no marker | **1** |

The same ladder is a standing rule in your harness's global instructions file
(`~/.claude/CLAUDE.md`, `~/.config/pi/AGENTS.md`, or Codex's `AGENTS.md`) and applies to
ordinary replies too. This skill is the expanded reference for the shape of
each level.

Position is irrelevant. `~~3 explain the scheduler` and `explain the scheduler
~~3` are the same request. The marker is a control token, never part of the
subject - strip it before working out what they actually asked about.

**Only `~~` immediately followed by `1`, `2`, `3` or `a` is a dial.** Plain
`~~struck through~~` is ordinary text; leave it alone.

**A marker always wins.** Plain language still works when no marker is present
- "deep dive", "full detail", "I need to implement this" read as 3; "walk me
through", "how does it work", "deeper" read as 2. But if a marker is there,
it is final: `~~1 give me everything` is level 1. Typing the dial *is* the
instruction, and second-guessing it defeats the point of having one.

**Default hard rule:** no marker and no plain-language cue → level 1, and
stop. Do not climb because the topic feels big, because the answer is
interesting, or because you happen to have a lot of context loaded. An
unasked-for level 3 is the main failure mode of this skill.

Never announce the selected level or offer a deeper level. Give a normal,
clean reply shaped to the selected depth.

## Step 2 - Ground it before explaining

Depth is worthless if it is invented. Before writing:

- **In this repo?** Read the actual file, function, config or test. Cite as
  `path/to/file.rs:142`. Never explain local code from the name alone.
- **A paper, library, or API?** Use the real source if it is reachable (the
  installed package, the docs, the vendored code). If it is not, say which
  parts are from memory, and flag anything that may have changed.
- **A concept?** Memory is fine, but mark genuine uncertainty rather than
  smoothing over it.

At level 3 this is not optional: no derivation, no line-level claim, and no
edge case goes in unless you have looked at the thing it describes.

## Step 3 - Write to the level's shape

### Level 1 - What and why
Target 100-200 words. No subheadings.

- One sentence: what it is, in plain language.
- Two or three: the problem it exists to solve, and the single core idea that
  makes it work.
- Where it sits - what it replaces, what it talks to, when you'd reach for it.
- At most 3 key terms, each defined in a half-line.

No code blocks unless the thing *is* a one-liner. No history, no taxonomy of
variants, no caveats. Someone should finish this in under a minute knowing
what the thing is and whether they care.

### Level 2 - How it works
Target 400-800 words. Subheadings allowed.

- Two-line recap of level 1, then move on - don't re-explain it.
- The mechanism: the main parts and how control or data moves between them.
- One worked example, concrete and small - real values, real call, real input
  and output. This is the centerpiece, not a garnish.
- The key design decisions and what each one trades away.
- Two or three things people get wrong about it, and the correction.

A short code block or a plain-text diagram is welcome here if it carries
something prose can't.

### Level 3 - How to build, extend or debug it
No length target - as long as the content demands, no longer.

- Three-line recap, then straight into depth.
- The full mechanism: every significant step, in order, with the reasoning or
  derivation behind each. Line-level for code (`file.py:88`), equation-level
  for math.
- Edge cases, failure modes, and what each one looks like from the outside -
  the error you'd actually see.
- Performance and cost: complexity, the hot path, what dominates at scale.
- Invariants and assumptions - including the ones that are implicit and would
  bite someone who broke them.
- Interactions: what else in the system this touches, and what breaks together.
- Where the real knowledge lives: the files, the spec sections, the tests that
  encode the behavior.
- What's genuinely unsettled or version-dependent.

The bar: after level 3 the user could reimplement it, or debug it at 3am.

## Rules that hold at every level

- **One thing.** If the ask covers several, name the split in one line and
  explain the one they most likely meant; offer the others by name.
- **Levels replace, they don't stack.** Level 3 is not level 1 plus appendices.
  Recap in two or three lines and spend the rest on new ground.
- **Match their vocabulary.** If they used domain terms, assume they know them.
  If they asked plainly, define as you go. Never explain a term they just used
  correctly themselves.
- **No padding.** No "great question", no restating the question, no closing
  summary of what you just said.
- **Say what you don't know.** "I'd have to read X to be sure" beats a fluent
  guess, hardest at level 3 where confident wrongness is most expensive.

## If the level doesn't fit the ask

Answer at the level asked without announcing the level or suggesting a deeper
one. The user sets the dial; do not override it.
