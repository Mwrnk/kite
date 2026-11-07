# Kite tutor: what we decided

Decided on 2026-11-06. Kite is a code editor that helps people **write code by hand**. A live AI
tutor watches, teaches and nudges, but never writes the code for you.

## Who it's for

People who lean on AI and autocomplete and want to build the skill to write code themselves.

## How the tutor helps

**A help dial with 4 steps.** It sets how often the tutor speaks and how far its hints go. No step
ever gives finished, runnable code.

| Step | Speaks up on its own when… | Hints go up to |
| --- | --- | --- |
| Silent | never; only when asked | guiding questions |
| Nudge | you look stuck (long pause, the same error 3×, undo churn) | concepts |
| Coach | also mistakes as you write them, and a review after ⌘R | pseudo-code in words |
| Guide | all of the above | code shapes with blanks (`for i in ___:`) |

- **Where hints appear:** a speech bubble from Twinkle, the guide bot, which perches beside the line
  being edited. Short by default, "more" expands it, Esc dismisses it. Hint text can't be pasted
  into the editor.
- **Pasting:** multi-line pastes into Python or JavaScript files arrive as faint ghost text that you
  must type over to keep. Single lines, JSON and plain-text files paste normally. A "Keep as is"
  shortcut accepts the paste anyway, but it's marked and doesn't count toward your independence score.

## How mistakes are found

1. **Syntax errors:** instantly, from Kite's tree-sitter parser. Offline and free.
2. **Runtime errors:** ⌘R runs the file, and the tutor reads the crash or error output.
3. **Logic slips:** on a pause, Claude Haiku 5.5 (`claude-haiku-5-5`) checks only the changed code.
   The same call decides whether it's worth interrupting at the current dial step.

Explanations and hints come from Claude Sonnet 5.5 (`claude-sonnet-5-5`).

Considered and set aside: language servers (Pyright and the TypeScript server need Node, and cost
memory; maybe later), and Jev or Laya as the decider (Haiku keeps it to one provider; Laya's 2 GB
footprint breaks Kite's lightweight goal).

## AI access and privacy

- **The user's own Anthropic API key**, stored in the macOS Keychain. "Sign in with Claude" isn't
  available for third-party apps.
- **Later:** App Attest (a registered, signed macOS app gets short-lived tokens billed to Kite's
  workspace), once Kite has Developer ID signing and a way to cover usage.
- **Sent to Claude:** on a pause, only the enclosing function or block plus a short outline of the
  file (names, not bodies). Explanations the user asks for may include the whole file. A visible
  indicator shows whenever code is being sent, and one setting turns automatic checks off.

## Languages

Python and JavaScript first, both runnable with ⌘R and with tutor prompts tuned for them. Kite detects
a missing `python3` or Node and guides the install. Swift and JSON keep syntax coloring only for now.

## What you work on: two modes

- **Learn mode (built first):** pre-made lessons that teach programming concepts. A known goal and
  tests let the tutor give sharper hints and check real understanding.
- **Free mode:** your own files, plus an optional goal line ("I'm building X"). Small drills generated
  from your weak spots come later.

### Learn mode lessons

**Each concept is one lesson in 4 stages**, a pattern based on a well-tested teaching method (PRIMM),
about 10–15 minutes in all:

1. **Read and predict:** a small example; type what you think it prints.
2. **Run and compare:** run it and see where your prediction differed.
3. **Change:** modify the example to do something slightly different.
4. **Write:** write a new program from scratch, checked by tests.

Twinkle and the help dial work in every stage.

**Content:** the first version ships **12 Python concepts**: variables, strings, conditions, loops,
lists, functions, dictionaries, string building, nested loops, errors, files and classes.
Claude drafts each lesson in a simple file format (example, predict question, change task, write
task, tests). An automatic check runs every example and test, and a person approves each lesson before it
ships. JavaScript reuses the same concept path afterwards.

**Progression:** a small concept map where each concept lists its prerequisites (loops build on
conditions, nested loops on loops). A concept opens once its prerequisites are done. If you already
know one, a **test-out** (just stage 4) marks it done.

**On screen:** a narrow **lesson strip to the right of the code** shows the 4 stages as steps, the
current task, a field for your prediction, **Run (⌘R)** and **Check (⌘↩)** buttons, and test
results. The concept map opens as its own window from **Learn ▸ Concepts**.

## Progress

A private log kept only on the Mac: repeated mistakes ("off-by-one in loops: 3× this week"),
concepts you've shown you know, and an **independence score** (the share of lines written without
help). The tutor uses it to point out repeats, and a small weekly view shows the trend.

## Build order

1. ⌘R runner and output panel (Python first), API-key setup, and Twinkle's bubble answering when asked (Silent step).
2. Learn mode: the lesson file format, the lesson strip, Check with tests, the concept map with test-outs,
   and the first 12 Python lessons (AI-drafted, automatically checked, approved by a person).
3. Syntax errors, stuck detection, Haiku pause checks, and the full 4-step dial.
4. Retype-on-paste and the learning log (concepts mastered feed the independence view).
5. Free mode extras: the goal line, then drills from weak spots. JavaScript lessons.

Related: `plans/` holds the bot animation plans. 001 (the guide flies to the edited line) is done;
002 (v2 look and physics) is ready to run.
