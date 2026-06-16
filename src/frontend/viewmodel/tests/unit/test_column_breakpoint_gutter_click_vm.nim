## M6 — Headless ViewModel layer test for the column-aware gutter
## click resolver.
##
## Spec:
##   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
##   §M6 Acceptance tests — Headless ViewModel.
##
## What this test proves:
##
##   1. The pure `resolveColumnClick` resolver (used by both the View
##      layer's Monaco mouse-down handler and any future ViewModel
##      test-seam) correctly dispatches a click to *either* the
##      legacy line-only path *or* the M1 column-aware path based on
##      the Monaco-resolved column.
##   2. A click on the CodeTracer gutter HTML (`.gutter-line` /
##      `.gutter-breakpoint`) always falls back to the legacy path —
##      column ≤ 1 — even when Monaco would report a non-trivial
##      column at the same pixel.  Pins M1's back-compat invariant.
##   3. A click on the line text at the recorded fixture column
##      positions (`var b` at column 12, `var c` at column 23 of the
##      M1 fixture program) yields a column-aware resolution with
##      the correct 1-based column.
##   4. Clicks at column 1 (the line's first character or leading
##      whitespace) fall back to the legacy path — the M6
##      "column ≤ 1 → legacy" boundary.
##   5. The resolver clamps to `MonacoTextModel.getLineMaxColumn(line)`
##      when the caller supplies it, so a click past the end of the
##      line maps to the line's last column (1-based, inclusive of the
##      trailing terminator slot Monaco reports).
##
## The pixel→column mapping itself is performed by Monaco
## (`e.target.position.column`).  This test does not duplicate Monaco's
## pixel decoding — instead it pins the *dispatch* logic that decides
## which breakpoint path a click should drive once the column is
## known.  Synthetic pixel coordinates from the M1 fixture program
## (`var a = 1; var b = 2; var c = a + b;` on line 1) drive the
## resolver.
##
## Compile + run:
##
##   nim c -r src/frontend/viewmodel/tests/unit/test_column_breakpoint_gutter_click_vm.nim
##
## No external binaries are required — the resolver is a pure Nim
## function so this test runs in-process without a replay-server or
## JS recorder.

import std/[options, unittest]

import ../../../ui/column_click_resolver

# ---------------------------------------------------------------------------
# Fixture constants — mirror `column_breakpoint.spec.ts` / the M1
# headless test so the columns asserted here line up with the
# recorded steps the existing M1/M5 specs exercise.
# ---------------------------------------------------------------------------

const
  Line1 = 1
  Line2 = 2
  # `var a = 1; var b = 2; var c = a + b;`
  ColumnVarA = 1                # legacy-fallthrough boundary
  ColumnVarB = 12               # `var b` — laterStatementColumn
  ColumnVarC = 23               # `var c`
  Line1MaxColumn = 37           # `getLineMaxColumn(1)` for the fixture

suite "M6 — Column-aware gutter click resolver":

  test "test_gutter_html_click_at_var_a_falls_through_to_legacy":
    ## A click landing on the gutter HTML element at line 1 — the M1
    ## back-compat path — MUST yield a `GutterClick` regardless of
    ## what Monaco might have resolved.  The View layer drives the
    ## legacy `addBreakpoint(path, line)` for this case.
    let resolved = resolveColumnClick(
      line = Line1,
      monacoColumn = some(ColumnVarB),  # even if a column were known
      onGutterElement = true,
      lineMaxColumn = some(Line1MaxColumn))
    check resolved.kind == GutterClick
    check resolved.line == Line1
    check resolved.column == 0
    check not resolved.isColumnAware()

  test "test_gutter_html_click_at_line_2_falls_through_to_legacy":
    ## Mirror the GUI test: clicking the gutter on line 2 (single
    ## statement line) is the canonical legacy path; column stays 0.
    let resolved = resolveColumnClick(
      line = Line2,
      monacoColumn = none(int),
      onGutterElement = true)
    check resolved.kind == GutterClick
    check resolved.line == Line2
    check resolved.column == 0

  test "test_text_click_at_var_b_column_resolves_column_aware":
    ## Clicking *inside* `var b` on line 1 (Monaco resolves column =
    ## 12) MUST yield a column-aware resolution so the View layer
    ## dispatches to `addColumnBreakpoint(path, 1, 12)`.
    let resolved = resolveColumnClick(
      line = Line1,
      monacoColumn = some(ColumnVarB),
      onGutterElement = false,
      lineMaxColumn = some(Line1MaxColumn))
    check resolved.kind == ColumnAwareClick
    check resolved.line == Line1
    check resolved.column == ColumnVarB
    check resolved.isColumnAware()

  test "test_text_click_at_var_c_column_resolves_column_aware":
    ## A second column position on the same line — `var c` at column
    ## 23 — also resolves column-aware.  This pins that the resolver
    ## doesn't accidentally bake in `var b`'s offset.
    let resolved = resolveColumnClick(
      line = Line1,
      monacoColumn = some(ColumnVarC),
      onGutterElement = false,
      lineMaxColumn = some(Line1MaxColumn))
    check resolved.kind == ColumnAwareClick
    check resolved.column == ColumnVarC

  test "test_text_click_at_column_one_falls_through_to_legacy":
    ## The M6 boundary: a click resolving to column 1 — the line
    ## start — MUST fall through to the legacy path, mirroring the
    ## "Click at column ≤ 1" rule from the M6 contract.
    let resolved = resolveColumnClick(
      line = Line1,
      monacoColumn = some(ColumnVarA),
      onGutterElement = false,
      lineMaxColumn = some(Line1MaxColumn))
    check resolved.kind == GutterClick
    check resolved.line == Line1
    check resolved.column == 0
    check not resolved.isColumnAware()

  test "test_text_click_past_line_end_clamps_to_line_max_column":
    ## When the caller supplies `lineMaxColumn`, a Monaco-resolved
    ## column past the end of the line is clamped so we never emit a
    ## column outside the line's text range.  The resolved click is
    ## still column-aware (the clamped column is well above 1).
    let resolved = resolveColumnClick(
      line = Line1,
      monacoColumn = some(Line1MaxColumn + 17),
      onGutterElement = false,
      lineMaxColumn = some(Line1MaxColumn))
    check resolved.kind == ColumnAwareClick
    check resolved.column == Line1MaxColumn

  test "test_missing_monaco_column_falls_through_to_legacy":
    ## A click with no Monaco-resolved column — e.g. the click event
    ## hit a `gutter-no-trace` element where Monaco does not report a
    ## position — MUST take the legacy path.  Preserves M1 invariant.
    let resolved = resolveColumnClick(
      line = Line1,
      monacoColumn = none(int),
      onGutterElement = false)
    check resolved.kind == GutterClick
    check resolved.column == 0

  test "test_zero_line_yields_no_resolution":
    ## Sanity: a click that didn't land on a real line (line = 0)
    ## yields a `GutterClick` with `line = 0` so callers can detect
    ## and early-return.
    let resolved = resolveColumnClick(
      line = 0,
      monacoColumn = some(ColumnVarB),
      onGutterElement = false)
    check resolved.kind == GutterClick
    check resolved.line == 0
    check resolved.column == 0

when isMainModule:
  discard
