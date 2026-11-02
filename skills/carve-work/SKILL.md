---
name: carve-work
description: Break one piece of work into 90-minute sittings before any Org task exists. Asks the Area, the room and the kind, then ten questions in a fixed order, the user answering first; sets each sitting's OUTCOME, NEEDS, depth and Effort 1:30, says how many sittings the work needs, and teaches the method while doing it. Use when the user says "carve", "carve this", "break this down", "how many sittings", or wants to turn "I want to do X" into sittings or a project file. Not for scheduling, tracking or reviewing sittings.
---

# Carve Work

Walk the user through breaking one piece of work (a project, a learning goal,
a feature) into sittings before any Org task exists, and teach the way of
thinking while doing it. The model it serves: a sitting is 90 minutes, planned
before it starts, with a heading (its name), an `OUTCOME`, a `NEEDS`, `:deep:`
when deep and `Effort 1:30`; work larger than one sitting is an Org project
whose tasks are sittings; there are no sub-tasks.

The user carves, the skill asks. Ask one question at a time, in the order
below, and let the user answer before you offer anything. Propose a breakdown
only after the user has tried, and mark it (my proposal). Write nothing until
section 4.

## 1. Entry

The user gives the work in a sentence. Ask, one at a time, and restate each
answer before the next: which Area it belongs to; which room, work or home;
which kind it is: build, learn, fix, decide, admin. The kind shapes what
follows; the effort is always 1:30 per sitting.

| Kind | Outcome looks like | Question 3 asks for | NEEDS, typically | Depth, by the rule |
|---|---|---|---|---|
| build | Something runs or a check passes, seen by its reader. | The smallest end-to-end thing that could not possibly be wrong. | The repo checked out, a build that runs, the spec or issue. | Deep when the design is yours; shallow when the piece is bounded and an agent writes it while you review. |
| learn | A note in your own words, or a thing you built without copy-paste. | The first rung of the ladder (become a user, build it, trace one feature, reimplement one commit, change three lines). | The clone, an environment that builds it, the docs page. | Deep. |
| fix | A check that reproduces the bug, then the same check passing. | The reproduction, before any fix. | The reproduction steps, the failing input, access to the system. | Deep while the cause is unknown; shallow once the fix is bounded. |
| decide | A note that lists the alternatives and ends in a recommendation, for a named reader. | The working example to study, or the first alternative. | The working example, the docs, the reader's name and a date. | Deep. |
| admin | The thing sent, filed, booked or paid. | The one thing that completes it. | The form, the account, the numbers. | Shallow. |

The rows are the agent's reading of the two walks; the user confirms or
changes them at review.

## 2. The questions, in order

Ask each in turn, in quotation marks as written. Restate the answer in one
line and get a yes before the next question. The user answers first; a
proposal comes only after they tried and is marked (my proposal).

### 1. Outcome

Ask: "What will exist when this is done that does not exist now?"
Then: "Who reads it, or what runs it?" (agent's guess, from the basemap walk).
Accept only something you can see, run, or watch pass. When the answer is
an activity, say so and ask again with the same thing turned into a result.
For example: "I want to read the Flask codebase" is an activity; its result
is "a note on Flask's architecture that names files and functions and covers
one request end to end". A goal wrapped in an activity ("understand how large
codebases are written") is pinned by asking what the check is.

Why: a unit of work ends in something you can see, run, or watch pass; an activity has no end.

Source: Hashimoto, "My Approach to Building Large Technical Projects", https://mitchellh.com/writing/building-large-technical-projects ("each small problem must have some clear way you can see the results of your work"); Ronacher, "Agentic Coding Things That Didn't Work", https://lucumr.pocoo.org/2025/7/30/things-that-didnt-work/ ("would I accept the result").

### 2. Attack

Ask: "Do you know how you would start?" If not, sitting 1 is finding the
attack or gathering context, and its outcome is a note or a running build,
never "read the code". Then: "Is there another way in?" (agent's guess, from
the basemap walk); a second way in is a second context sitting beside the
first.

Why: a problem is ripe when you have a reasonable attack, and context gathered first is an artifact the later sittings reuse.

Source: Karpathy, "A Survival Guide to a PhD", https://karpathy.github.io/2016/09/07/phd/ (quoting Hamming: "it is that you have a reasonable attack"); Zechner, "What I learned building an opinionated and minimal coding agent", https://mariozechner.at/posts/2025-11-30-pi-coding-agent/ ("If you need to gather context, do that first in its own session. Create an artifact"); Hashimoto, "Contributing to Complex Projects", https://mitchellh.com/writing/contributing-to-complex-projects ("Don't read the code before learning to build the project").

### 3. First sitting

For a build, ask: "What is the smallest end-to-end thing that could not
possibly be wrong?" For a learn, the ladder replaces the question: become a
user, build it, trace one feature, reimplement one commit, change three
lines; sitting 1 is the first rung not yet climbed. For a fix, the
reproduction. For a decide, the working example or the first alternative.
For an admin, the one thing that completes it.

Why: a skeleton you cannot have broken gives every later sitting a place to stand, and the first thing seen running is worth more than its code.

Source: Karpathy, "A Recipe for Training Neural Networks", https://karpathy.github.io/2019/04/25/recipe/ ("pick some simple model that you couldn't possibly have screwed up somehow"); Hashimoto, "Contributing to Complex Projects", https://mitchellh.com/writing/contributing-to-complex-projects (the five steps).

### 4. Next sitting

Ask: "What is the next single thing you would add, and how would you know it worked?"
Repeat until the outcome from question 1 is reached. One addition per
sitting, each with its own check.

Why: unverified complexity added all at once takes forever to find; one step with one check does not.

Source: Karpathy, "A Recipe for Training Neural Networks", https://karpathy.github.io/2019/04/25/recipe/ ("complexify only one at a time"); Zechner, "Prompts are code, .json/.md files are state", https://mariozechner.at/posts/2025-06-02-prompts-are-code/ ("Port one type at a time." "STOP and wait for confirmation.").

### 5. Count

Say how many sittings the chain holds. Carve all of them; there is no cap,
no "carve to the next demo", no remainder left as one line. When the count
depends on an earlier sitting's result, carve what is known, write the rule
under the project's `* Outcome` ("one sitting per alternative, carved after
sitting 3"), and tell the user to run carve-work again after that sitting
(agent's guess, from the basemap walk).

Why: the user is planning the whole task, and the sitting is fixed at 90 minutes, so the count is what the chain says, not a target.

Source: Zechner, "What I learned building an opinionated and minimal coding agent", https://mariozechner.at/posts/2025-11-30-pi-coding-agent/ (a plan file with Goal, numbered Approach steps and a Current Step); Karpathy, X 2024-02-10, https://x.com/karpathy/status/1756380066580455557 ("Allocate a 4 hour window": a real learning piece is two or three sittings, not one).

### 6. Depth

For each sitting, ask:
"Would doing this by hand teach you something or decide something?"
Yes: the user does it, and it is `:deep:`. No, and it is bounded and
checkable: it can go to an agent, the user reviews, and the sitting carries
no tag. Deep because the thinking is yours; importance does not set depth.

Why: what you keep is what teaches or decides; what you hand off is bounded and checkable; the same split the four people make.

Source: Zechner, "Thoughts on slowing the fuck down", https://mariozechner.at/posts/2026-03-25-thoughts-on-slowing-the-fuck-down/ ("let the agent do the boring stuff, the stuff that won't teach you anything new"); Ronacher, "90%", https://lucumr.pocoo.org/2025/9/29/90-percent/ ("At this state I don't let the AI write"); Karpathy, X 2026-01-26, https://x.com/karpathy/status/2015883857489522876 ("watch them like a hawk").

### 7. Needs

For each sitting, ask: "What must be at hand before this starts: a file, a
repo checked out, an access, a prior note?" That is its `:NEEDS:`. When a
need is an earlier sitting's outcome, name that sitting.

Why: a sitting that opens with looking things up is not 90 minutes of work; the user should sit down knowing what to do, what is needed and the effort.

Source: Zechner, "What I learned building an opinionated and minimal coding agent", https://mariozechner.at/posts/2025-11-30-pi-coding-agent/ ("Using a sub-agent mid-session for context gathering is a sign you didn't plan ahead").

### 8. Throwaway

On unfamiliar ground, ask: "Which of these sittings might be thrown away?"
Mark it in the heading text as "(may be thrown away)"; the properties hold
nothing else new.

Why: on new ground the first attempt is a best guess; naming it keeps an unreached outcome from reading as failure.

Source: Hashimoto, "My Approach to Building Large Technical Projects", https://mitchellh.com/writing/building-large-technical-projects ("I just take a best guess and expect there is a higher likelihood I'll throw my work away at some point").

### 9. Read back

Read every sitting back as a list: its name, OUTCOME, NEEDS, depth, the
check, and the principle it applied, pointing at the question (Q1 to Q8)
that carries the principle's source. This is the teaching moment: the user
sees their own answers as the method.

Why: what you can restate in your own words you have learned.

Source: Karpathy, X 2020-11-07, https://x.com/karpathy/status/1325154823856033793 ("teach/summarize everything you learn in your own words").

### 10. Show

Show the Org text as section 3 says. Write nothing; section 4 says when
writing happens.

Why: the user judges the carving on the page before it lands anywhere.

Source: Ronacher, "What Actually Is Claude Code's Plan Mode?", https://lucumr.pocoo.org/2025/12/17/what-is-plan-mode/ ("a file on disk somewhere that I can see, that I can read, that I can review, that I can edit before actually acting on it").

## 3. The Org text

A sitting is a `** TODO` heading whose text is its name, with `:OUTCOME:`,
`:NEEDS:` and `:Effort: 1:30` in its property drawer; the heading carries the
tag :deep: when deep, and no tag means shallow; nothing else new. A sitting
that may be thrown away says so in its heading text. The sitting template:

#+begin_src org
** TODO <name> :deep:
:PROPERTIES:
:OUTCOME: <what exists afterwards>
:NEEDS: <what must be at hand>
:Effort: 1:30
:END:
#+end_src

One sitting is shown as that `** TODO` heading, to go under `* Tasks` in the
Area hub file or the project file the work belongs to.
Two or more sittings are shown as a project file skeleton, the whole file:

#+begin_src org
#+TITLE: <name of the work>
#+PROPERTY: AREA <Area>
#+FILETAGS: :<kind>:
#+ARCHIVE: ::* Archive

* Outcome
<the outcome from question 1, with the rule for sittings carved later, if any>

* Tasks [/]
:PROPERTIES:
:COOKIE_DATA: todo recursive
:END:
<the sittings, in order>

* Log

* Notes
#+end_src

No sub-tasks under a sitting: projects, not parents. Work that needs more
than one heading is a project file whose tasks are the sittings, never a
sitting with children.

When the count depends on an earlier sitting's result, write the rule under `* Outcome`
("one sitting per alternative, carved after sitting 3"), and the user runs
carve-work again after that sitting (agent's guess, from the basemap walk).

When a task inside a project file outgrows one sitting, it becomes its own project file beside it,
with a pointer from the old task, which keeps its devlog and clock lines,
and a line under the new file's `* Outcome` pointing back ("Carved <date>
with carve-work; the earlier task of the same name in <file> holds the
devlog and the clock lines from before the carving") (agent's guess, from the
basemap walk). File names are kebab-case under
`~/Stillness/Brain/Areas/<Area>/`.

## 4. Writing, on the user's word

The skill writes nothing until the user has seen the Org text and says to
write. On the user's word:

- Write the heading under `* Tasks` of the file the user names, or the
  project file at `~/Stillness/Brain/Areas/<Area>/<kebab-name>.org`.
- Add the `:ID:` (a fresh upper-case UUID) and `:CREATED:` (now, as an
  inactive timestamp, `[YYYY-MM-DD Day HH:MM]`) drawer to the file and to
  each heading, as every Brain heading carries.
- When the work was an existing task, add the pointer to the old task and
  leave it, its devlog and its clock lines in place.
- Schedule only when the user asks in the same session: a
  `SCHEDULED: <YYYY-MM-DD Day HH:MM-HH:MM>` line under the heading with the
  day and time the user gives; never pick the slot.
- Never delete a note (Brain rule: move it to `Archives/`). Never commit,
  push or reset; tell the user what was written.

These are the only writes the skill makes.

## 5. Worked example, home room: Reading Codebase: Flask

Area: Craft. Room: home. Kind: learn.

The walk, carved by the user on 2026-11-02:

- Q1: first answer "understand how large codebases are written … the organization … mitsuhiko's way of doing things", a goal wrapped in an activity; pinned by asking for the check: a note that names files and functions and covers one request end to end.
- Q2: "I don't know how I would start … I cloned it and started reading right away"; so sitting 1 is the first rung of the learn ladder, become a user, not reading.
- Q3, Q4, in the user's words: "a little more than hello world of Flask with its nuances highlighted"; "first build a block-size understanding of things, then later pick one and understand it"; "pick one question and understand it"; "how it sits in the bigger picture", the architecture note itself.
- Q5: four.
- Q6: "All four are deep sessions."
- Q7: the needs read back and confirmed ("everything is here").
- Q8: sitting 3 ("yes, sitting three").

Read back, the principle each sitting applied:

1. Flask as a user: become a user before reading the code, Hashimoto (Q2).
2. Block map: gather context first and leave an artifact, Zechner (Q2).
3. Trace one question: one thing at a time, verified, Karpathy (Q4); may be thrown away, Hashimoto (Q8).
4. Architecture note: summarise in your own words after building it, Karpathy (Q9).

The Org text, shown, not written:

#+begin_src org
#+TITLE: Reading Codebase: Flask
#+PROPERTY: AREA Craft
#+FILETAGS: :learn:
#+ARCHIVE: ::* Archive

* Outcome
A note on Flask's architecture and code organization: for each major part,
what it is, how it does it, and why Ronacher built it that way, naming files
and functions and covering one request end to end.

Carved 2026-11-02 with carve-work; the earlier task of the same name in
[[file:real-world-projects.org][real-world-projects.org]] holds the clock lines from before the carving.

* Tasks [0/4]
:PROPERTIES:
:COOKIE_DATA: todo recursive
:END:
** TODO Flask as a user: a small app running from source, with my questions :deep:
:PROPERTIES:
:OUTCOME: An app a step past hello world (variable routes, request and response, a template, an error handler) runs from my source clone; a note says what Flask solves and lists my "how does it do that?" questions.
:NEEDS: The Flask clone; a Python env installing it from source; the quickstart page.
:Effort: 1:30
:END:
** TODO Block map of Flask's source and the request path through it :deep:
:PROPERTIES:
:OUTCOME: A note with the main modules under src/flask, one line each; the request path from WSGI entry to response at block level; every question from sitting 1 placed on its block.
:NEEDS: The app and the questions list from sitting 1.
:Effort: 1:30
:END:
** TODO Trace one question to file and function (may be thrown away) :deep:
:PROPERTIES:
:OUTCOME: One question from the list traced: file and function names, how Flask does it, and why it is done that way.
:NEEDS: The block map from sitting 2; the one question picked.
:Effort: 1:30
:END:
** TODO Write the architecture note :deep:
:PROPERTIES:
:OUTCOME: The project's Outcome note exists, built from the map and the trace.
:NEEDS: The notes from sittings 2 and 3.
:Effort: 1:30
:END:

* Log

* Notes
#+end_src

Written to the Brain on the user's word on 2026-11-02; the skill ended with
the text shown.

## 6. Worked example, work room: Basemap with no labels and borders

Area: Impact. Room: work. Kind: decide.

The walk, carved by the user on 2026-11-02:

- Q1: "a document about how to approach … alternatives along with why and why nots"; pinned by naming the reader: "compile them in a single document and then present it to my seniors".
- Q2: "the same jumping in as in Flask … I tried to understand how Worldview is working for this feature"; the started attack, Worldview, is sitting 1. Asked for another way in, the user added Mapbox: "look for alternatives about how basemaps can be served … taking Mapbox as an example"; kept as a second context sitting beside the first.
- Q3, Q4, in the user's words: Worldview, "is it requesting different layers or hiding on the client, is it using a different provider, where is the data source"; Mapbox; "by questioning its approach I can have alternatives … design a system for that"; one per alternative, "why and why not"; "compile them in a single document and present it to my seniors".
- Q5: four now, plus one per alternative carved after sitting 3; the user does not know how many alternatives there will be. A dependency, not a cap.
- Q6: "all is deep, design thinking being mine, true."
- Q7: the needs read back and confirmed.
- Q8: the per-alternative sittings.

Read back, the principle each sitting applied:

1. Worldview: gather context from a working example first and leave an artifact, Zechner (Q2).
2. Mapbox: another way in, from the tool already in use, Hamming via Karpathy (Q2).
3. Alternatives: name the options before arguing any, Ronacher (Q1); the per-alternative sittings are carved after it (Q5), and each may be thrown away (Q8).
4. The note: summarise in your own words, for a reader, Karpathy (Q9).

The Org text, shown, not written:

#+begin_src org
#+TITLE: Basemap with no labels and borders
#+PROPERTY: AREA Impact
#+FILETAGS: :build:
#+ARCHIVE: ::* Archive

* Outcome
A note for my seniors on how to let the client hide and change labels and
borders on the MMGIS basemap, the way Worldview does: the alternatives,
each with how it works, what it requires of the map and the data, the why
and why-not, and something seen running; ending with my recommendation.

The number of alternatives is known only after sitting 3; one sitting per
alternative is carved then, each marked "may be thrown away".

Carved 2026-11-02 with carve-work; the earlier task of the same name in
[[file:mmgis.org][mmgis.org]] holds the devlog and the clock lines from before the carving.

* Tasks [0/4]
:PROPERTIES:
:COOKIE_DATA: todo recursive
:END:
** TODO How Worldview hides labels and borders :deep:
:PROPERTIES:
:OUTCOME: A note on Worldview's layer structure for labels and borders: whether the hide is a different request or a client-side hide, which provider or server serves those layers, where the data comes from; file and function names from its source or its network requests.
:NEEDS: The Worldview repository cloned; the Worldview link from the devlog; browser dev tools.
:Effort: 1:30
:END:
** TODO What Mapbox gives for several basemaps and runtime layer switching :deep:
:PROPERTIES:
:OUTCOME: A note on how Mapbox GL supports several basemaps and switching style layers at runtime, and how basemaps are served in general; the options named, the cheap ones tried on a scratch page.
:NEEDS: The Mapbox GL JS style and layer docs; the current MMGIS basemap setup; a scratch Mapbox page.
:Effort: 1:30
:END:
** TODO The alternatives for MMGIS, sketched, and the next sittings carved :deep:
:PROPERTIES:
:OUTCOME: The list of alternatives drawn from both notes, each with a one-paragraph sketch of how it would work in MMGIS and what it asks of the map and the data; one sitting carved per alternative.
:NEEDS: The notes from sittings 1 and 2; how MMGIS loads layers today.
:Effort: 1:30
:END:
** TODO The note for the seniors: alternatives compared, recommendation :deep:
:PROPERTIES:
:OUTCOME: The project's Outcome note, ready to present and discuss.
:NEEDS: Every alternative's section; a date with the seniors.
:Effort: 1:30
:END:

* Log

* Notes
#+end_src

Written to the Brain on the user's word on 2026-11-02; the skill ended with
the text shown.

## Excuse / Reality

| Excuse | Reality |
|---|---|
| "The outcome is 'work on X'." | An outcome is something you can see, run, or watch pass. Ask again with the same thing as a result. |
| "It needs five sittings, let me list all five." | Carve all five. There is no cap; the user is planning the whole task. |
| "I'll propose the breakdown, it is faster." | The user carves. Propose only after they tried, and mark it (my proposal). |
| "Deep because it is important." | Deep because the thinking is yours. Importance does not set depth. |
| "Sitting 3 adds the parser and the runtime." | One addition per sitting, each with its own check. |
| "I'll write the headings into the file now." | Show the Org text. Writing is a separate step on the user's word. |
| "Sub-tasks under the sitting would help." | Projects, not parents: no sub-tasks. |
| "The user is busy, I'll schedule it too." | Scheduling is the Shutdown ritual's job; schedule only when the user asks in this session. |
