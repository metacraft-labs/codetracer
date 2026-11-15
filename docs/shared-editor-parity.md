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
the named part of the environment cannot be reproduced here; **not met** —
the desktop keeps Monaco for that use, for the reason given.

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
| LSP: Nim semantic tokens | met | **L** the codetracer langserver's response (the dev shell's `nimlangserver` 1.12.0 advertises semantic tokens and never answers a range request — filed). Asked for only where Monaco's `semanticHighlighting.enabled` option is on: on the desktop Monaco sends no semantic-token request (the trace-macro scenario's language-server traffic, read for both editors), and a range request the server leaves unanswered holds up the macro trace queued behind it. Arms L4, L6. |
| Syntax highlighting (Monarch via `monarch.nim`) | met | **B** "the document's lines, coloured by the Monarch runner": the keyword span in the editor theme's keyword colour; **U** "tokens cut at decoration edges". Arms R15, R16. |
| Decorations: the execution pointer | met | **B** decorations case (whole-line class in the overlay layer); **X** the execution line after a step. Arm R7. |
| Decorations: per-line status (breakpoints, tracepoints) in the gutter | met | **U** margin classes on the first line; **B** the glyph class in the margin; **X** the glyph column after a press. Arms F4, F5. |
| Decorations: inline values | met | **U** injected content; **B** the value chip at the line's end; **X** the value chips. Arm F8. |
| Decorations: the flow overlay | met | **B** view zones push the lines below them; **U** the layout; **G** the flow specs. Arms R8, F7. |
| Editing: find and replace | met | **B** "find highlights incrementally…": the shared find session, incremental highlights, Enter / Escape, Replace All as one undo. An off-screen match is centred, and the palette's **Find: Cancel and Return** closes the shared find and restores its origin (the pack's `find-cancel-and-return-restores-the-view`, `incremental-find-walks-and-keeps-the-match`). Arms R11, R12. |
| Editing: multiple selections | met | **B** two carets drawn and typed at. |
| Editing: clipboard | met | **B** copy fills the event's `text/plain` and the core's register; paste inserts the clipboard's text. Arm R10. |
| Editing: undo and redo (PLAT-32) | met | **B** typing undone as one group, redone. |
| Editing: folding | met | **B** the chevron folds, `unfold-all` unfolds; **U** the fold's extent. Arms R9, F6. |
| Editing: bracket matching | met | **B** the bracket and its partner. Arm F9. |
| Editing: drag selection | met | **B** click, double click, drag across lines. Arm R6. |
| Pointer: where a press puts the caret | met | **B** a press on the middle of a character puts the caret after it, as Monaco's does (the scenario pack aims its text anchors there); a double or triple press is counted, by each press's event time, at the character under the pointer, so a double click on a loaded page still selects the word. Arm R22; the pack's `multiclick-selects-caret-word-line`, `tabs-survive-mode-switch`. |
| The unified-diff view | not met — Monaco's diff editor is kept | The shared editor's diff (`ui/shared_diff_editor.nim`: two shared editors behind Monaco's diff-editor API, removed lines as zones, added lines marked; **B** "the unified diff…", **U** "the unified diff's line diff", arms R17, R18, F10) draws a diff, but the desktop's review and VCS panel use more of Monaco's diff editor than it does: hidden unchanged regions with their draggable, keyboard-operable boundaries, word-level marks inside a changed line, syntax highlighting of deleted lines, and the flow's values and loop control over the diff (the Electron GUI suite with the setting on: `deepreview/deepreview-gui.spec.ts` UD-1 to UD-4 and Tests 14–16f, 21, 26–31; `vcs/vcs_unified_diff.spec.ts` UD-2). Until it does, the desktop's diff views stay on Monaco under the setting too (`ui/unified_diff.nim`). |
| Read-only mode | met | **B** a read-only editor takes no text and still moves and selects; **D** typing in Debug mode changes nothing. Arm R14. |
| The editor context menu | met | **D** the right-click menu is CodeTracer's; **G** `tests/editor/editor_context_menu_is_mode_dependent.spec.ts`. |
| Live editing for hot code reload | met | **D** Edit mode: typing, undo, `Ctrl+S` writes the file; **G** the HCR specs. |
| Theming from the design system (PLAT-46) | met | **B** the ground and the keyword colour are the `editor-theme/*` tokens; the forced-colours block. Arm R15. |
| Input through the shared router: product keymap (CUA) | met | **D** stepping keys reach the debugger, arrows move the caret, `Ctrl+S` saves. |
| Input through the shared router: Vim, Kakoune | met | **D** the palette's "Keymap: Vim" / "Keymap: Kakoune": modes, motions, operators, as the terminal and GPUI. A modal keymap's own chords are the editor's while it has the keys — Kakoune's `Ctrl+P` (back through the jump list) among them, as on the terminal. |
| What the rest of the desktop reads of Monaco | met | The tracepoint view, the flow, the review, the build panel and the page objects call Monaco directly; the shared editor answers what they read: the theme service's theme name, a layout whose minimap entry has its width and left edge (the tracepoint editor and the loop slider size themselves from them), `getModelMarkers` per owner, decorations' hover messages, content widgets placed by Monaco's preference (EXACT on its line) and hidden off the view, view zones as wide as the view, a find-widget press reported as an overlay widget without a position, Escape closing an open find, and an editor in a hidden tab drawing no lines. **B** content widgets; **G** below. Arms R23, R24. |
| Monaco's DOM where the page styles it | met | The desktop's stylesheet and its page objects address Monaco's structure, and the editor keeps it: the gutter's rows hold only the cells that exist, number last (`text_editor.styl` paints every `div` of a row with the gutter's ground); the glyph decorations in `.glyph-margin-widgets` beside a `.glyph-margin` column; the find widget's `visible` class; a contained, composited `.lines-content`, so the flow's `position: fixed` value chips are placed in the text; Monaco's font fallback; `scrollBeyondLastLine`; every cursor's line highlighted; the view state carrying every selection across a mode switch. **B** the glyph layer and the find widget's class; **X** and the scenario pack (below). Arms R19, R20, R21, A2; the gutter rows under the page's own rules are graded by the scenario pack on the desktop. |
| The differential | met, with a measured difference | **X** one scripted scenario, both editors, the same observations (the lines drawn, the execution line, the glyph column, the active line, the caret, the selection, the value chips) at each of seven points. `ci/test/shared-editor-differential.sh` runs the scenario pack's editor and tracing scenarios of the Electron lane on both editors and compares every step's status and observation: 17 of 18 the same. The difference: in `dimming-marks-only-untaken-branches`, after the stop at `shield.nr:34`, the first line drawn is 13 with Monaco and 14 with the shared editor (the last, 54, the same; the editors' heights and line heights measured equal) — the scenario's own assertions hold on both. |

## The Electron GUI suite with the setting on and off

The whole suite, but four specs that cannot run on this workstation (the
macOS capture lane, the MCR native recorder, the PLAT-59 visual recording),
each way at the same commit: 107 failures with the shared editor, 108 with
Monaco, the same tests but for five, and a rerun of those five in both modes
shows each failing or passing on either editor (timing-dependent storybook
and Noir space-ship cases). A failure common to both modes is not the
setting's; whether it predates this work is checked against `agents` with
the shared editor's commits reverted (PLAT-67's status block names the
commits and the counts).

`tests/harness/codetracer-ci-dev-shell.spec.ts` used to hang a run for 1.5
hours: `dotnet` deadlocked at start-up under an `LD_PRELOAD` shim with
LTTng-UST and ignored SIGTERM, and the synchronous child blocked the worker
past the test's own timeout. codetracer-ci commands now run with
`DOTNET_LTTng=0`, and every synchronous child in the suite is bounded by
the time left to its test (`src/tests/gui/lib/sync-child-timeout.ts`,
`tests/harness/sync-child-timeout.spec.ts`); codetracer-pm
`issues/2026-11-13-dotnet-deadlocks-at-start-up-under-an-ld-preload-shim-with-lttng-ust.md`.

## Measurements

Every figure names the commit it was taken at; see codetracer-pm
`milestones/CodeTracer-Platform.milestones.org`, PLAT-67's status block.
