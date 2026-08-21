---
title: Not yet available
order: 4
---

# Not yet available

Everything on this page is real behaviour you will meet, written down so you do
not read it as a bug or, worse, as a measurement. It is deliberately a page of
its own rather than a footnote at the end of a longer one: the fastest way to
mislead a reviewer is to describe a surface that shows execution data without
saying which parts of it are not driven by the data yet.

## The trace-context selector names the recordings; it does not filter yet

Choosing a different context is remembered, but it does not re-drive the overlay
from that recording. Coverage counts are the **sum across every recording** in
the dataset, and the invocation stepper walks every recorded call of a function
regardless of which run it came from. The selector's entries also show labels
only (`run-1`) — both collectors leave each context's recording id empty.

## `ct review inspect` reads native datasets only

The materialized collector writes a single `review.json` and no `.dr` chunks, so
`inspect` over a materialized dataset reports a missing `manifest.dr`. On a
machine with no native backend installed it reports that instead. Open the
dataset with `ct review`, or read `review.json` directly — it is plain JSON.
[Collecting a review](/deep_review/collecting) shows both transcripts.

## Values are one strip per line, not the debugger's parallel value columns

A review renders every value a step recorded as chips at the end of the line.
Values also arrive from the collectors as pre-rendered strings, so a struct or a
vector shows its rendered text and does not expand.

## The loop control is a stepper, not a dragged slider

It has previous/next buttons and a counter. The debugger's draggable loop slider
is sized from measurements a review has no live flow component to take.

## Draggable context-boundary edge lines are not implemented

The `Expand N lines` buttons are the supported control.

## Coverage is what the recording observed

The materialized collector reports the lines a run actually executed, so the
badge reads `N/N` on a fully-covered file; a line no recording touched is absent
from the coverage list rather than listed as uncovered. `unreachable` is always
`false`: a trace can say a line was not observed, never that it cannot be
reached.

## Symbols carry no declared type or visibility

A materialized trace records that a function ran, not how it was declared, so
`typeDesc` and `visibility` are emitted empty rather than guessed.

## Flow is collected for functions the diff *changed*, not for everything they call

A changed line `let x = helper(y);` gets flow for its caller; `helper` gets a
call count and coverage, but no flow overlay of its own. Following callees would
pull an arbitrary depth of untouched code into the review.

## A review carries no test results

`DeepReviewData` has no test name, status or duration field, which is why the
Agent Activity panel's Tests tile reads *not available for this dataset*.
`ct test` ships (`ct test discover` works from `ct`; `ct test run` needs the
standalone runner binary, which `ct` tells you when it cannot run it) but
issues **no test certificates** — and nothing in the review surface, or in
the text `ct agent prompt` prints, claims otherwise.

## Sharing a review is still handing over a directory

`ct review` has exactly three forms — the launch form, `collect` and `inspect`.
None of them packages a dataset into a single file, uploads one, or produces a
link; handing a review to somebody means handing over the directory `collect`
wrote. Note what that hands over: a dataset carries the source text of every
changed file and the recorded variable values, so whoever receives it gets all
of it.

## See also

- [Introduction](/deep_review) — what DeepReview is for.
- [Reading a review](/deep_review/reading) — the surfaces these limits apply to.
