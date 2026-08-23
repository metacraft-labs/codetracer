---
title: DeepReview
order: 12
---

# DeepReview

**DeepReview is code review with the recordings attached.** You give CodeTracer
a diff and one or more recordings of the code actually running; it shows you the
diff with what each changed line *did* — which lines ran, how many times, and
which values they held on each pass through a loop.

It is two commands:

```sh
ct review collect …   # build a review dataset from recordings + a diff
ct review <PATH>      # open it
```

A **review dataset** is a self-contained `review.json`: the diff, the source of
each changed file, per-line coverage, the recorded flow (steps and values), and
the call tree. It is produced once and can be opened later, on another machine,
without the original recordings.

DeepReview adds **no panel of its own**. A review routes its data into three
panels CodeTracer already has — the VCS panel, the Editor, and the Agent
Activity panel — and leaves your layout otherwise alone.

![A DeepReview window: the VCS panel with the changed file and its coverage badge, the diff tab with the flow overlay, and the Agent Activity panel](/assets/img/deep_review/review-window.png)

## DeepReview is not rr-only

`ct review collect` chooses a collector by **inspecting the recordings you give
it**. There is no `--backend` flag and you never name one.

| Recordings                                                             | Collector                                        |
| ---------------------------------------------------------------------- | ------------------------------------------------ |
| Native / rr (C, C++, Rust recorded through the rr backend)             | the native replay backend (`ct-native-replay`)   |
| Materialized (Python, Ruby, JavaScript, Noir, and every other language that records a trace database) | the db-backend collector, over the same trace the debugger reads |

A directory holding recordings of **both** kinds is refused, rather than
half-collected:

```console
$ ct review collect --repo . --diff HEAD~..HEAD --recordings ./mixed -o /tmp/out
error: `ct review collect` refuses a mixed recordings directory: './mixed' holds recordings of more than one kind.
    native (rr): 1 (rr-run)
    materialized (CTFS): 1 (py-run)
  One collector is chosen per run by inspecting the recordings, and datasets produced by
  two different collectors are not merged.  Point --recordings at recordings of one kind.
```

An empty directory, a directory with no recordings in it, and a `--recordings`
path that does not exist are three different mistakes and get three different
messages:

```console
$ ct review collect --repo . --diff HEAD~..HEAD --recordings ./empty -o /tmp/out
error: `ct review collect` found no recordings in './empty': the directory is empty.
  Record the runs you want reviewed first (`ct record …`), then point --recordings at
  the directory holding them.

$ ct review collect --repo . --diff HEAD~..HEAD --recordings ./nope -o /tmp/out
error: `ct review collect` found no recordings directory at './nope'.
  --recordings names the directory that HOLDS the recordings, one subdirectory each.
```

## A worked example: reviewing a Noir change

This walks the whole loop on a materialized-trace language. Noir is used because
`nargo` ships with CodeTracer; the steps are identical for Python, Ruby or
JavaScript — only the `ct record` invocation changes (see the
[Getting Started](/getting_started) guide for your language).

### 1. The program, before the change

`Nargo.toml`:

```toml
[package]
name = "scale_sum"
type = "bin"
authors = [""]

[dependencies]
```

`Prover.toml`:

```toml
x = "5"
```

`src/main.nr`:

```rust
fn main(x: Field) {
    let mut sum: Field = 0;
    for i in 0..4 {
        sum = sum + x;
    }
    let final_result = sum;
    assert(final_result == 20);
}
```

Commit it:

```sh
git init -q
git add -A
git commit -qm "base: sum x four times"
```

### 2. The change to review

Scale each term by the loop index instead of adding `x` four times:

```rust
fn main(x: Field) {
    let mut sum: Field = 0;
    for i in 0..4 {
        let contribution = (i as Field) * x;
        sum = sum + contribution;
    }
    let final_result = sum;
    assert(final_result == 30);
}
```

```sh
git add -A
git commit -qm "scale each term by the loop index"
```

### 3. Record the change running

A review needs recordings. Record the runs you want reviewed into one directory,
one subdirectory per run:

```sh
ct record -o .ct/runs/run-1 .
```

```console
Saved trace to /home/you/scale_sum/.ct/runs/run-1
recordingId:01a016ab-5ec2-7269-ae4c-f99e9003223f
```

:::note
Those are the **last two** lines. Recording a Noir program first prints a block
of `warning: unused import __debug_member_assign_N` diagnostics — one per
variable the instrumenter tracks — on **stdout**, not stderr. The eight-line
program above produces eighteen such lines; a real program produces hundreds.
They come from `nargo` compiling the instrumented copy, they are not a problem
with your code, and there is no flag to suppress them today. A script that
parses this output should read the last lines rather than the first, and cannot
separate the noise by redirecting stderr.
:::

Record as many runs as you want reviewed — a second run with a different
`Prover.toml` input, say, or the same program under a different test. Each
becomes a **trace context** in the review:

```sh
ct record -o .ct/runs/run-2 .
```

### 4. Collect the dataset

```sh
ct review collect --repo . --diff HEAD~..HEAD --recordings .ct/runs --output .ct/review
```

```console
DeepReview collect complete: 2 recordings collected, 1 files, 1 with coverage, 2 function executions
Review dataset ready: .ct/review/review.json
Open it with: ct review .ct/review
```

`collect` writes `review.json` into the output directory, so the directory it
names is exactly what `ct review` opens.

### 5. Open the review

```sh
ct review .ct/review
```

Either the directory or the `review.json` inside it works. A path that does not
exist is diagnosed by `ct` before anything launches.

## What the review shows

### The VCS panel

The VCS panel is the review's navigation surface, and it is the visible tab of
whatever stack hosts it when the review opens.

- **Header** — `Review: <commit>` and the review's totals (`1 file +3 -2`).
- **Trace-context selector** — a dropdown naming the recordings the dataset was
  collected from (`run-1`, `run-2`). It appears only when the dataset carries
  more than one. See [Not yet available](#not-yet-available) for what it does
  not do yet.
- **`Unified Diff` toggle** — active means clicking a file opens its **diff
  tab**; inactive means clicking opens the **full file**. It changes what a
  click does, not what the panel renders.
- **Changed files** — one row per file with its status letter (`M`, `A`, `D`,
  `R`), its `+`/`−` counts, and a coverage badge (`8/8` above).

Clicking a row opens that file. A review does not concatenate every file into
one scrolling document; cross-file navigation is this list.

The changeset is immutable, so a review offers no refresh and no file watching.

### The diff tab

The diff tab is an ordinary Monaco editor tab, so search, selection, copy,
minimap and keyboard navigation all work inside it. It shows one file: a header
line with the path and its counts, `@@` hunk headers, added lines in green with
`+`, removed lines in red with `−`, and context lines on the normal background.

![The diff tab: the invocation stepper, the loop-iteration stepper, per-line flow shading, inline value chips and the context-expansion control](/assets/img/deep_review/diff-tab.png)

**Context expansion.** `... Expand 10 lines above` / `... Expand 10 lines below`
reveal more of the surrounding file, ten lines at a time, and repeat. In a
review this is a local slice: the dataset already carries each changed file's
full source, so nothing is fetched. Revealed lines are normal code lines and
pick up the flow overlay like any other.

**Hunk selection.** Click a hunk header to select it, shift-click for a range,
ctrl-click to toggle one. The toolbar shows the count and offers **Copy** (the
selection as a patch) and **Clear**. Staging, discarding and moving hunks
between commits are *not* offered in a review — there is no working tree to
stage into.

### The flow overlay

This is the part a diff on its own cannot give you. Every line the recording
executed carries the standard Omniscience annotations, produced by the same code
that renders them during ordinary debugging:

- **Executed / not executed shading** on each line inside a recorded function.
- **Inline value chips** at the end of the line — a name chip (`<contribution>`)
  and a value chip (`0`) — in the same style the debugger's value boxes use.
  Values are never rendered as `//` comments.
- **An invocation stepper** anchored above each recorded function
  (`‹ main: call 1 / 2 ›`). A function that ran more than once has more than one
  invocation, and the stepper chooses which one the values describe.
- **A loop-iteration stepper** anchored above each loop the selected invocation
  entered (`‹ iteration 1 / 5 ›`), so a line inside a loop shows the values of
  the pass you asked for. It clamps at both ends and disappears for a loop
  entered only once.

In the example above, stepping the loop control walks `contribution` through
`0`, `5`, `10`, `15` — the four terms the change introduced — and `sum` through
their running total, on the same lines the diff added.

:::note
The loop stepper counts the **passes over the loop's header line** that this
invocation recorded. For the `for i in 0..4` above that is five, not four: four
iterations plus the final exit test, which is a real recorded step with no `i`.
:::

Lines with no recorded steps — including comments, which no collector reports —
are shaded as not executed.

### The Agent Activity panel

The third pillar. Its primary content in a review is **the agent session that
produced the dataset**, so you can read what the agent actually did in the run
leading up to it.

The session is loaded **by reference**: a dataset stores the session id and
enough context to resolve it against the agent backend (Agent Harbor, or an ACP
agent that advertises `session/load`). No transcript is copied into the file, so
a dataset never goes stale against the session and sharing a dataset does not
share the conversation.

`ct review collect` records the reference automatically when it is run inside an
agent session — it reads `CODETRACER_AGENT_SESSION_ID` and friends, the
variables the harness already exports:

```console
Review dataset ready: .ct/review/review.json
Associated with agent session: rv8-demo-session (acp)
Open it with: ct review .ct/review
```

A dataset with no session reference is a complete review; the panel simply shows
no conversation. When a reference cannot be resolved the panel says which of the
three things went wrong, in one sentence, rather than rendering an empty
conversation that reads as "the agent did nothing":

- the agent cannot replay sessions,
- the session could not be fetched (quoting the backend's own reason),
- the session loaded but contains no messages.

The session is all the panel shows. It used to keep a roll-up of the dataset
beneath the conversation — coverage, a per-file table, a **Tests** tile — and
that is gone: the VCS panel already reported the same facts, and a static
summary is not what you open a review to read. Per-file coverage is the badge on
each Changed Files row; the changeset totals are the stats line in the panel
header. The **Tests** tile read `n/a`, and nothing replaces it, because there is
nothing to say: a review dataset carries no test results, and no surface reports
a zero in their place — see [Not yet available](#not-yet-available).

## Full Files mode

Turning the VCS panel's `Unified Diff` toggle off makes a click open the whole
file in the normal editor instead, with diff highlights on the modified lines
and the same flow overlay — the same value chips, the same shading — wherever
the dataset has data for the loaded file.

Full Files mode has **no controls of its own**. It follows the invocation and
loop-iteration choices made with the diff tab's steppers, so the two surfaces
always agree about which call they are showing.

## Reviewing native (rr) recordings

Nothing about the workflow changes. Record the runs the way you normally would
for your language (for native programs that means the rr backend — see
[`ct record`](/reference/ct_cli)), point `--recordings` at the directory holding
them, and `ct review collect` routes to the native collector. The `collect` and
`review` commands are the same ones used above; only the recordings differ.

The native collector is reached as a subprocess. `ct` finds it on `PATH` as
`ct-native-replay`, or wherever `CODETRACER_NATIVE_REPLAY_PATH` points. If it is
missing, only native collection fails — collecting a Python or Noir recording on
a machine that never installed the rr backend works normally, and says so if it
cannot.

Reading a diff out of a git repository with `--repo` needs the native
collector's optional git support, which the default build does not enable. If
`--repo` is refused, generate the patch yourself and pass it instead:

```sh
git diff main..HEAD > change.patch
ct review collect --diff-file change.patch --recordings .ct/runs --output .ct/review
```

A patch file names no commits, so a dataset collected that way carries empty
commit ids rather than invented ones.

## The agent workflow

An agent produces a review the way a person does: it runs `ct review collect`,
then points CodeTracer at what it produced. There is no agent-specific
collection path.

```sh
ct review collect --repo . --diff main..HEAD --recordings .ct/runs -o .ct/review
ct agent evidence .ct/review
```

`ct agent evidence` takes the dataset and nothing else in the common case. The
session, task and workspace are read from the environment the agent already runs
under — `CODETRACER_AGENT_SESSION_ID`, `CODETRACER_AGENT_TASK_ID`,
`CODETRACER_AGENT_WORKSPACE` — because the harness that launched the agent knows
all three, and asking the agent to restate them only invites disagreement.
`--session`, `--task` and `--workspace` override the environment for use outside
a managed session and in tests.

When none of the three sources names a session, the command **fails and says
so**. It does not invent an id, because an invented one attaches the review to
the wrong conversation and nothing downstream can tell:

```console
$ ct agent evidence .ct/review
error: `ct agent evidence` could not tell which agent session this evidence belongs to.
  It reads the session from CODETRACER_AGENT_SESSION_ID, which the agent harness sets;
  that variable is unset, no --session was given, and the dataset at '.ct/review/review.json'
  carries no session reference of its own.
  Export CODETRACER_AGENT_SESSION_ID, or pass --session <ID> explicitly.
```

`ct agent evidence` accepts either the directory `ct review collect` produced or
the `review.json` inside it. (The text `ct agent prompt` prints spells the
collection `-o review.json`; `--output` always names a *directory*, so that form
produces a directory called `review.json` — which both `ct agent evidence` and
`ct review` open, because they resolve a directory to the dataset inside it.)

### Telling the agent to do it

CodeTracer ships the prompt text. Print it with:

```sh
ct agent prompt
```

and install it into a project's agent instructions with:

```sh
ct agent prompt >> AGENTS.md
```

The text teaches the pair of commands above, tells the agent to fix a failing
suite rather than hand over evidence for it, permits collecting from a dirty
working tree provided it says so, and forbids hand-writing a dataset — a file an
agent assembled itself asserts coverage and execution that never happened.

### The end-of-turn hook

A project that would rather not depend on the agent remembering can run the
collection from an end-of-turn hook. `ct agent end-of-turn` runs the *same two
commands, in that order*, and prints each one as it runs it:

```console
$ ct agent end-of-turn
+ ct review collect --repo /home/you/scale_sum --diff HEAD~..HEAD --recordings .ct/runs --output .ct/review
DeepReview collect complete: 2 recordings collected, 1 files, 1 with coverage, 2 function executions
Review dataset ready: .ct/review/review.json
Associated with agent session: rv8-demo-session (acp)
Open it with: ct review .ct/review
+ ct agent evidence .ct/review
{"sessionId":"rv8-demo-session","taskId":"rv8-demo-task", …}
```

It takes all of `ct review collect`'s options, and reads them from the
environment when they are not given, so the hook line in a harness's
configuration can be bare:

| Variable                       | Fills in            | Default    |
| ------------------------------ | ------------------- | ---------- |
| `CODETRACER_REVIEW_REPO`       | `--repo`            | the workspace |
| `CODETRACER_REVIEW_DIFF`       | `--diff`            | —          |
| `CODETRACER_REVIEW_DIFF_FILE`  | `--diff-file`       | —          |
| `CODETRACER_REVIEW_RECORDINGS` | `--recordings`      | `.ct/runs` |
| `CODETRACER_REVIEW_OUTPUT`     | `--output`          | `.ct/review` |

The two are not exclusive, and the trade is real: prompting keeps the judgement
of *what is worth reviewing* with the agent, which is where it belongs; a hook is
reliable but indiscriminate and will produce datasets for turns nobody wanted
reviewed. A project that uses a hook should still prompt, so the agent knows what
the hook will do and does not duplicate it.

## Inspecting a dataset without a GUI

**The dataset the worked example above just produced cannot be inspected
today.** `ct review inspect` reads only the **native** collector's format — the
directory holding a `manifest.dr` — and the materialized collector writes a
single `review.json` and no `.dr` chunks. Running it on `.ct/review` fails:

```console
$ ct review inspect .ct/review
error: `ct review inspect` needs the native replay backend, and no `ct-native-replay` binary was found.
  Add it to PATH, or point CODETRACER_NATIVE_REPLAY_PATH at it.
```

With the native backend present it gets one step further and then fails on the
missing `manifest.dr`. Either way the exit status is 1, so a CI job that shells
out to it on a materialized dataset will fail rather than print statistics.

For a materialized dataset, read `review.json` directly — it is plain JSON, and
`files[].coverage`, `files[].flow` and `files[].diff` are the same numbers
`inspect` would summarise:

```sh
jq '{files: (.files | length), commit: .commitSha, recordings: .recordingCount}' .ct/review/review.json
```

For a **native** dataset the command is:

```sh
ct review inspect <PATH> [--format text|json]
```

which prints file and symbol counts, coverage and flow steps.

## Not yet available

Everything in this section is real behaviour you will meet, written down so you
do not read it as a bug or, worse, as a measurement.

- **The trace-context selector names the recordings; it does not filter yet.**
  Choosing a different context is remembered, but it does not re-drive the
  overlay from that recording. Coverage counts are the **sum across every
  recording** in the dataset, and the invocation stepper walks every recorded
  call of a function regardless of which run it came from. The selector's
  entries also show labels only (`run-1`) — both collectors leave each context's
  recording id empty.
- **`ct review inspect` reads native datasets only.** The materialized collector
  writes a single `review.json` and no `.dr` chunks, so `inspect` over a
  materialized dataset reports a missing `manifest.dr`. On a machine with no
  native backend installed it reports that instead. Open the dataset with
  `ct review`, or read `review.json` directly — it is plain JSON.
- **Values are one strip per line, not the debugger's parallel value columns.**
  A review renders every value a step recorded as chips at the end of the line.
  Values also arrive from the collectors as pre-rendered strings, so a struct or
  a vector shows its rendered text and does not expand.
- **The loop control is a stepper, not a dragged slider.** It has previous/next
  buttons and a counter. The debugger's draggable loop slider is sized from
  measurements a review has no live flow component to take.
- **Coverage is what the recording observed.** The materialized collector
  reports the lines a run actually executed, so the badge reads `N/N` on a
  fully-covered file; a line no recording touched is absent from the coverage
  list rather than listed as uncovered. `unreachable` is always `false`: a trace
  can say a line was not observed, never that it cannot be reached.
- **Symbols carry no declared type or visibility.** A materialized trace records
  that a function ran, not how it was declared, so `typeDesc` and `visibility`
  are emitted empty rather than guessed.
- **Flow is collected for functions the diff *changed*, not for everything they
  call.** A changed line `let x = helper(y);` gets flow for its caller; `helper`
  gets a call count and coverage, but no flow overlay of its own. Following
  callees would pull an arbitrary depth of untouched code into the review.
- **A review carries no test results.** `DeepReviewData` has no test name,
  status or duration field, so no review surface reports any — and none reports
  a zero either, which would read as "a suite ran and was green". `ct test`
  ships (`ct test discover` works from `ct`; `ct test run` needs the standalone
  runner binary, which `ct` tells you when it cannot run it) but issues **no
  test certificates** — and nothing in the review surface, or in the text
  `ct agent prompt` prints, claims otherwise.
- **Draggable context-boundary edge lines are not implemented.** The `Expand N
  lines` buttons are the supported control.

## See also

- [`ct` CLI reference](/reference/ct_cli) — the full `ct review` and `ct agent`
  flag tables.
- [Command-Line Interface](/usage_guide/cli) — recording and replaying traces.
- [Getting Started](/getting_started) — how to record in your language.
