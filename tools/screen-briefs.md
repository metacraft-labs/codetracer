# Per-Screen Design Briefs for Visual Audit

Each section describes exactly what must be visible, what data should be shown,
and how to evaluate the screenshot against the CodeTracer design spec.

---

## Screen 1: Normal CodeTracer Layout (reference baseline)

**Purpose**: Establish the reference baseline that all other screens are compared against.

**Expected content**:

- Toolbar: debugger step controls (forward, backward, continue icons)
- Left: FILESYSTEM panel with file tree showing `source folders > codetracer > test-programs > py_console_logs > main.py`
- Center: Editor tab `py_console_logs/main.py` with Python source code visible, line numbers, syntax highlighting (keywords in purple/blue, strings in green/orange)
- Center-right: STATE panel showing "Enter a watch expression" input, SCRATCHPAD tab
- Right: CALLTRACE panel with expandable call tree showing function names, AGENT ACTIVITY tab
- Bottom-left: EVENT LOG panel with event rows (step index, line number, event text)
- Bottom-right: TERMINAL OUTPUT panel with stdout/stderr output
- Footer: Status bar with `Python(db) | UTF-8 | stable: ready | <file path>` on the right, **BUILD | PROBLEMS | SEARCH RESULTS** labels on the right as auto-hide pane triggers
- NO session tab bar (single trace)
- NO gray empty areas — panels fill full window width

**Evaluation**: This must look like a professional IDE. Compare against VS Code's dark theme for consistency.

---

## Screen 2: BUILD Auto-Hide Pane — Successful Build (happy path)

**Purpose**: Show the BUILD pane expanded from the bottom with successful build output.

**How to trigger**: Click the "BUILD" label in the status bar footer. The BUILD pane slides up as an overlay from the bottom.

**Expected data to inject**:

```
$ nim c --sourcemap:on main.nim
Hint: used 42 lines of code
Hint: operation successful (0.8s)
Hint: [SuccessX]
```

**Expected appearance**:

- BUILD overlay visible at bottom, full-width, ~30% window height
- Overlay header: "Build succeeded" in GREEN text, with header controls (stop, clear, auto-scroll, duration "0.8s")
- Build output lines in monospace font with ANSI colors rendered (green "Hint:" text)
- "Unpin" button at top-right of overlay
- The GL layout area above is still visible behind/above the overlay
- Status bar "BUILD" label is highlighted (active state)

---

## Screen 3: BUILD Auto-Hide Pane — Failed Build (unhappy path)

**Purpose**: Show BUILD pane with compiler errors, demonstrating error parsing and color coding.

**Expected data to inject**:

```
$ cargo build
error[E0308]: mismatched types
 --> src/main.rs:42:5
  |
42 |     let x: bool = 42;
  |                   ^^ expected `bool`, found integer

warning: unused variable: `y`
 --> src/main.rs:10:9

error: aborting due to previous error
```

**Expected appearance**:

- Overlay header: "Build failed (exit code 1)" in RED text
- Error lines: red text (#f85149), clickable (underline on hover)
- Warning lines: yellow text (#d29922)
- File locations (`src/main.rs:42:5`) underlined and clickable
- ANSI colors rendered — "error" in red, "warning" in yellow, "-->" in blue
- Arrow indicators and code snippets visible in monospace

---

## Screen 4: PROBLEMS Auto-Hide Pane with Parsed Errors

**Purpose**: Show the PROBLEMS pane with structured error list from the failed build.

**Expected data**: 2 errors + 1 warning:

- ERROR: src/main.rs:42:5 — "mismatched types: expected `bool`, found integer"
- ERROR: src/main.rs:55:12 — "cannot find value `undefined_var` in this scope"
- WARNING: src/main.rs:10:9 — "unused variable: `y`"

**Expected appearance**:

- Overlay header: "3 problems (2 errors, 1 warning)" with filter buttons [All] [Errors] [Warnings]
- Error rows: red circle icon (●), file path in dim color, line:col, error message
- Warning row: yellow triangle icon (▲), same format
- Rows clickable with pointer cursor
- Grouped by file if "Group by File" is toggled

---

## Screen 5: SEARCH RESULTS Auto-Hide Pane with Results

**Purpose**: Show search results grouped by file with match highlighting.

**Expected data**: Search for "print" with 4 results across 2 files:

- src/main.py:10 — `def print_to_stdout() -> None:`
- src/main.py:15 — `print("hello world")`
- src/main.py:51 — `print("1. print using print('text')")`
- src/utils.py:3 — `from io import print_function`

**Expected appearance**:

- Overlay header: "4 results for 'print'"
- Results grouped by file: `src/main.py (3)` header, then 3 match rows
- Then `src/utils.py (1)` header, 1 match row
- Each row: line number on left, text with "print" highlighted in amber/yellow
- Clickable rows for navigation

---

## Screen 6: Auto-Hide Left — FILESYSTEM Pinned with Overlay Open

**Purpose**: Show left auto-hide strip with FILESYSTEM panel overlay.

**Expected appearance**:

- Thin vertical strip (~28px) on the left edge with vertical text "FILESYSTEM"
- Strip is TILED beside GL (not overlaying) — GL content starts after the strip
- Overlay panel slides in from left showing the FILESYSTEM file tree
- File tree shows `source folders > codetracer > test-programs > py_console_logs > main.py`
- "Unpin" button at top-right of overlay
- Overlay content is LIVE (real file tree, not placeholder)

---

## Screen 7: Multi-Tab Mode — Two Traces Loaded

**Purpose**: Show the session tab bar with multiple traces.

**Expected appearance**:

- Session tab bar visible ABOVE the GL panels (between toolbar and GL)
- Two tabs: first trace name (e.g., "py_console_logs/main.py"), second tab (e.g., "Trace 2")
- Active tab highlighted with different background
- "+" button at the right end to add new trace
- GL layout below shows the active trace's panels
- All panels show data from the ACTIVE trace

---

## Screen 8: DeepReview Standard Layout

**Purpose**: Show DeepReview mode using the standard CodeTracer GL layout with changed files.

**Expected appearance (per DeepReview-GUI.md spec)**:

- FILESYSTEM panel shows changed files with diff badges: M main.rs (+8/-3), A utils.rs (+8/-0), D config.rs (+0/-7)
- Colors: M=orange, A=green, D=red
- Editor area shows the first file's content with diff decorations (green lines for additions)
- All standard panels present: STATE, CALLTRACE, EVENT LOG, etc.
- **Must look like the normal CodeTracer layout** (Screen 1) with only the FILESYSTEM content changed and diff decorations in the editor
- NO separate "DeepReview" panel or monolithic component

**Comparison**: The reviewer should compare this against Screen 1 (normal layout) and verify that ONLY the FILESYSTEM content and editor decorations changed — everything else is identical.

---

## Evaluation Criteria (applied to ALL screens)

1. **Full-width**: Panels must fill the entire window width. NO gray empty areas.
2. **Dark theme**: Background #1e1e1e, panels #252526, borders #3c3c3c, text #cccccc
3. **Font consistency**: Monospace for code/output, system sans-serif for UI labels
4. **Professional polish**: Looks like VS Code / JetBrains, not a prototype
5. **Auto-hide overlays**: Flush with window edge, full-width for bottom, full-height for sides
6. **Status bar**: Always visible at bottom with auto-hide labels (BUILD, PROBLEMS, SEARCH RESULTS)
7. **No broken elements**: No overlapping text, no clipped content, no invisible elements

**Rating scale**: 1-3 broken, 4-5 rough, 6-7 good, 8-9 near-shipping, 10 perfect
**Target**: All screens must reach 7/10 minimum.
