# Kite editor: what we decided

Decided on 2026-11-06. Kite is a **powerful, lightweight code editor for people who love writing code
by hand**. It's open source, with its own clean, minimal design: no icons, just code.

The AI tutor ([TUTOR-SPEC.md](TUTOR-SPEC.md)) is on hold.

## Principles

- **Kite understands code but never writes it.** It offers navigation, errors and refactoring, but no
  popup autocomplete.
- **Pure code.** Kite has its own design, not the native macOS look: no icons, a few flat colors, and
  nothing on screen that isn't the code or directly about it.
- **Lightweight is measured, not hoped for.** See the limits below.
- **Nothing third-party runs inside Kite.** It has no plugin system. You extend it with a config file
  and shell commands.

## Look and layout (built first)

- **Kite's own window chrome**, clean and minimal. No native tab bar or macOS toolbar look.
- **Minimal text tabs:** a slim strip with only file names in small text, the active one brighter.
  No icons, and close buttons appear only on hover. An unsaved file shows a dot.
- **2-pane splits:** ⌘\\ for side by side and ⌥⌘\\ for stacked, separated by a hairline. The same file
  can be open in both panes, sharing one buffer.
- **The sidebar is text only,** with no folder or file icons.
- **Code colors:** a few flat colors on the main text color. Comments are dimmed, and strings,
  keywords, and numbers/constants each get one hue. Everything else is plain, with no bold or italic
  tricks, and it must stay readable. Dark and light versions. The current rainbow theme stays
  available as an option.
- **Bots are off by default**, turned on with View ▸ Show Bots or the config file.

## Features (order to be decided after the new look)

- **Language intelligence for navigation only:** go-to-definition (⌘-click), find references, hover
  docs, rename and error squiggles, from language servers. There's no completion popup. Optional
  word completion (⎋ or ⌃Space) offers only names already in the file.
- **Language servers are downloaded on demand** into `~/Library/Application Support/Kite/servers`.
  Kite prefers servers that run on their own (clangd, rust-analyzer, Astral's `ty` for Python,
  sourcekit-lsp from Xcode). Node-based servers (TypeScript, JS) use the Node already installed,
  with a one-line install hint if it's missing. Kite never installs a runtime itself.
- **Customizing:** `~/.config/kite/config.toml` holds the font, size, theme, tab width per language,
  keybindings, language servers and hidden files, and reloads when saved. **Bindable shell
  commands** run on the selection or the file (format with `black`, sort lines with `sort`). Theme files
  can be dropped in. No plugins.
- **Vim mode (optional, off by default):** Normal, Insert, Visual and Visual-line modes. Common
  motions and operators (w b e, 0 $, gg G, f t, d c y), counts, dot-repeat, text objects (iw, i"),
  registers, and `:w :q :s`. It works with multiple cursors.
- **Running code:** ⌘R runs the project's task, either auto-detected (`swift build`, `npm test`,
  `python file.py`, `make`, `cargo run`) or set in the config file. Output streams into a bottom panel,
  and `file:line` errors are clickable and appear as squiggles. There's no built-in terminal:
  ⌥⌘T opens your own terminal app at the project folder.
- **Git, read-only:** gutter marks for added, changed and deleted lines. Click a mark to see the old
  version or revert that chunk. Changed files are tinted in the sidebar, the branch shows in the
  status bar, and blame appears on hover (optional). Committing stays in the terminal or a git app.
- **Find and replace:** Replace in the find bar (⌥⌘F), with regex, match-case and whole-word
  toggles, and `$1` capture groups. Project Replace in Files shows a preview where you can uncheck
  changes, and can be undone per file.
- **Sessions:** quitting never prompts. Each project reopens exactly as you left it: tabs, splits,
  cursor and scroll positions, and unsaved edits, which are kept in a hidden backup. ⌘S stays manual,
  and autosave on switching away can be turned on in the config file.
- **Languages:** about 15 built in: Swift, Python, JS, TS/TSX, JSON, HTML, CSS, C, C++, Rust, Go,
  Shell, Markdown, YAML and TOML. Anything else opens as plain text, and more grammars can later
  download on demand.

## Limits every feature must stay within

Measured by a `scripts/budget.sh` script. A feature that breaks a limit doesn't ship until it's fixed.

| Limit | Value |
| --- | --- |
| App size | under 20 MB |
| Launch to typing | under 150 ms |
| Memory with a mid-size project open (language servers counted separately) | under 100 MB |
| Worst keystroke on a 5 MB file | under 8 ms |
| Scrolling | smooth at 120 fps |

## Platforms

Mac first, with Linux planned for later. New features keep their logic in the Mac-independent
modules (`EditorCore`, `Syntax`, and a future project and language-server core), behind a thin UI
layer, so a Linux UI can reuse them.

## Next

The new look (layout B · Rail) was built on 2026-11-06. Build order, decided on 2026-11-06:

1. **Languages:** the 15 built-in languages listed above. No extras for now. (Skipped for now: the
   grammars need downloading.)
2. **Session restore** (done 2026-11-07): each window reopens with its tabs, cursors, scroll positions and unsaved
   edits. Quitting never asks. Closing a tab with unsaved changes still asks (Save / Don't Save).
   With nothing to restore, Kite opens a plain window listing recent folders and files (text only).
3. **Find and replace:** regex, match case, whole word, `$1`, plus Replace in Files with a preview.
4. **Split panes:** 2 panes (⌘\\ side by side, ⌥⌘\\ stacked).
5. **Run tasks:** ⌘R with the output panel and clickable `file:line` errors.
6. **Git marks:** change bars in the gutter, changed files tinted in the list.
7. **Language servers:** go-to-definition, references, hover docs, rename, error squiggles.

Later: config file and shell commands, Vim mode. Housekeeping before step 1: `scripts/budget.sh`.
