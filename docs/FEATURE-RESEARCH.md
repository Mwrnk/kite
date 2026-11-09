# What Kite needs next: feature research

Researched on 2026-11-07. The question: which features make Kite more powerful and more useful,
without losing what it is: a fast, lightweight editor for people who write code by hand.

## How this was researched

- Read what the editors people pick for speed actually ship: Sublime Text, Zed, Helix, and the
  native Mac editors (BBEdit, CotEditor, Nova). Sources are listed at the end.
- Read why people move between editors. People who leave VS Code for Sublime mostly cite speed.
  When they go back, they say they missed the sidebar, git, debugging and language smarts.
- Checked usage data. VS Code is used by about 76% of developers (Stack Overflow 2025), but
  lean editors keep very loyal users: Neovim had the highest "admired" score in one summary.
- Weighed each feature against Kite's rules ([EDITOR-SPEC.md](EDITOR-SPEC.md)): it never writes
  code for you, the screen shows only text, it has no plugins, and every feature must stay within
  the measured limits.

## What Kite has today

Tabs, a text-only file list, quick open (⌘P), multiple cursors (⌘D, ⇧⌘L, ⌥-click, cursors
above/below), find and replace with regex and find in selection, project search and Replace in
Files with a preview, session restore with unsaved edits, a recent-folders start window, syntax
colors through tree-sitter for Swift, Python, JavaScript and JSON, bracket matching, indent
guides, word wrap, and toggle comment, indent and move line. It's 6–7 MB, launches in about
150 ms, and stays under 8 ms per keystroke on a 5 MB file.

## What the field offers

| Feature | Sublime | Zed | Helix | Mac editors | Kite |
| --- | --- | --- | --- | --- | --- |
| Open file by name | Goto Anything | ⌘P | picker | yes | ⌘P |
| Go to symbol in file | `@` in Goto Anything | ⇧⌘O | picker (LSP) | BBEdit function menu | **missing** |
| Go to symbol in project | yes (index) | ⌘T (LSP) | picker (LSP) | some | missing |
| Command palette | ⇧⌘P | ⇧⌘P | `:` / space | Nova | **missing** |
| Expand selection by syntax | yes | yes | ⌥O / ⌥I | no | **missing** |
| Multiple cursors | yes | yes | yes | some | yes |
| Split panes | yes | yes | yes | CotEditor, Nova | missing (planned) |
| Go to definition, references | index / LSP | LSP | LSP | Nova | missing (planned) |
| Errors inline | LSP | LSP | LSP | Nova | missing (planned) |
| Run commands / tasks | build systems | tasks | shell pipes | BBEdit scripts | missing (planned) |
| Git marks | yes | yes | yes | Nova | missing (planned) |
| Code folding | yes | yes | no | yes | missing |
| Line tools (duplicate, sort, join, case) | yes | yes | yes | yes | **mostly missing** |
| Per-project indent settings | `.editorconfig` | `.editorconfig` | yes | BBEdit `.editorconfig` | **missing** |
| Vim keys | Vintage | yes | it's modal | no | missing (planned) |
| Minimap | yes | yes | no | Nova | not wanted |
| Plugins | Python | extensions | none | some | not wanted |

## What matters for Kite

Three findings shape the list.

1. **Tree-sitter can do a lot without a language server.** Helix's syntax motions and Pulsar's
   symbol list run on the parse tree alone. Kite already keeps a parse tree for every file, so
   go-to-symbol, syntax selection and folding cost almost nothing: no extra process, no download,
   no memory to speak of. These give much of the "IDE feel" while staying lightweight.
2. **Discoverability without icons needs a command palette.** Kite has no toolbar and no icons
   by design. A ⇧⌘P list of every command, with its shortcut, is how a text-only editor stays
   learnable.
3. **Small editing tools are what hand-coders reach for all day.** Duplicate line, delete line,
   join lines, sort lines and change case are in every editor people praise for speed. Each is a
   few lines of code.

## The list, in build order

Effort: S is under a day, M a few days, L a week or more. Weight: what it adds to app size,
memory or launch.

### Now: cheap, high value, no new weight

| # | Feature | What it does | Effort | Weight |
| --- | --- | --- | --- | --- |
| 1 | Go to Symbol (⌘T), **built** | A quick-open style list of the file's functions, types and methods, from the parse tree. Type to filter, Return to jump. | S | none |
| 2 | Expand / shrink selection, **built** | ⌃⇧⌘→ grows the selection to the enclosing syntax node (word → call → statement → block); ⌃⇧⌘← goes back. | S | none |
| 3 | Line tools, **built** | Duplicate line (⇧⌘D), delete line (⇧⌘K), join lines (⌃J), sort lines, upper / lower / title case. All work with multiple cursors. | S | none |
| 4 | `.editorconfig` | Uses the project's indent style and size, trims trailing whitespace and adds a final newline on save, when the file asks for it. | S | none |
| 5 | Command palette (⇧⌘P) | Every menu command in a filterable text list, with its shortcut. | S | none |
| 6 | Current symbol in the status line, **built** | The name of the function the caret is in, next to the position: a text breadcrumb instead of sticky headers. | S | none |

### Next: already planned in the spec

| # | Feature | Notes | Effort | Weight |
| --- | --- | --- | --- | --- |
| 7 | Split panes (⌘\\, ⌥⌘\\) | Two panes, same buffer allowed. | M | small |
| 8 | Run tasks (⌘R) | Auto-detected command, output panel, clickable `file:line`. | M | small |
| 9 | Git marks | Gutter bars from `git diff` (run as a process, no library), changed files tinted. | M | small |
| 10 | Code folding | Fold the syntax node at a line; folds are text (`…`), no triangles. | M | none |
| 11 | More languages | TypeScript, Go, Rust, C, HTML, CSS, Markdown, YAML, TOML, Shell. Needs your OK: each grammar is vendored source code and adds roughly 0.3–2 MB. | M | 5–10 MB in total |

### Later: heavier, opt-in

| # | Feature | Notes | Effort | Weight |
| --- | --- | --- | --- | --- |
| 12 | Language servers | Go to definition (⌘-click), references, hover docs, rename, error squiggles. Servers download on demand and run as separate processes. | L | outside Kite's memory limit |
| 13 | Config file | `~/.config/kite/config.toml`: font, theme, keys, shell commands. | M | none |
| 14 | Vim mode | Off by default. | L | none |

### Not doing

Minimap (noise on screen), plugins (a weight and safety cost Kite avoids), a built-in terminal
(⌥⌘T opens yours), AI completion (Kite never writes the code).

## Proving the speed

From the earlier discussion, in order of strength: input-to-screen latency measured with an outside
tool (Typometer) against other editors on the same Mac; a public benchmark page with scripts anyone
can rerun; `budget.sh` in CI on every commit; an optional speed readout in the status line; short
unedited demos on huge files.

## Sources

- [Sublime Text](https://www.sublimetext.com/) feature page
- [Zed: finding and navigating](https://zed.dev/docs/finding-navigating.html), [outline panel](https://zed.dev/docs/outline-panel), [comparisons](https://zed.dev/compare)
- [Helix: syntax-aware motions](https://docs.helix-editor.com/syntax-aware-motions.html), [Helix keymap](https://github.com/helix-editor/helix/blob/cc66db3fed81c5bdc8b83baccb509102c78fd10f/book/src/keymap.md)
- [Pulsar: tree-sitter symbols without ctags](https://pulsar-edit.dev/blog/20240122-savetheclocktower-modern-tree-sitter-part-6.html), [symbol-provider-tree-sitter](https://web.pulsar-edit.dev/packages/symbol-provider-tree-sitter)
- [BBEdit programming features](https://www.barebones.com/products/BBEdit/featuresdev.html), [TechTarget: macOS code editors](https://www.techtarget.com/searchsoftwarequality/tip/Essential-macOS-code-editors), [toolradar: CotEditor vs Nova](https://toolradar.com/compare/coteditor-vs-nova-editor)
- [EditorConfig](https://editorconfig.org/)
- [Stack Overflow Developer Survey 2025](https://survey.stackoverflow.co/2025/technology/), [Visual Studio Magazine on the survey](https://visualstudiomagazine.com/articles/2025/08/01/stack-overflow-dev-survey-visual-studio-vs-code-hold-of-ai-ides-to-remain-on-top.aspx?p=1), [Second Talent: most used IDEs](https://www.secondtalent.com/resources/most-used-ides/)
- [Why I switched from VS Code to Sublime Text](https://dev.to/restoreddev/why-i-switched-from-visual-studio-code-to-sublime-text-28k0) and its comments
