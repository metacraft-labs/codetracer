use rust_sample_project_lib::add;

fn main() {
    println!("Hell othere");
    let x = add(1, 2);
}

#[test]
fn trivial_test() {
    assert_eq!(1, 1);
    assert_eq!(2, 2);
}
