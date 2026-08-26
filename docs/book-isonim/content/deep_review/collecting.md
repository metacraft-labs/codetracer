---
title: Collecting a review
order: 1
---

# Collecting a review

A review is produced by one command and opened by another:

```sh
ct review collect …   # build a review dataset from recordings + a diff
ct review <PATH>      # open it
```

`collect` needs three things: a **diff** (a commit range, or a patch file), the
**source** the diff applies to, and one or more **recordings** of that code
running. It writes a `review.json` into the output directory, and the directory
it names is exactly what `ct review` opens.

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

What you see next is covered by [Reading a review](/deep_review/reading).

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

## See also

- [Reading a review](/deep_review/reading) — what the three panels show.
- [The agent workflow](/deep_review/agent_workflow) — collecting from an agent
  session, and the end-of-turn hook.
- [`ct` CLI reference](/reference/ct_cli) — the full `ct review` flag tables.
- [Not yet available](/deep_review/not_yet_available) — the deferrals, named.
