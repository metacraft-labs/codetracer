---
title: Introduction
order: 0
---

# DeepReview

A diff is a proposal written in the language of text edits. It tells you,
exactly and completely, what the author changed. It cannot tell you what the
change **did**.

So a reviewer infers. You read `let contribution = (i as Field) * x;`, you build
a model of the loop in your head, you decide the arithmetic comes out right, and
you approve. Only the first of those steps is evidence. The rest is a simulation
you ran in your head against a program you have not seen run — and it is where
review defects come from.

**DeepReview is code review with the recordings attached.** You give CodeTracer
a diff together with one or more recordings of that code actually running, and
it renders the diff with what each changed line did: which lines the run
executed, how many times, and which values they held on each pass through a
loop.

![A DeepReview window: the VCS panel with the changed file and its coverage badge, the diff tab with the flow overlay, and the Agent Activity panel](/assets/img/deep_review/review-window.png)

## The questions it lets you answer

Each of these is a question about a change that a diff cannot answer at all, and
that a reviewer otherwise answers by inference, by asking the author, or by
checking the branch out and running it themselves.

**Did this line run at all?** Every line inside a recorded function is shaded
executed or not executed, on the diff itself. A hunk that no recording ever
entered looks different from one that ran on every pass, so "this branch is
never taken in practice" stops being a suspicion and becomes something you can
see.

**What value did it hold — on which pass through the loop?** Executed lines
carry inline value chips, and a loop the recording entered gets an iteration
stepper above it. Stepping it walks the same line through the values it actually
held: `contribution` through `0`, `5`, `10`, `15`, and `sum` through their
running total. You are reading measurements, not re-deriving them.

**Was this function called once, or forty times?** A recorded function carries an
invocation stepper (`‹ main: call 1 / 2 ›`), and the file rows carry coverage
counts. A helper the change touched lightly and a helper it put on a hot path
are different reviews, and the dataset already knows which one you are looking
at.

**Which parts of the change did the runs never exercise?** The same shading, read
the other way. It is the honest version of "is this tested?" — not a promise
that the untouched lines are wrong, but a list of the ones no recording has
anything to say about.

**What did the agent that produced this change actually do?** When a review is
collected inside an agent session, the Agent Activity panel shows that session's
conversation, loaded by reference against the agent backend. The change, the
evidence for it, and the reasoning that produced it are in one window.

## What a review actually is

Two commands and one artefact:

```sh
ct review collect …   # build a review dataset from recordings + a diff
ct review <PATH>      # open it
```

A **review dataset** is a self-contained `review.json`: the diff, the source of
each changed file, per-line coverage, the recorded flow (steps and values), and
the call tree. It is produced once and can be opened later, on another machine,
without the original recordings — which is what makes a review something you can
hand to somebody rather than a session you have to be present for.

DeepReview adds **no panel of its own**. A review routes its data into three
panels CodeTracer already has — the VCS panel, the Editor, and the Agent
Activity panel — and leaves your layout otherwise alone. Everything you already
know about the editor still applies inside a review.

## What it does not tell you

Worth stating in the same breath, because a tool that shows execution next to a
diff invites a stronger reading than it has earned:

- **It does not tell you the change is correct.** It tells you what happened in
  the runs you recorded. Judging whether that is what *should* have happened is
  still the review.
- **It is not a test report.** A review dataset carries no test results at all —
  no names, no statuses, no durations — so no surface reports them, and none
  shows a zero in their place. `ct test`
  is a separate command, and issues **no test certificates** — see
  [Not yet available](/deep_review/not_yet_available) for exactly how far it
  goes. Nothing in a review claims otherwise.
- **Coverage is observation, never reachability.** A recording can say a line
  was not observed. It can never say a line cannot be reached, and a review does
  not pretend the two are the same.
- **It reviews the changed code, not everything it calls.** Flow is collected for
  the functions the diff touched; a callee gets a call count and coverage, but no
  overlay of its own.

The full list of the things that are deliberately not there yet lives on
[Not yet available](/deep_review/not_yet_available). It is worth a read before
your first review: everything on it is real behaviour you will meet, written
down so you do not read it as a bug or, worse, as a measurement.

## Where to go next

- [Collecting a review](/deep_review/collecting) — the two commands, a worked
  example end to end, and what happens with native (rr) recordings.
- [Reading a review](/deep_review/reading) — the three panels, the flow overlay
  and the steppers.
- [The agent workflow](/deep_review/agent_workflow) — how an agent produces a
  review, and how to make it do so reliably.
- [Not yet available](/deep_review/not_yet_available) — the deferrals, named.
