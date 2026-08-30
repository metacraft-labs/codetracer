# Verno output fixtures — where each one came from

These are the inputs to `test_verification_vm.nim`. The classifier and the
diagnostic parser are the only things standing between "Verno said something"
and "CodeTracer showed the developer something", so a fixture that was *made up*
would make the whole suite worthless. Each file below therefore records how it
was obtained, and whether a solver was involved.

**Verno revision:** `blocksense-network/verno` branch `vn-m2/noir-beta26` @
`5b2d32e` (VN-M2's port onto Noir `v1.0.0-beta.26`), built as
`target/debug/verno`.

**Machine:** macOS (Darwin 25.5.0), arm64.

**The constraint that shapes this directory:** Verno's solver back end, `venir`,
is Linux-only. On this machine every run stops at the solver boundary and Verno
prints `Failed to start the Venir binary`. So a *proved* or *not-proved* outcome
cannot be produced here at all — see the two `failed_obligation_*` entries.

| File | Produced by | Solver ran? |
|---|---|---|
| `no_solver.txt` | Real run, this machine, this date | No — this is the message saying so |
| `unsupported_lambda.txt` | Real run, this machine, this date | No — refused before the solver |
| `pipeline_error_type_mismatch.txt` | Real run, this machine, this date | No — refused before the solver |
| `proved.txt` | Verno source, `formal_verification/src/venir_communication.rs:114` | **Not reproduced here** |
| `failed_obligation_assertion.txt` | Verno's docs (`pre_and_postconditions.md:95`) + Verno source (see below) | **Not reproduced here** |
| `failed_obligation_postcondition.txt` | Verno's regression harness (`run-corpus.py:478`) + Verno source (see below) | **Not reproduced here** |
| `timed_out_rlimit.txt` | `scripts/run-corpus.py` self-test, quoting `air/src/main.rs` | **Not reproduced here** |

## The three that are real runs on this machine

Commands, verbatim, from `~/m/dev/codetracer/test-programs`:

```sh
$VERNO --program-dir noir_verification             formal-verify -- --rlimit 60   # exit 1   -> no_solver.txt
$VERNO --program-dir noir_verification_unsupported formal-verify -- --rlimit 60   # exit 101 -> unsupported_lambda.txt
```

and, for a front-end error, a throwaway package with `let y: Field = x;` where
`x: u32`:

```sh
$VERNO --program-dir typeerr formal-verify -- --rlimit 60                         # exit 1   -> pipeline_error_type_mismatch.txt
```

`pipeline_error_type_mismatch.txt` matters out of proportion to its size. It is
a **real** `codespan-reporting` block emitted by `noirc_errors::reporter` at
`v1.0.0-beta.26`, on this machine, today — which is the same reporter, and the
same block shape, that renders a solver diagnostic
(`venir_communication.rs::smt_output_to_diagnostic` builds a `CustomDiagnostic`
and hands it to `report_all`). So the *span parser* is validated against
genuine current output even though the *solver* never ran.

## The two failed-obligation fixtures, stated plainly

`failed_obligation_assertion.txt` and `failed_obligation_postcondition.txt`
were **not** produced on this machine and no solver was involved in making
them. They are assembled from two verified sources:

1. the diagnostic block — wording and layout — from Verno's own repository, but
   the two headlines come from **different** files there and it is worth being
   exact about which:
   * `error: assertion failed` is quoted from the documentation,
     `docs/src/specifications/pre_and_postconditions.md:95`, which records a
     real solver-backed run — including its `┌─ src/main.nr:10:12` location
     line and its `-------- assertion failed` underline, which is where this
     fixture's layout comes from;
   * `error: postcondition not satisfied` is **not** in that document. The
     document's four example blocks use
     `error: possible arithmetic underflow/overflow` (×2),
     `error: precondition not satisfied` and `error: assertion failed`. The
     exact string used here is quoted from the regression harness instead,
     `scripts/run-corpus.py:478`, where it is the `lost_proof_output` sample
     that harness asserts must classify as `not-proved`. That is still a
     Verno-authored statement of what a lost proof looks like, but it is a
     *test sample*, not a transcript — one step further from a real run than
     the assertion block above, and this file should not have said otherwise.
2. the trailer — `Error: Verification failed due to N previous errors!` — from
   the current source, `formal_verification/src/venir_communication.rs:108-112`,
   because the docs were written when Verno printed the older
   `Error: Verification failed!` (still at lines 27, 49, 76 and 102 there).

The line/column numbers point at real packages in this repository, but only one
of the two can be diffed against a Linux run as-is:

* `failed_obligation_assertion.txt` points at
  `test-programs/noir_verification_failing/src/main.nr:15:12`, which is the
  `assert(n == 40)` in that package's `main`, and that package *should* report
  `not-proved` on Linux. Diff it directly.
* `failed_obligation_postcondition.txt` points at
  `test-programs/noir_verification/src/main.nr:7:1`, which is a **correct**
  package — its postcondition holds, and on Linux it should report `proved`
  and emit `proved.txt`, not this. This fixture is therefore a *counterfactual*
  shaped like Verno's output, kept because the parser has to handle a
  postcondition block whose span covers a whole attribute line. It is not a
  prediction of what that package prints.

**What this means for the milestone.** `test_a_failed_obligation_lands_in_the_editor`
asserts the path from verifier output to an editor marker. It is a real test of
real code against recorded output, and it is **not** evidence that a solver
produced that output here. Reproducing it end to end needs a machine with
`venir`, and the test says so in its own header rather than only here.

## Reproducing the two of them on Linux

```sh
nix develop                        # in the verno checkout; this is what supplies venir
cargo build
./target/debug/verno --program-dir <codetracer>/test-programs/noir_verification_failing \
    formal-verify -- --rlimit 60
```

If the recorded text and the real text disagree, the recorded one is wrong and
should be replaced by the real one — that is the point of keeping the packages
in the repository next to the fixtures.
