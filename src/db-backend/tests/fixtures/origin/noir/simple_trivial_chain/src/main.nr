// simple_trivial_chain -- Noir
// a=10; b=a; c=b -- origin chain terminates at Literal.
//
// The Value Origin query targets `c` at the `println` line.  The chain
// must walk: c -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).
//
// Noir's let-binding syntax is Rust-like (`let <name>: <type> = <expr>;`).
// The classifier reuses the Rust universal-table row from spec section 7.1.
// The Noir-specific overrides documented in spec section 7.2 (M23 Noir row)
// recognise `unconstrained fn` bodies; this fixture is straight
// constrained code so the override path is inert here.
fn main() {
    let a: Field = 10;
    let b: Field = a;
    let c: Field = b;
    println(c);
}
