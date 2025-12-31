// Simple Rust program for flow/omniscience integration testing
// This program tests that local variables inside functions can be loaded.

fn calculate_sum(a: i32, b: i32) -> i32 {
    // Local variables inside a function
    let sum = a + b;
    let doubled = sum * 2;
    let final_result = doubled + 10;
    println!("Sum: {}", sum);
    println!("Doubled: {}", doubled);
    println!("Final: {}", final_result);
    final_result
}

fn main() {
    // Local variables in main
    let x = 10;
    let y = 32;
    let result = calculate_sum(x, y);
    println!("Result: {}", result);
    with_loops(x);
}

fn with_loops(a: i32) {
    let mut sum = 0;
    for i in 0..a {
        sum += i;
    }
    println!("sum with for {sum}");

    sum = 0;
    let mut i_2 = 0;
    loop {
        sum += i_2;
        if i_2 >= a - 1 {
            break;
        }
        i_2 += 1;
    }
    println!("sum with loop {sum}");

    sum = 0;
    let mut i_3 = 0;
    while i_3 < a {
        sum += i_3;
        i_3 += 1;
    }
    println!("sum with while {sum}");
}
