# DeepReview Unified-Diff Design Brief

The reusable brief for every visual review of CodeTracer's review surface,
following
[`codetracer-specs/Methodologies/visual-design-iteration.md`](../../../codetracer-specs/Methodologies/visual-design-iteration.md).

It is read by a **disposable sub-agent**, once per screenshot. The driving
agent never looks at the image; it reads only the few hundred words the
sub-agent returns. Capture the screenshots with
`tools/visual-review/capture-deepreview-views.sh` and generate the sub-agent's
prompt with `tools/visual-review/deepreview-review-prompt.sh`; the view names
below are the ones those scripts define, and a contract suite
(`deepreview-harness-test.sh`) fails if a view exists in one place and not the
other.

---

## What You're Reviewing

CodeTracer is a time-travelling debugger. **DeepReview** is its code-review
workspace: it takes a diff and one or more recordings of the program running,
and shows the reviewer not only what changed but what the changed lines
actually did — the value each variable held, on each pass of each loop, in each
invocation of the function.

The surface under review is the **unified diff**: a changed-files list on the
left and, in the editor area, one tab per file rendering that file's hunks with
the recorded values drawn on the code. This is the view a reviewer would use
instead of GitHub's PR diff, so GitHub's diff is the bar it has to clear.

## Design Goals

- **Match CodeTracer's own dark theme exactly**: background `#1e1e1e`, panels
  `#252526`, borders `#3c3c3c`, text `#cccccc`. The light theme is meant to be
  the same layout in the light palette, equally finished — but see known gap 5:
  it does not exist yet, and the harness will not hand you a capture that
  pretends otherwise.
- **IDE-quality, not prototype-quality.** The reference points, named by the
  product owner, are GitHub's PR diff, VS Code's diff editor, and Cursor.
- **Information density without clutter.** File list, hunks, inline values and
  coverage badges must all be readable at a glance, together.
- **Continuous with the rest of the editor** — same fonts, same spacing scale,
  same border radii, same icon language as the main CodeTracer editor. A
  reviewer should not be able to tell that the diff is a different feature.
- **The values are the differentiator.** Anything that makes the recorded
  values hard to read, or that makes them fight the code they annotate, is a
  more serious problem than a spacing inconsistency of the same size.

---

## What is Expected on the Screenshot

**Verify these before evaluating anything.** Your first job is to establish
that the capture shows the state it claims to show. If an expected element is
missing, distorted, or replaced by a placeholder, report that as your **first**
finding and rate the screenshot **1-3 out of 10** regardless of how polished
the rest of the frame looks. A rating that does not distinguish "this design is
rough" from "this capture is broken" is worthless to the person reading it,
because they cannot tell which one to go and fix.

Every screenshot shows a review of a two-commit repository called
`review_corpus`, containing exactly two changed files:

- `main.nr` — Noir. A `scale` helper near the top, a wide block of unchanged
  helper functions in the middle, and `main` at the bottom running a four-pass
  loop. This is the file that was recorded, so it is the only one carrying
  values.
- `report.py` — Python. Changed in the same commit, never recorded.

### View: `review-shell`

The whole application window, on landing.

- A **changed-files list** listing **both** `main.nr` and `report.py`, each row
  carrying a status letter (`M`) and an added/removed line count.
- A **unified diff tab** open in the editor area, showing `main.nr`.
- The surrounding CodeTracer window chrome: the layout's panel headers and the
  status bar along the bottom.
- Missing-element examples: only one file in the list; an empty editor area; a
  file list with rows but no names.

### View: `diff-intraline`

A close-up of the hunk containing `fn scale(...)`.

- A **removed line** `fn scale(index: Field, factor: Field) -> Field {` and an
  **added line** `fn scale(index: Field, multiplier: Field) -> Field {`,
  adjacent, with the removed one marked in the red/deletion treatment and the
  added one in the green/addition treatment.
- The two lines are identical apart from one word (`factor` / `multiplier`).
- Missing-element examples: only one of the two lines; no add/remove colouring
  at all; a completely different function on screen.

### View: `diff-collapsed-context`

The whole diff tab for `main.nr`, in its initial state.

- At least one **collapsed-context boundary**: a horizontal band across the
  editor saying how many lines it is hiding, with a rule at its top edge and
  another at its bottom edge. It stands where unchanged source has been folded
  away, between or beside the hunks.
- At least one `@@ -N,M +N,M @@` **hunk divider**.
- **No expanded context yet** — the region is still collapsed.
- Missing-element examples: no boundary anywhere (nothing is collapsed, so this
  view is not what it claims to be); a band with no count in it; a diff showing
  the whole file with no dividers.

### View: `diff-expanded-context`

The same diff tab after the reader actuates one boundary.

- **Unchanged source lines where the boundary's band used to reach**, each
  carrying its own line number in the gutter, reading as ordinary context
  rather than as additions or removals.
- Whatever remains hidden is still behind a boundary, and the rest of the diff
  is unchanged around it.
- Missing-element examples: the band still covering the same span with no new
  lines beside it; a blank gap where the lines should be; revealed lines with
  no line numbers.

### View: `diff-flow-values`

A close-up of the recorded values on `main.nr`'s loop.

- **At least two value chips**, each a two-part chip: a **name half** reading a
  variable in angle brackets (`<contribution>`, `<total>`, `<x>`) and a **value
  half** holding a number.
- The code lines those chips describe, visible in the same frame. A chip
  belongs to the line it is drawn beside or, where the pane is too narrow for
  that, to the line directly above it.
- Several chips **side by side in one row**, in more than one group. A row that
  carries two or more groups is showing successive passes through the loop; a
  row that carries one is showing a line outside it. Both occur in this frame.
- Typically also the **in-editor invocation stepper** — a small `‹ main: call
  1 / 2 ›` control on its own row — and a **loop control**, `‹ iteration N /
  M ›`, with a slider track beside it.
- A row may end in a dim `+N`. That is a count of what the pane could not
  hold — either N more values on that line, or N more passes through the loop,
  which the loop control beside the band reaches. It is a marker, not an empty
  chip, and two rows that look identical can carry different counts, because
  what differs between them is exactly the part that is not drawn.
- **This is the view most likely to be silently broken, so be strict.**
  Missing-element examples: no chips anywhere; chips showing a name but no
  value; chips rendered as raw text with no styling; a chip strip with no code
  around it; every row carrying exactly one group.

### View: `diff-long-line`

A close-up of the changed `assert(...)` line carrying a long message.

- A **single changed line** far wider than the pane, whose text begins
  `assert(final_result == expected, "the scaled sum must equal x times the
  triangular number...`.
- Whatever the surface does at the right edge — clip, wrap, or scroll — is
  visible in the frame. That behaviour is the subject of this view.
- Missing-element examples: a short line; no line long enough to reach the
  right edge.

### View: `diff-other-language`

The diff tab for `report.py`.

- **Python source**, recognisable as Python: a `def format_row(index: int,
  value: int) -> str:` signature, a triple-quoted docstring, an f-string.
- **No Noir on screen.** If you can see `Field`, `fn main(x: Field)` or
  `let mut total`, the wrong tab is captured and that is a missing-element
  finding, not a styling one.
- **No value chips** — this file was never recorded, and empty is the correct
  answer for it. Their absence here is *not* a missing element.
- Missing-element examples: the Noir file; an empty tab; a file list with
  `report.py` selected but no diff beside it.

---

## Known gaps this campaign is closing — findings, not capture failures

These are weaknesses the surface still has. Report them as **findings** if you
see them; do **not** treat them as evidence that the capture is broken, and do
not let them alone drive a rating below 4.

This section deliberately says what is *not finished*. It does not say what
recent work fixed, and it names no property as closed — a reviewer told what to
expect to find good tends to find it, and a rating reached that way is worth
nothing. Judge everything not listed here on its own merits.

1. **Deleted lines are not syntax-highlighted.** Monaco's inline diff draws the
   old revision's lines as view zones carrying no tokens at all, whatever the
   model says, so a removed line reads in one flat colour beside an added line
   that is coloured properly. `experimental.useTrueInlineView` changes that and
   is deferred to UD-4, because it also merges each deletion and its
   replacement into a single line and that is a UX decision rather than a bug
   fix.
2. **The two `+` / `-` markers are in two columns.** Monaco's inline diff lays
   the old revision's gutter out as a separate strip to the left of the new
   one, so the `-` of a deletion and the `+` of an addition sit about 30px
   apart rather than in one rail. It is a consequence of the two-editor layout;
   UD-4 owns whether it is worth working around.
3. **The chips are not the code's colour.** They take the editor's own surface
   colour, so on a changed line the diff's add or remove wash lies behind them
   and a chip can read as part of the highlight instead of as something over
   it. Whether the annotation layer should have a colour of its own is
   undecided.
4. **The code text is cut at the pane's right edge.** A line longer than the
   pane is sheared through a glyph with no ellipsis, no fade and no visible
   scroll affordance; the corpus's `assert(...)` line is 214 characters and
   several others reach the edge. What the surface should do at that edge is
   still undecided, so report what you see there rather than assuming a bug.
5. **Monaco's collapsed-region handle sits over the line above it.** The blue
   twin bars at a fold are drawn across the lines either side of the boundary,
   so they can land on the text of the context line above.
6. **There is no light theme yet.** `default_white` builds and loads, but its
   palette is unfinished: the built light and dark Electron stylesheets differ
   in about 1.8% of their rules and both still paint `#282828`, so a window
   configured for it comes out dark. The harness refuses to write a capture
   labelled `light` that paints dark, so **you will never be handed one** — if
   a screenshot is labelled `light`, a real light palette exists and it is fair
   game to review as one.

## What to Evaluate

1. **Alignment** — gutter, line numbers, code and chips on consistent edges.
2. **Spacing** — consistent padding and margins; nothing cramped, nothing
   adrift; the vertical rhythm of the code lines unbroken by the annotations.
3. **Colour harmony** — the add/remove greens and reds against the theme
   background; do they read as part of the palette or as stock diff colours
   dropped in?
4. **Typography** — one code font, one size, deliberate weight differences;
   clear hierarchy between file header, hunk divider, code and chips.
5. **Visual weight** — where the eye lands first; whether the values compete
   with the code instead of supporting it.
6. **Legibility of the values** — can you read a chip's name and value at a
   glance, and tell which line it belongs to?
7. **Overflow behaviour** — what happens at the right edge, and whether it is
   discoverable.
8. **Professional polish** — would this ship? Where is the gap to GitHub's PR
   diff and VS Code's diff editor, specifically?
9. **Theme parity** — the light capture should be as finished as the dark one,
   not a recolour with contrast problems.

## How to Report

- Under 250 words.
- **Start with** `Expected elements: present` — or
  `Expected elements: missing <what>` / `replaced by <what>`.
- If anything expected is missing, that is the first finding and the rating is
  1-3.
- Otherwise: one sentence of overall impression, then specific issues each with
  a location ("hunk divider: text sits 2px below the vertical centre of its
  band"), then the one or two highest-priority fixes.
- Rate out of 10, on this scale:

  | Rating | Meaning                                                            |
  | ------ | ------------------------------------------------------------------ |
  | 1-3    | Broken — missing elements, wrong layout, unstyled                  |
  | 4-5    | Functional but rough — correct structure, needs significant polish |
  | 6-7    | Good — professional-looking, minor issues remain                   |
  | 8-9    | Near-shipping — polished, only nitpicks                            |
  | 10     | Perfect — nothing to change                                        |

- Return text only. Never write files, and never quote the image back.
