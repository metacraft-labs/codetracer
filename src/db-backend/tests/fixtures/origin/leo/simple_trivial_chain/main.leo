// simple_trivial_chain — Leo (Aleo)
// a=10; b=a; c=b — origin chain terminates at Literal.
//
// The Value Origin query targets `c` at the trailing `return c;` line.
// The chain must walk: c -> b (TrivialCopy) -> a (TrivialCopy) ->
// Literal(10).
//
// Leo's let-binding syntax is Rust-like (`let <name>: <type> = <expr>;`).
// The classifier reuses the Rust universal-table row from spec §7.1.
// The Leo-specific overrides documented in spec §7.2 (M23 Leo row) only
// fire on circuit / record field assignments — this fixture is local
// scalars only so the override path is inert here.
program flow_test.aleo {
    transition compute() -> u32 {
        let a: u32 = 10u32;
        let b: u32 = a;
        let c: u32 = b;
        return c;
    }
}
