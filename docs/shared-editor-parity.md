# The shared editor on the desktop — parity with Monaco

The desktop's editor pane can draw the shared editing core — the editor the
terminal draws as cells and the GPUI window as elements — instead of Monaco.
It is a **developer setting**, off by default:

- `sharedEditor: true` in the configuration (`~/.config/codetracer/.config.yaml`);
- `CODETRACER_SHARED_EDITOR=1` (or `=0`) for one launch;
- the command palette's **Developer: Toggle Shared Editor** in a running
  window: every open source editor re-mounts with the other editor, keeping
  its text, caret line and scroll.

Monaco stays the default until every row below is met. Whether to drop Monaco
is a later decision taken on this table (codetracer-pm
`spec/Architecture/Editor-ViewModel.md` §3.2a).

## How it is built

| Piece | Where |
|---|---|
| The frame as a value: line index, Monaco columns ↔ core bytes, decorations in the core's `DecorationSet`, folding, the vertical layout with view zones, spans, brackets, the line diff | `src/frontend/view_vocabulary/editor_dom_frame.nim` |
| The DOM renderer, input (keys, pointer, composition, clipboard), the find widget | `src/frontend/ui/shared_editor.nim` |
| Monaco's editor and model API over the core (what `ui/editor`, `ui/flow`, `ui/trace`, the LSP router and the page objects call) | `src/frontend/ui/shared_editor_facade.nim` |
| Language features through the LSP router's bridge | `src/frontend/ui/shared_editor_lsp.nim` |
| The unified diff on two shared editors | `src/frontend/ui/shared_diff_editor.nim` |
| The setting | `src/frontend/ui/shared_editor_flag.nim`, `common/config.nim` (`sharedEditor`) |
| Keys through the shared router | `src/frontend/ui/key_router.nim` (`routeSharedEditorKey`, `runSharedEditor`) |

## The checklist

Status: **met** — the row's behaviour matches Monaco's on the desktop and a
test fails when it is broken (the harness arm named); **met, with a
measured difference** — the behaviour matches and a stated, measured property
does not; **not exercised** — the code path is implemented and graded, and
the named part of the environment cannot be reproduced here.

Suites: **U** `src/frontend/viewmodel/tests/unit/test_editor_dom_frame.nim`
(vm-unit, vm-unit-js); **B** `src/frontend/tests/shared_editor_chromium_test.nim`
and **L** `src/frontend/tests/shared_editor_lsp_chromium_test.nim`
(renderer-chromium, headless Chromium, trusted input); **D**
`src/tests/gui/tests/shared-editor/shared_editor_desktop.spec.ts` and **X**
`editor_differential.spec.ts` (the Electron GUI suite); **G** the whole Electron
GUI suite run with `CODETRACER_SHARED_EDITOR=1`. Arms are
`src/frontend/tests/run-plat67-shared-editor-mutations.py`'s.

| Row | Status | Evidence |
|---|---|---|
| IME and composition (CJK) | met | **B** "an input method's composition…": Chromium's IME entry points (`Input.imeSetComposition`, `Input.insertText`) compose `にほ` (shown, nothing committed) and commit `日本` through the core's `insert-text`, one undo step. Arms R2, F2. |
| Dead keys | met | **B** same case: the accent composed, `é` committed — the composition path Chromium delivers a dead key on. |
| Text the OS input method produces (an OS IME daemon) | not exercised | The host has `ibus-daemon` with only the `simple` (XKB) engine and no CJK engine; Xvfb lanes run no IM daemon, so an OS IME's own candidate window is not driven. The renderer side it feeds (composition events into the text area) is the row above. |
| Accessibility: screen reader reads lines and the caret | met | **B** "a screen reader reads…": the accessibility tree (`Accessibility.getFullAXTree`) has a focused multi-line `textbox` whose value is the caret's line and whose name says line and column; read-only says so. Arm R3. |
| Accessibility: focus order | met | **B** "the editor is in the page's focus order": Tab / Shift+Tab. Arm R4. |
| Accessibility: high-contrast themes | met | **B** "a forced-colours theme…": `forced-colors: active` paints the selection `Highlight` and the ground `Canvas`. Arm R5. |
| Huge files (PLAT-24's bar) | met, with a measured difference | **B** "a 200,000-line file opens, scrolls and edits…": opens in ~0.3–0.6 s, draws only the viewport, reveals line 150,000; the PLAT-24 gate — `Enter` at line 1 ÷ at the last line under 4× — holds (0.5–1.4×). The measured difference: one keystroke at 200,000 lines costs ~1.5–3 s in the renderer's debug build (Monaco: milliseconds), the core's per-operation derivation and state copies on the JS backend (`viewmodel/editor/operations.nim`, `wrap.nim`); at 1,000 lines a key costs ~20–25 ms. Arms R13, F1, F3. |
| LSP: diagnostics | met | **L** "the router's diagnostics squiggle their spans": the router's `setModelMarkers` reaches the shared model. Arm A1. |
| LSP: hover | met | **L** against the dev shell's real `nimlangserver`. Arm L1. |
| LSP: completion | met | **L** `Ctrl+Space`, the server's items, Enter inserts. Arm L3. |
| LSP: go to definition | met | **L** `F12` where the keymap leaves it, Ctrl+click in a writable editor. Arms L2, L5. |
| LSP: Nim semantic tokens | met | **L** the codetracer langserver's response (the dev shell's `nimlangserver` 1.12.0 advertises semantic tokens and never answers a range request, which also stalls Monaco's provider — filed). Arm L4. |
| Syntax highlighting (Monarch via `monarch.nim`) | met | **B** "the document's lines, coloured by the Monarch runner": the keyword span in the editor theme's keyword colour; **U** "tokens cut at decoration edges". Arms R15, R16. |
| Decorations: the execution pointer | met | **B** decorations case (whole-line class in the overlay layer); **X** the execution line after a step. Arm R7. |
| Decorations: per-line status (breakpoints, tracepoints) in the gutter | met | **U** margin classes on the first line; **B** the glyph class in the margin; **X** the glyph column after a press. Arms F4, F5. |
| Decorations: inline values | met | **U** injected content; **B** the value chip at the line's end; **X** the value chips. Arm F8. |
| Decorations: the flow overlay | met | **B** view zones push the lines below them; **U** the layout; **G** the flow specs. Arms R8, F7. |
| Editing: find and replace | met | **B** "find highlights incrementally…": the shared find session, incremental highlights, Enter / Escape, Replace All as one undo. Arms R11, R12. |
| Editing: multiple selections | met | **B** two carets drawn and typed at. |
| Editing: clipboard | met | **B** copy fills the event's `text/plain` and the core's register; paste inserts the clipboard's text. Arm R10. |
| Editing: undo and redo (PLAT-32) | met | **B** typing undone as one group, redone. |
| Editing: folding | met | **B** the chevron folds, `unfold-all` unfolds; **U** the fold's extent. Arms R9, F6. |
| Editing: bracket matching | met | **B** the bracket and its partner. Arm F9. |
| Editing: drag selection | met | **B** click, double click, drag across lines. Arm R6. |
| The unified-diff view | met | **B** "the unified diff: removed lines as zones, added lines marked, decorations per side" (Monaco's diff-editor structure and API over two shared editors); **U** "the unified diff's line diff"; **G** `tests/vcs/vcs_unified_diff.spec.ts` with the setting on. Arms R17, R18, F10. |
| Read-only mode | met | **B** a read-only editor takes no text and still moves and selects; **D** typing in Debug mode changes nothing. Arm R14. |
| The editor context menu | met | **D** the right-click menu is CodeTracer's; **G** `tests/editor/editor_context_menu_is_mode_dependent.spec.ts`. |
| Live editing for hot code reload | met | **D** Edit mode: typing, undo, `Ctrl+S` writes the file; **G** the HCR specs. |
| Theming from the design system (PLAT-46) | met | **B** the ground and the keyword colour are the `editor-theme/*` tokens; the forced-colours block. Arm R15. |
| Input through the shared router: product keymap (CUA) | met | **D** stepping keys reach the debugger, arrows move the caret, `Ctrl+S` saves. |
| Input through the shared router: Vim, Kakoune | met | **D** the palette's "Keymap: Vim" / "Keymap: Kakoune": modes, motions, operators, as the terminal and GPUI. |
| The differential | met | **X** one scripted scenario, both editors, the same observations (the lines drawn, the execution line, the glyph column, the active line, the caret, the selection, the value chips) at each of seven points; `ci/test/shared-editor-differential.sh` runs the scenario pack's editor scenarios (`src/tests/scenarios/editor/…`) on both editors and compares every step's status and observation. |

## Measurements

Every figure names the commit it was taken at; see codetracer-pm
`milestones/CodeTracer-Platform.milestones.org`, PLAT-67's status block.
