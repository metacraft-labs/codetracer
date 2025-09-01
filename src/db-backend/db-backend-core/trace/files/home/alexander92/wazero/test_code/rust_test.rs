struct SampleAtomic {

    sample_atomic_i32: i32,
    // sample_atomic_u64: u64,

}
struct Sample<'a> {
    test_bool: bool,
    test_string: &'a str,
    test_i32: i32,
    test_sample_atomic: &'a SampleAtomic,
}

fn add_3_and_4() -> i32 {

    let blq = "abcd";

    let x = 3;
    let y = 4;

    let test_struct = Sample {
        test_bool: true,
        test_string: "test",
        test_i32: 7,
        test_sample_atomic: &SampleAtomic{
            sample_atomic_i32: 10,
            // sample_atomic_u64: 11,
        },
    };

    return x + y;

}

fn main() {

    let z = add_3_and_4();

}
