# Kite

A small, fast, native code editor for macOS, for people who write code by hand. Swift + AppKit, Core Text
drawing, tree-sitter syntax, and its own minimal look: one background, hairlines, text instead of icons.
The base for a live AI code tutor (coming later).

## Build and run

```bash
scripts/bundle.sh            # builds build/Kite.app (release)
open build/Kite.app
swift test                   # 76 tests: buffer, editing, undo, multiple cursors, brackets, search, syntax
```

While developing you can run the binary directly with files: `.build/debug/Kite file.swift`.

## How it's put together

| Module | What it does | AppKit? |
|---|---|---|
| `EditorCore` | `PieceTable` (text storage, UTF-8), `TextBuffer` (line index, UTF-16 bridge, edit events), `TextEditor` (selection, every editing command, undo), `TextFileCodec` (encodings, line endings) | No |
| `Syntax` | Tree-sitter parsing on a background queue, highlight queries with `#eq?`/`#match?`/`#any-of?` | No |
| `Kite` | The app: `EditorView` (Core Text, only visible lines), gutter, find bar, status bar, `NSDocument`, menus, `BotsOverlay` (the little bots) | Yes |
| `Vendor/` | tree-sitter v0.27.1 and the Swift, Python, JavaScript and JSON grammars, compiled from source | – |

Every buffer change emits a `BufferEdit` (byte range + row/column). Syntax parsing listens to it,
and the AI tutor will too.

**Adding a language:** copy the grammar's `src/` into `Vendor/grammars/<name>`, add a target in
`Package.swift`, add a case to `Language`, and copy its `queries/highlights.scm` to
`Sources/Syntax/Queries/<name>.scm`.

## Developer tools (no screen needed)

```bash
Kite --render file.swift out.png [--light] [--line N] [--select A:B] [--find text]
     [--wrap] [--project DIR] [--quick-open QUERY] [--search QUERY] [--cursors A,B,…]
KITE_SNAPSHOT=out.png Kite folder file   # saves the real window as drawn, then quits
Kite --bench big-file.swift          # load, parse, typing and scrolling timings
Kite --selftest-save file.py         # opens, edits, saves and checks the bytes on disk
scripts/budget.sh                    # builds release and checks size, launch, memory, typing, scroll
```

Environment switches: `KITE_NO_SESSION=1` neither restores nor saves the session;
`KITE_SESSION_DIR=dir` keeps it somewhere else; `KITE_TEST_SCRIPT=edit-and-quit|report|start-return|note-recent`
drives the running app for end-to-end checks.

## The window

One window per project: the file list on the left (text only; folders end in `/`, the open file is
brighter), Kite's own text tabs on top (a dot marks unsaved files, × appears on hover, middle-click
closes), the open file, and one status line at the bottom. Window buttons appear when the pointer
nears the top edge. Colors are flat: dimmed comments plus one hue each for keywords, strings and
numbers (View ▸ Rainbow Colors brings back the many-color theme). Bots are off unless turned on in
View ▸ Show Bots. The design is documented on the Kite Editor Design canvas and in
[docs/EDITOR-SPEC.md](docs/EDITOR-SPEC.md).

## Sessions

Quitting never asks to save. Next launch, every window comes back with its folder, size, tabs,
cursors and scroll positions, and unsaved edits come back still unsaved (their text is kept in
`~/Library/Application Support/Kite/backups` until you save or close the file). Closing a tab with
unsaved changes still asks. With nothing to restore, or when you click the Dock icon with no windows
open, Kite shows a plain list of recent folders and files: ↑↓ and Return, or click.

## Projects

Open a folder with **File ▸ Open Folder…** (⇧⌘O), `Kite path/to/folder`, or by dropping it on the Dock
icon. The file list (⌃⌘S) shows its files; `.git`, `node_modules`, `.build`, `build`, `__pycache__` and
similar are hidden, and the tree updates when files change on disk. Any file you open from inside the
folder joins the project.

- **⌘P** quick open: type a few letters of a file name (`edv` → `EditorView.swift`).
- **⇧⌘F** search the whole project. Results are grouped by file and appear as they're found;
  click one to open it with the match selected. Binary files and files over 4 MB are skipped.

## Shortcuts

**Editing:** ⌘/ toggle comment · ⌘] / ⌘[ indent/outdent · ⌥↑ / ⌥↓ move line · ⌘C with nothing
selected copies the line · ⌘L go to line.

**Multiple cursors:** ⌥-click adds a cursor (⌥-click it again to remove it) · ⌘D selects the word,
then adds the next match · ⇧⌘L puts a cursor on each selected line · ⌥⌘↑ / ⌥⌘↓ add a cursor above/below ·
Esc back to one cursor. Typing, deleting, Return, Tab, cut, copy and paste work at every cursor;
copying from N cursors and pasting into N cursors gives each its own line.

**Tabs and windows:** ⌘W close tab · ⇧⌘W close window · ⌃Tab / ⌃⇧Tab next/previous tab.

**Find:** ⌘F find · ⌘G / ⇧⌘G next/previous · ⌘E use selection · ⇧⌘F find in project · ⌘P quick open.

**View:** ⌥Z word wrap (wrapped rows keep the line's indentation; off automatically for files over
200,000 lines) · ⌃⌘S file list · ⌘+ / ⌘- / ⌘0 text size · ⇧⌘B show/hide bots.

The editor outlines the bracket matching the one at the cursor (ignoring brackets inside strings and
comments) and draws faint indent guides. Standard macOS text keys (⌥←, ⌘←, ⌃K, …) all work.
