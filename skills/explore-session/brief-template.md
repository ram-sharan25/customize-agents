# Exploration brief: {{slug}}

You are a separate exploration session, opened from a parent {{parent_agent}}
session so that one tangent can be explored without polluting the parent's
context. The user will talk to you directly in this tmux window. You have no
other link to the parent than what is written here.

## Parent

- Agent: {{parent_agent}}
- Address: {{parent_address}}
- tmux: {{parent_tmux}}

## Topic

{{topic}}

## What the parent wants to learn

{{goal}}

## Minimal context (pointers, not transcript)

{{context}}

## Files worth reading first

{{files}}

## Constraints

{{constraints}}
- The shared rules apply unchanged: never commit, push, or reset; ask in plain
  language; verify rather than assume.

## Where to write

- Directory: `{{dir}}`
- `findings.md` — your detailed notes; any length and shape you like.
- `summary.md` — written only when the user tells you to report back; at most
  12 lines in the format below. It is the ONLY file the parent will read.
- Any other files you produce go in the same directory; list them in
  `summary.md` under `Where:`.

## Reporting back — only when the user tells you to

1. Write or refresh `findings.md`, then write `summary.md`.
2. Send the parent exactly one line, nothing else:

       exploration {{slug}} done — ready to bring in ({{dir}})

   {{report_instruction}}
3. If `EMACS_AGENT_SESSION_ID` is set in your environment, also run
   `emacs-share file "{{dir}}/findings.md" "exploration {{slug}}: findings"`
   and `emacs-share file --to "$EMACS_AGENT_PARENT" "{{dir}}/summary.md"
   "exploration {{slug}}: ready to bring in"`, so the files show on the
   user's dashboard. If that fails, say so in one line and carry on.
4. Tell the user it was sent, and stay available here. The parent will read
   `summary.md` only when the user tells it to bring the exploration in.

## summary.md format

    # Exploration summary: {{slug}}
    What: <1–3 sentences: the finding, decision, or answer, and whether it is settled>
    Where:
    - {{dir}}/findings.md — <what it holds>
    - <other absolute path> — <what it holds>
    Open: <one line: what remains or needs the user; or "nothing">

Lead with the conclusion. Paths absolute. Never paste file contents into the
summary or the notice. If the user redirected you away from this brief, say so
in `What:`.

## First action

{{start}}
