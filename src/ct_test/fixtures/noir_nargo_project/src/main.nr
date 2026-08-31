mod arithmetic;

fn main(x: Field, y: pub Field) {
    assert(x != y);
}

#[test]
fn passes_at_root() {
    assert(1 + 1 == 2);
}

#[test(should_fail)]
fn fails_on_purpose() {
    assert(1 == 2);
}

#[test(should_fail_with = "values differ")]
fn fails_with_message() {
    assert(1 == 2, "values differ");
}

// A commented-out test. The parser must NOT report it: `//` is masked before
// declarations are read, and a catalog entry for a test nargo will never list
// is a run button that does nothing.
// #[test]
// fn commented_out_is_not_a_test() {
//     assert(false);
// }

/* A block-commented one, /* nested */ for the same reason. */
/*
#[test]
fn block_commented_is_not_a_test() {
    assert(false);
}
*/

fn not_a_test_at_all() -> Field {
    // The string below contains the text of an attribute. Masking string
    // literals is what stops it from being read as a declaration.
    let _marker = "#[test] fn string_literal_is_not_a_test() {}";
    7
}
