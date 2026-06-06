// simple_trivial_chain — Cairo
// a=10; b=a; c=b — origin chain terminates at Literal.
//
// The Value Origin query targets `c` at the trailing return.  The chain
// must walk: c -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).
//
// Cairo's `felt252` is the canonical scalar type, so every binding here
// is a plain felt copy — exactly the universal-table TrivialCopy shape
// per spec §7.1 row 1 (no felt-vs-pointer ambiguity at this scenario).
fn main() -> felt252 {
    let a: felt252 = 10;
    let b: felt252 = a;
    let c: felt252 = b;
    c
}
