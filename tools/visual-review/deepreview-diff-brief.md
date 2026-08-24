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

- At least one **collapsed-context boundary**, reading
  `... Expand N lines above` or `... Expand N lines below`, sitting between or
  beside the hunks. Today it is a *line of the document*; that is the thing
  UD-2 replaces, and it is expected to be present here.
- At least one `@@ -N,M +N,M @@` **hunk divider**.
- **No expanded context yet** — the collapsed region is still collapsed.
- Missing-element examples: no `Expand` boundary anywhere (the region is not
  collapsed, so this view is not what it claims to be); a diff showing the
  whole file with no dividers.

### View: `diff-expanded-context`

The same diff tab after the reader actuates one boundary.

- **Revealed context lines** where a boundary used to be: unchanged source
  lines carrying their own line numbers in the gutter, visually distinct from
  both the added/removed lines and from the boundary control.
- The rest of the diff is unchanged around them.
- Missing-element examples: still showing `Expand N lines` in the place the
  lines should have appeared, with no new lines; a blank band where the
  expansion happened.

### View: `diff-flow-values`

A close-up of the recorded values on `main.nr`'s loop.

- **At least two inline value chips**, each a two-part chip: a **name half**
  reading a variable in angle brackets (`<contribution>`, `<total>`, `<x>`) and
  a **value half** holding a number, drawn at the end of the code line the
  variable belongs to.
- The code lines those chips annotate, visible in the same frame.
- Typically also the **in-editor invocation stepper** — a small `‹ main: call
  1 / 2 ›` control on its own row.
- **This is the view most likely to be silently broken, so be strict.**
  Missing-element examples: code lines with no chips after them at all; chips
  showing a name but no value; chips rendered as raw text with no styling; a
  chip strip with no code around it.

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

These are real weaknesses of the current surface. Report them as **findings**
if you see them; do **not** treat them as evidence that the capture is broken,
and do not let them alone drive a rating below 4.

1. **Syntax highlighting is partial, and where it fails it fails oddly.**
   UD-1 replaced the `plaintext` document with a Monaco diff editor over two
   models carrying the reviewed file's real language, so a tokenizer now runs
   — but it runs over a *window* of the file rather than the whole of it, and
   a tokenizer starts from ITS line 1. A hunk that begins inside a block
   comment or a multi-line string is therefore tokenized as if that string had
   just opened, and everything after it comes out flat. `tools/report.py`'s
   first hunk starts on line 4, inside the module docstring, so the
   `diff-other-language` view shows exactly this: two English words coloured
   as keywords inside the docstring, and the code below it in one colour.
   Report it — it is real — but it is a *known* consequence of windowed
   models, and UD-2 (whole-file models with `hideUnchangedRegions`) is what
   closes it, not a colour change.
   **Deleted lines are separately not highlighted**: Monaco's inline diff view
   draws them as view zones with no tokens at all, whatever the model says.
   `experimental.useTrueInlineView` fixes that and is deferred to UD-4,
   because it also merges each deletion and insertion into one line and that
   is a UX decision.
2. **Word-level intra-line marking — CLOSED by UD-1.** The changed word inside
   a partially-changed line is now marked, on both sides, by Monaco's own diff.
   It is the single property that most separates this surface from GitHub's, so
   if `diff-intraline` shows a whole line tinted and no inner mark, that is a
   regression and worth leading with.
2b. **The two `+` / `-` markers are in two columns.** Monaco's inline diff lays
   the old revision's gutter out as a separate strip to the left of the new
   one, so the `-` of a deletion and the `+` of an addition are about 30px
   apart rather than in one rail. It is a consequence of the two-editor layout;
   UD-4 owns whether it is worth working around.
3. **Expansion is a line of text, not a gesture.** UD-2 replaces it with a
   draggable boundary with a visible affordance.
4. **The values sit in a single trailing strip**, not in the debugger's own
   parallel value columns. UD-3 fixes the placement.
5. **There is no light theme yet.** `default_white` builds and loads, but its
   palette is unfinished: the built light and dark Electron stylesheets differ
   in about 1.8% of their rules and both still paint `#282828`, so a window
   configured for it comes out dark. The harness refuses to write a capture
   labelled `light` that paints dark, so **you will never be handed one** — if
   a screenshot is labelled `light`, a real light palette exists and it is
   fair game to review as one.

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
