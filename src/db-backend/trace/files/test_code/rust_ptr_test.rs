struct Test {
    a: i32,
    b: i32,
}

fn main() {
    let my_num: i32 = 10;
    let my_num_ptr: *const i32 = &my_num;

    let my_test: Test = Test { a: 1, b: 2 };

    let my_test_ptr: &Test = &my_test;

    let my_test_ptr_ptr: &&Test = &my_test_ptr;

    std::process::exit((*my_test_ptr).b)

}
