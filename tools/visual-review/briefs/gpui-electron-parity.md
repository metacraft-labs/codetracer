# Parity Review Brief — GPUI against the Electron reference

Read `tools/visual-review-brief.md` first: it says what CodeTracer is, what
each named view must show, and how Electron and GPUI relate. This brief is
for the **parity** pass of the visual-design-iteration loop
(`codetracer-pm/spec/Methodologies/visual-design-iteration.md`): the job is
not to grade either front-end on its own but to find **every visible
difference** between them, so the GPUI front-end can be made to replicate the
Electron one nearly exactly.

## What you are given

For one named view, three images of the SAME scenario (same recording, same
debugger operations, same viewport):

1. `<view>.electron.png` — the **reference**. Chromium, the shipping design.
2. `<view>.gpui.png` — the candidate. GPUI's own renderer and text shaper.
3. `<view>.side-by-side.png` — the two at full size, Electron on the LEFT.

You may also be given crops of one region of both at 2x.

## What to do, in order

1. **Verify the state.** Use the view's expected-elements block in
   `tools/visual-review-brief.md`. If BOTH captures miss the expected state,
   the scenario did not reach it: report that first and stop. If ONE misses
   an element the other draws, that is the first parity finding.
2. **Walk the screen region by region**, the same way in both: the top bar
   (menu, debugger controls, omnibar, window buttons), each pane's tab strip
   and title, each pane's body, the dividers between panes, the footer and
   status line. For each region compare:
   - **geometry**: position, width, height, padding and gaps, in pixels where
     you can estimate them ("GPUI tab strip is ~6px taller");
   - **colour**: backgrounds, text, borders, selection and highlight bands,
     icons ("GPUI pane ground is lighter, roughly #2b2b2b against #1e1e1e");
   - **typography**: family (monospace or proportional), size, weight, line
     height, letter spacing, truncation and ellipsis;
   - **iconography**: which glyphs, their size, their stroke and colour;
   - **content**: the same rows, labels and values, in the same order.
3. **Rank the differences** by how noticeable they are at a glance:
   - **P1**: missing or extra elements, a different layout, a wrong colour
     family, unreadable or clipped text;
   - **P2**: clearly visible mismatches in size, spacing, weight or colour
     shade;
   - **P3**: differences you find only by flipping between the images.

## Accepted differences — do not report these

- **The window buttons.** The Electron window is frameless and always draws
  minimise, maximise and close. The GPUI window draws the buttons the desktop
  supports and is configured for, where it is configured for them (the
  product decision for the native front-end); on the capture lane's sway
  target that is close alone. Report a button only if its shape, size or
  position differs from Electron's equivalent button.
- **A number before "No certificates"** in Electron's status bar (`4`, `14`,
  `20`): Electron's test-movement counter, drawn only under its test harness.
- **Module-level inline values left over in Electron's editor** after the
  debugger has moved into a function: chips naming `EXPRESSIONS`,
  `OPERATIONS` or `__builtins__` on module-level lines (90, 99 and 116 of
  `calc/main.py`). They are the previous flow's values, which Electron fails
  to clear when it loads the new function's flow. GPUI shows only the
  current flow's values. Every other inline-value difference is still to be
  reported.

## How to report

- Keep it under 400 words.
- Start with "State: both correct / both wrong (…) / one differs (…)".
- Then the differences, P1 first, each one line naming the region, what
  Electron does, what GPUI does, and your estimate of the gap.
- End with a **parity rating 1–10**: 10 means a person flipping between the
  two could not tell which is which; 8 means only P3 differences remain;
  5 means the same product with clearly different styling.
- Do NOT suggest code changes; describe what you see.
