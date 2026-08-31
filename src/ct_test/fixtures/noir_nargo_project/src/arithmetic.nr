pub fn add(a: Field, b: Field) -> Field {
    a + b
}

#[test]
fn adds_two_fields() {
    assert(add(2, 3) == 5);
}

#[test]
unconstrained fn adds_unconstrained() {
    assert(add(1, 1) == 2);
}

#[test]
fn genuinely_fails() {
    assert(add(1, 1) == 3, "one plus one is not three");
}

// The trailing comment on the next line carries a `mod` keyword and an open
// brace. If line comments were not masked before declarations are read, it
// would open a module frame called `ghost`, and every selector below would
// silently gain a `ghost::` segment that nargo has never heard of.
pub fn helper() -> Field { add(1, 2) } // mod ghost {

mod nested {
    #[test]
    fn nested_case() {
        assert(super::add(4, 4) == 8);
    }
}
