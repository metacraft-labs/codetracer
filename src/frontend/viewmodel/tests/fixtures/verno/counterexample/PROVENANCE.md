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
