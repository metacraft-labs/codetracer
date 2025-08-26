// use std::num::NonZero;

struct TestStruct {
    a: i32,
}

fn test_struct(a: i32) -> TestStruct {
    TestStruct { a: a }
}

fn number() -> usize {
    1
}
// fn non_zero() -> NonZero<usize> {
    // NonZero::new(2).unwrap()
// }

fn main() {
    let test = test_struct(123);

    let dummy = test_struct(234);

    let first = number();

    // let i = non_zero();
    println!("{}", test.a);

    std::process::exit(0)
}
