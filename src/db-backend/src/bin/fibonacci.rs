fn fibonacci(n: u64) -> u64 {
    if n <= 1 {
        return n;
    }

    let mut a = 0;
    let mut b = 1;

    for _ in 2..=n {
        let next = a + b;
        a = b;
        b = next;
    }
    b
}

fn main() {
    let n = 10;
    println!("The {}th Fibonacci number is: {}", n, fibonacci(n));

    let n_large = 50; // Test with a larger number to show performance improvement
    println!("The {}th Fibonacci number is: {}", n_large, fibonacci(n_large));
}
