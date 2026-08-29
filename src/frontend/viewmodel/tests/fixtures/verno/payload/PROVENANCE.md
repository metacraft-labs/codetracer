<!--
This file is a **vendored copy**. Its source of truth is
`blocksense-network/verno` at `conformance/codetracer-payload/PROVENANCE.md`,
alongside the fixtures it describes. Both repositories hold byte-identical
copies of `manifest.json`, and each checks every digest in it against its own
copy of the fixtures — so a fixture edited on one side and not the other fails
on both. Regenerating means regenerating in both, in the same commit pair.

The consumer-side check is
`src/frontend/viewmodel/tests/unit/test_verification_payload.nim`, suite
"VN-M4 the conformance corpus is shared, and provably the same on both sides".
-->

# The VN-M4 conformance corpus — where each fixture came from

These are the shared test inputs for the `codetracer.verification/v1` payload
contract. Verno produces the payload; CodeTracer consumes it. Both sides test
against **these bytes**, so that a producer and a consumer can be developed
independently and still meet.

A fixture that was *made up* and presented as a recording would make the whole
corpus worthless — worse than worthless, because it would look like evidence.
So every file below records how it was obtained and, specifically, **whether a
solver was involved.**

**Verno revision:** `blocksense-network/verno`, branch `vn-m4/payload-contract`
off `main` `5b2d32e`, built as `target/debug/verno`.

**Machine:** macOS (Darwin 25.5.0), arm64.

**The constraint that shapes this directory, again:** Verno's solver back end,
`venir`, is Linux-only. On this machine every run stops at
`Failed to start the Venir binary`. A `proved` or a `not-proved` outcome cannot
be produced here at all.

**And a second constraint, which is new and is not about the machine:** even on
Linux, **`venir` returns no counterexample model.** Its whole output surface is
four JSON shapes carrying five strings between them
(`blocksense-network/Venir`, `src/stub_structs.rs`), and its `Reporter` receives
diagnostics only — `air::context::ValidityResult::Invalid(Option<Model>, ..)`
is destructured inside `rust_verify` and the model never reaches the reporter.
So `not_proved_with_model.json` below is **not** something a Linux run would
produce today either, and it says so in its own contents.

## Accepted fixtures

| File | Produced by | Solver ran? |
|---|---|---|
| `no_solver.json` | Real `verno` run, this machine, 2026-08-29 | No — this is the payload that says so |
| `unsupported_lambda.json` | Real `verno` run, this machine, 2026-08-29 | No — refused before the solver |
| `pipeline_error_type_mismatch.json` | Real `verno` run, this machine, 2026-08-29 | No — refused before the solver |
| `proved.json` | Hand-authored against the schema | **No.** Nothing has ever proved anything in this campaign |
| `not_proved_assertion.json` | Hand-authored against the schema | **No** |
| `not_proved_with_model.json` | Hand-authored, and **hypothetical** — see below | **No** |
| `timed_out_rlimit.json` | Hand-authored against the schema | **No** |

### The three that are real runs

Commands, verbatim:

```sh
VERNO=~/m/dev/verno-vnm4/target/debug/verno

cd <codetracer>/test-programs/noir_verification
$VERNO --program-dir . formal-verify -- --rlimit 60     # exit 1   -> no_solver.json

cd <codetracer>/test-programs/noir_verification_unsupported
$VERNO --program-dir . formal-verify -- --rlimit 60     # exit 101 -> unsupported_lambda.json

# a throwaway package whose `main` has `let y: Field = x;` with `x: u32`
cd typeerr
$VERNO --program-dir . formal-verify -- --rlimit 60     # exit 1   -> pipeline_error_type_mismatch.json
```

Each was taken verbatim from the `target/verno-report.json` the run wrote, with
**exactly three** substitutions, all of them machine-specific paths that would
otherwise make the file unreproducible on another checkout:

* `run.workspace_root` → `"<recorded: ...>"`
* `run.argv[0]` → `"<recorded: the absolute path of the verno binary>"`
* `source_map.files[].absolute_path` → `"<recorded: ...>"`

Nothing else was edited. In particular the timestamps, the outcome, the
findings, the trust classes and the **line and column numbers** are as the
producer wrote them.

`pipeline_error_type_mismatch.json` earns its place the way VN-M3's fixture of
the same name did, and for the same reason. Its two findings sit at `2:20` and
`1:24`, and the `noirc_errors::reporter` block the same run printed to stderr
reads `┌─ src/main.nr:2:20` and `┌─ src/main.nr:1:24`. That is the *whole* of
the agreement between the two tiers being demonstrated on real, current
`v1.0.0-beta.26` output: the structured payload's coordinates and the rendered
text's coordinates are the same coordinates, computed independently. A solver
diagnostic goes through the same `report_all`, so the agreement carries.

`unsupported_lambda.json` is produced by the **panic hook**, not by a return
path — `todo!("UNSUPPORTED: ...")` unwinds past every `?` in the command. That
it exists at all is the evidence that the hook works, and it was captured from a
real panic on this machine.

### The four that were written by hand

`proved.json`, `not_proved_assertion.json` and `timed_out_rlimit.json` are
authored to the schema. Their *shape* is checked by the producer's own
validator (`payload::conformance_tests`), so they cannot drift from the
contract, but no solver produced their contents and none of them is a
transcript. They exist so that a consumer can be developed against all five
expressible outcomes rather than the three this machine can reach.

`not_proved_with_model.json` is the important one to be careful about. It is
the **only** fixture in this corpus carrying model values, path steps, a
violated obligation, a proof-goal tree and SMT query text — and **none of it
came from a solver.** It is a statement of what the contract's slots are for,
written so that the consumer's decoder has something to decode. Two markers in
the file itself keep it from being mistaken for a recording:

* `producer.version` is `"0.0.0-hypothetical"`, which is not and will never be
  a real Verno version;
* `run.workspace_root` reads `"<authored: NOT A RECORDING — see PROVENANCE.md>"`.

Both are asserted by a test, so they cannot be tidied away.

## Rejected fixtures

`rejected/` holds documents a conforming consumer must **refuse**. Each one
breaks exactly one stated rule, and each side's test asserts not only that it
was refused but *which rule* the refusal named — a rejection test that passed on
any rejection would prove nothing.

| File | The rule it breaks |
|---|---|
| `missing_run_trust.json` | every payload carries a trust class |
| `missing_finding_trust.json` | every *finding* carries one too |
| `unknown_outcome.json` | the outcome is one of exactly six |
| `unknown_schema.json` | an unrecognised schema is refused, not guessed at |
| `limitation_answers_correctness.json` | a limitation can never sit in a payload that claims to answer correctness |
| `counterexample_claims_recording.json` | a solver model is never a recorded execution |
| `model_unavailable_with_bindings.json` | an unavailable model carries no values |
| `proved_without_solver_oracle.json` | a `proved` verdict rests on the solver oracle and must say so |
| `counterexample_without_a_rejection.json` | only `not-proved` may carry a counterexample |
| `finding_without_location_or_reason.json` | a finding with no source span says why it has none |

## `manifest.json`, and why it exists

There is no shared repository and no submodule between Verno and CodeTracer, so
"both sides test against the same fixtures" needs something to enforce it.
`manifest.json` lists every fixture with its SHA-256, and a **byte-identical
copy** lives in CodeTracer at
`src/frontend/viewmodel/tests/fixtures/verno/payload/manifest.json`. Each side
checks every digest against its own copy of the fixtures.

The consequence is the one that matters: a fixture edited in one repository and
not the other **fails in both**. Without it, the two sides could quietly test
different corpora and both stay green — which is exactly the failure this
milestone's "conformance fixture set both sides test against" deliverable is
about.

Regenerating after an intentional change means regenerating in **both**
repositories, in the same commit pair.

## What is still missing, and what would close it

One command on a Linux machine with `venir`:

```sh
nix develop                        # in the verno checkout; this is what supplies venir
cargo build
cd <codetracer>/test-programs/noir_verification_failing
<verno> --program-dir . formal-verify -- --rlimit 60
cat target/verno-report.json
```

That produces the first real `not-proved` payload. Diff it against
`not_proved_assertion.json`; if they disagree, the recorded one is wrong and
should be replaced.

It will **not** produce `not_proved_with_model.json`. Closing that needs a change
in `blocksense-network/Venir`, and the change is smaller than it sounds:

1. `MessageX` (`vir::messages`) already derives `Serialize`, and it carries
   `spans`, **all** the `labels`, `help` and `level`. Venir's reporter currently
   flattens it to three strings and keeps only `labels.last()`. Serialising
   `MessageX` itself would give Verno the full diagnostic instead of a lossy
   projection, at the cost of one `serde_json::to_string` call.
2. The model is a larger job. `air::model::Model`'s fields are private and it
   does not derive `Serialize`; the *values* are not in it at all — they are
   obtained by evaluating expressions against the live Z3 context, which is what
   Verus's `--debugger` shell does. Verus's own path additionally needs a
   `rustc_span::SourceMap`, which Verno has no analogue for. But Verno's spans
   *are* recoverable without rustc: `vir::messages::Span::as_string` carries
   `"(byte_start, byte_end, file_id)"`, written by
   `vir_gen::encode_span_to_string`, and venir already re-extracts it with a
   regex. So a snapshot-to-Noir-span mapping is reachable through data venir
   already has.
3. Variable identity is already preserved end to end:
   `VarIdent(name, VarIdentDisambiguate::RustcId(local_id))` is built from the
   Noir identifier and its `LocalId`, so a model value can be named in the
   developer's own vocabulary. Parameters additionally have real `Location`s via
   `formal_verification/src/param_source.rs`; locals would need a
   `VarIdent -> Location` side-table built during `vir_gen`.

Until (2) lands, a Verno counterexample is a located obligation with
`model.status == "unavailable"` and a stated reason — which is a true thing to
say, and is what `not_proved_assertion.json` shows.
