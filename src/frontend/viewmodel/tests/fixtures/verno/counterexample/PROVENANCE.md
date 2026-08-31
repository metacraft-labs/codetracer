# Provenance — `verno_emitted_solver_model.json`

**Deliberately not part of the shared conformance corpus** in
`../payload/`. That corpus is byte-identical in `blocksense-network/verno` and
in this repository and is tied by a SHA-256 manifest; this file is not, because
it is not a document either side is asked to agree about. It is one specific
document, produced by one side, so the other side can be checked against it.

## What produced it

`cargo test -p formal_verification --lib -- --nocapture w8` in
`blocksense-network/verno` at `vn-m5/counterexample-payload`. The check prints
the payload its own `PayloadBuilder` emitted; this file is that output.

The **counterexample model inside it is a real solver result.** It came from
`air --print-model` (`blocksense-network/verus-lib`
`vn-m5/counterexample-model`) run against **z3 4.15.1** on 2026-08-30, on a
query shaped the way Verno's `vir_gen` shapes one and whose failing execution
is *unique*: `n = 42`, `total = n + 1 = 43`, `doubled = total * 2 = 86`,
against the obligation `doubled < 0`. Those are not one model among many; they
are the values the failing execution computes.

## What is **not** real about it

Everything around the model. There is no Noir workspace, no `venir` process and
no recorded run:

* `run.workspace_root` reads **`NOT A RECORDING`** — asserted by
  `test_verification_payload.nim` so it cannot be tidied away, exactly as
  `not_proved_with_model.json`'s marker is;
* `run.started_at_unix_ms` / `finished_at_unix_ms` are fixed values, substituted
  so the file is stable across runs;
* the two findings carry no source locations, because the check that built them
  had no `FileManager`;
* `source_map.files` is empty for the same reason.

## What it is for

To check that the document Verno's emitter *actually produces* for a payload
carrying a solver model decodes here — with the values, the program points in
the order the program reaches them, and the violated obligation intact — and
that the payload opens VN-M5's gate (`hasSteppableCounterexample` answers
`true`). Writing that document by hand on this side would have made the check
agree with itself.

## What would replace it

A Linux run of `tests/manual/verno_payload_end_to_end.nim` with `venir` against
a real Noir package. That would produce the same shape with a real workspace, a
real `venir` process, real source locations and a real obligation span — and it
would then belong in the shared corpus rather than here.

---

# Provenance — `bounded_loop_model.json`

**Authored here, and it is the only fixture in this directory that is.** That
is a weakness, it is stated first, and it is why nothing in this document is
trusted to be right about arithmetic — see "How it is kept honest" below.

## Why it exists

VN-M5 deliverable 4: "Loops from a bounded model driven through the **existing**
loop controls, not a parallel mechanism." The contract has carried
`StepKind::LoopIteration` and `iteration` since VN-M4, and **no producer emits
either**: `air`'s snapshots do not distinguish an unrolled iteration from any
other program point, so Verno has nothing to put in those fields, and the two
real documents in this repository contain zero loop steps between them.

Without this file the consumer half of deliverable 4 would be tested by
quantifying over an empty set, which passes
(`codetracer-specs/Testing/Verification-Harness-Traps.md`, trap 4). With it, the
grouping, the iteration boundaries and the slider's end stops are exercised over
a loop of known, asserted size.

## What is real about it

Nothing. There is no Noir package, no `venir` run, no solver and no z3. The
values are consistent with the program they describe — `n = 3`, and an
accumulator reaching `12` against an invariant of `sum <= 3 * i` — and they were
worked out by hand, not found. `run.workspace_root` says so, in the file, in
the same place and for the same reason `verno_emitted_solver_model.json` and
`not_proved_with_model.json` say it.

It is **not** part of the shared conformance corpus in `../payload/`, for the
same reason its neighbour is not: that corpus is byte-identical in
`blocksense-network/verno` and tied by a SHA-256 manifest, and this is not a
document either side is asked to agree about.

## How it is kept honest

The loop checks in `../../unit/test_counterexample_session.nim` do not take this
file's word for what an iteration is. Every answer the session gives about
iterations is cross-asserted against **`src/frontend/ui/flow_loop_math.nim`** —
`activeIterationForTicks`, `nextIteration`, `previousIteration` — which is the
Omniscience flow panel's own loop arithmetic, written for a different panel and
a different coordinate long before this milestone. `run-vnm5-render-mutations.py`
arm `R10` mutates that module and requires the counterexample's loop check to
redden, which is the demonstration that there is one loop control here and not
two.

The one thing this file is trusted for is its *shape*: which steps are loop
iterations, and which iteration number each carries.

## What would replace it

A `venir` that distinguishes an unrolled iteration. That is a producer-side
change nobody has made, it is named in VN-M5's deliverable 4, and until it
exists this file is the only input deliverable 4's consumer half has.

---

# Provenance — `verno_end_to_end_macos.json`

**The first document in this repository that nobody authored any part of.** No
hand-written envelope, no substituted timestamps, no `NOT A RECORDING` marker —
because it is not synthetic. Its two siblings above stay exactly as they are;
this file does not replace either of them.

## What produced it, end to end

```
verno fv        # blocksense-network/verno main cc90731, release build
  -> Noir v1.0.0-beta.26 front end -> VIR
  -> venir       # blocksense-network/Venir vn-m5/report-counterexample 7cc0e51
  -> rust_verify + vir + air   # blocksense-network/verus-lib 15f7712a
  -> z3 4.12.5 (arm64-osx, the version tools/get-z3.sh pins)
```

on **aarch64-apple-darwin**, 2026-08-31, against
`test_programs/formal_verify_failure/verus_post_failure` — a Noir program with
two false postconditions, ported from Verus' own `examples/basic_failure.rs`.
Total wall clock for the run: **0.55 s**.

`run.workspace_root` is a real absolute path on the machine that produced it.
That is deliberate and is the point: the two files above say `NOT A RECORDING`
because their envelopes are invented, and this one must not, because its
envelope is not.

## Why it exists next to the other two rather than instead of them

Each answers a different question.

* `verno_emitted_solver_model.json` — does the document Verno's *emitter*
  produces decode here? Its model is a real z3 result; its envelope is
  synthetic.
* `not_proved_with_model.json` (in `../payload/`) — the shared, SHA-256-manifested
  conformance corpus. It is the only document whose steps are **mixed**, and it
  is the control arm for every "unknown position" assertion.
* **This file** — does the whole chain, with nothing authored anywhere in it,
  reach the consumer's gate?

## What it establishes, and one thing it corrects

`hasSteppableCounterexample` answers **true** for it. Opening `f1` gives a
2-step session: one program point with values and **no** source position, and
one violated obligation at `src/main.nr:7:12` producing one real editor anchor.
`positionSummary` reads *"1 of 2 steps have no source position"*.

So the campaign's central constraint is now confirmed **against real solver
output** rather than against a fixture: `SnapPos` does not cross the `venir`
boundary, so a program point carries values and no position, while the
obligation's own span does cross — it travels on the message, not on the
snapshot map.

**The correction:** `not_proved_with_model.json` gives its model binding `x1` a
declaration span. **Real Verno emits no binding locations at all** — every
binding here is `noloc`. So any claim that a value can be shown against its
declaration site rests on a fixture shape the producer does not yet produce.
Recorded here rather than left to be discovered.

## Two producer defects this run exposed, neither fixed here

1. **An encoding-internal name reaches the developer.** Trace `cx0`'s model
   shows a binding named `no%param`. `payload/counterexample.rs::demangle`
   classifies a name as internal with `starts_with('%')`, and Verus also emits
   `<word>%<word>` internals, which that test misses. The module's own rule is
   "names the encoding owns rather than the developer are not shown"; this is
   that rule failing on real output, visible only from a real run.
2. **One corpus entry cannot be parsed.** `formal_verify_success/array_set_composite_types_3`
   fails with *"Failed to deserialize the following lines"* — `venir` wrote an
   output shape Verno's `SmtOutput` does not recognise. It is the second
   `pipeline-error` in the run and is a real regression against the expectation
   that the success half proves.

Both belong to Verno and are reported rather than patched: PR #6 and the
`derivation.nix` pin bump are being held deliberately.
