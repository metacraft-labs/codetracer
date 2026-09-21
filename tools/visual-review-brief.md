# Visual Review Brief — CodeTracer

> **Tier 4.** This is the gate. The tiers below it — the determinism canary,
> the perceptual thresholds and the layout assertions — exist to keep this gate
> from being re-litigated on every commit, not to replace it.
> See `codetracer-specs/Methodologies/visual-design-iteration.md` and
> `codetracer-specs/Testing/Cross-Renderer-Visual-Alignment.md`.

## What You're Reviewing

CodeTracer is a time-travelling debugger. It has **two native front-ends that
must look like one product**: an Electron front-end (Chromium, the design
reference) and a GPUI front-end (a GPU surface with its own text shaper). You
are reviewing **one capture of one named view**, and a paired capture of the
same scenario in the other front-end exists.

You will be told **which front-end** you are looking at and **which scenario**.
The scenario names a recording, a sequence of debugger operations, a viewport
and a view — and names no renderer, because one definition drives both capture
paths.

## Design Goals

- A dark, dense, professional debugger surface. The references are VS Code and
  Zed, not a marketing page.
- **The Electron front-end is the reference.** Where the reference is wrong,
  that is a change to the Electron front-end and to the design system — never a
  license for the GPUI front-end to differ.
- Monospace for code, gutter and inline values; proportional for pane titles
  and variable names.
- Information density over whitespace: a debugger pane that fits four fewer
  rows to look calmer is worse.

## What is Expected on the Screenshot

**Verify these elements are present and recognisable BEFORE evaluating
aesthetics.** If any expected element is missing, distorted, or replaced by a
placeholder, report that as the first finding and rate the screenshot **below
4/10 regardless of polish**.

This section is what lets you distinguish three findings that otherwise
collapse into one low rating:

1. the scenario did not reach the state — **both** captures wrong, the same way;
2. one front-end failed to draw something the other drew — an **alignment
   defect**;
3. both drew it and one looks worse — a **design finding**.

### View: `shell` — scenario `entry-shell`, viewport wide (1920x1080)

- A **debug-controls strip** across the top, with the nine transport buttons
  (run-to-entry, continue, reverse-continue, step-out, reverse-step-out,
  step-in, reverse-step-in, next, reverse-next) as distinct icons.
- A **source editor** occupying the left three-quarters of the body, showing
  the recorded program's text with **line numbers in a gutter**.
- A **call-trace pane** and a **state pane** on the right.
- **The state pane is legitimately sparse here**: this scenario is *not*
  stepped, and a program at its entry point genuinely has no locals. An empty
  variable list is the correct picture. Report it as a finding only if the pane
  is *missing*, unlabelled, or shows an error.
- No modal, no overlay, no spinner.

### View: `editor` — scenario `stepped-editor`, viewport wide (1920x1080)

- Everything in `shell`, plus:
- An **execution-pointer mark** on exactly one gutter row, and the
  corresponding source row visually distinguished (a highlighted line
  background, not only a gutter glyph).
- The **state pane now lists variables** — name, type and value per row. It is
  not empty. An empty state pane here is a first-order finding.
- The **call-trace pane lists frames**, with one marked as current.
- Line numbers are **contiguous ascending integers**; no gaps, no repeats, no
  `0`.

### View: `state` — scenario `advanced-state`, viewport laptop (1440x900)

- Everything in `editor`, at a narrower window, plus:
- **Inline value annotations beside source rows**: `name: value` chips rendered
  on or next to the executed lines, not in a separate panel.
- The state pane's rows must **differ** from `stepped-editor`'s — this scenario
  is three statements further along. Two identical state panes across these two
  scenarios is a finding.
- At the narrower viewport, **nothing is clipped**: no truncated pane title, no
  horizontally scrolled toolbar, no value text cut mid-glyph.

### View: `calltrace` — scenario `returned-calltrace`, viewport laptop (1440x900)

- Everything in `editor`, plus:
- The **call trace shows the caller's frame as current**, not the callee's: this
  scenario steps into `evaluate` and steps back out, so `main` is current and
  `evaluate` is behind it.
- The editor shows **the caller's source** — `main`'s body, not `evaluate`'s —
  and the execution pointer is on the statement **after** the call, never inside
  the callee. Measured 2026-09-21: line 110, one past the `evaluate(...)` call
  on line 109.
- The state pane is **populated and labelled**, and the call-trace pane — not
  the state pane — is what shows that a frame was returned from. Measured
  2026-09-21 and recorded here so the next reviewer does not re-derive it: the
  state pane's `Locals` tab shows the MODULE's names (`EXPRESSIONS`,
  `OPERATIONS`, `__file__`, ...) rather than `main`'s own `results` /
  `expression` / `value`, even though the call trace correctly marks `main` as
  the current frame. Whether that is a defect is a product question this
  document does not own; it is filed as a tier-4 finding rather than asserted
  here, because an expected-elements block that demands the behaviour somebody
  has not yet decided on fails every capture for a reason the reviewer cannot
  act on.

### View: `eventLog` — scenario `continued-event-log`, viewport wide (1920x1080)

- The **event-log pane is populated** — a dense table with an id column, a kind
  column and a value column, and a visible row count in its footer.
- The table has **column headers** and its rows are aligned to them.
- The transport buttons are still present and the session has not ended in an
  error banner.

### View: `editorWithMark` — scenario `breakpoint-editor`, viewport laptop (1440x900)

- Everything in `editor`, at the narrower window, plus:
- **A breakpoint mark in the gutter on exactly one row**, distinct from the
  execution pointer and distinct from an empty gutter cell.
- The breakpoint glyph and the execution pointer are **simultaneously legible**
  — they occupy different lanes rather than overwriting each other.

## What to Evaluate

1. **Alignment** — consistent edges, pane boundaries meeting cleanly, the
   gutter's right edge and the code's left edge stable down the column.
2. **Spacing** — consistent padding and row height; nothing cramped, nothing
   loose enough to cost a row.
3. **Colour harmony** — one dark palette; the execution line, the breakpoint
   and the inline values must each be findable without being loud.
4. **Typography** — monospace for code/gutter/values, proportional for titles;
   a clear hierarchy between pane title, row label and value.
5. **Visual weight** — the editor dominates, the state and call-trace panes
   support it, the toolbar recedes.
6. **Professional polish** — shipping product versus prototype.
7. **Cross-front-end plausibility** — given that a paired capture exists,
   would a user who has used the other front-end recognise this one as the same
   product?

## How to Report

- Keep under 200 words.
- **Start with**: `Expected elements: present / missing-X / replaced-by-Y`.
- If anything expected is missing, report that **first** and rate **≤ 4**.
- Otherwise lead with the overall aesthetic impression in one sentence.
- List specific issues **with locations** — "state pane header: gap too large",
  not "spacing is off".
- End with the 1–2 highest-priority fixes.
- Rate 1–10.

| Rating | Meaning |
| --- | --- |
| 1-3 | Broken — missing elements, wrong layout, unstyled |
| 4-5 | Functional but rough — correct structure, needs significant polish |
| 6-7 | Good — professional-looking, minor issues remain |
| 8-9 | Near-shipping — polished, only nitpicks |
| 10 | Perfect — nothing to change |

**A numeric rating is a summary of the findings ledger, not a substitute for
it.** "9/10" is not a gate; "zero unresolved P1 and P2 findings" is.

## The mutation arm, stated here because this file is half of it

The methodology's checklist item 7: *deliberately break a view and confirm the
review surfaces a "missing element" finding; if it does not, your brief's
expected-elements block is too vague.*

`src/frontend/gpui/tests/run-plat35-visual-mutations.py` breaks **one pane in
one front-end** and requires two things at once: the tier-3 comparison must
redden, **and** the expected-elements block for that view must name an element
the broken capture no longer has. The second half is graded against **this
file**, by matching the block's named elements against the answer set the
broken front-end produced — so a block that says "the panes look right" passes
nothing and fails the arm.

That is why every block above names **concrete, countable** things — a gutter
mark on exactly one row, a non-empty variable list, a table with a footer row
count — rather than qualities.
