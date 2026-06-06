// simple_trivial_chain — Aiken (Cardano)
// a=10; b=a; c=b — origin chain terminates at Literal.
//
// The Value Origin query targets `c` at the trailing return.  The chain
// must walk: c -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).
//
// Aiken's let-binding syntax mirrors Rust's, so the classifier reuses
// the Rust universal-table row from spec §7.1.  The Aiken-specific
// override documented in spec §7.2 (M23 Aiken row) recognises Aiken's
// pipeline operator `|>` as a `Computational` shape with a known
// continuation receiver; this fixture is straight-line copies so the
// pipeline override is inert here.
fn compute() -> Int {
  let a = 10
  let b = a
  let c = b
  c
}

test flow_test() {
  compute() == 10
}
