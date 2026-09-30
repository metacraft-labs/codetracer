//! Crate-level documentation.
/* A block comment that
   spans lines, /* nested */ still a comment */
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct Point<T> {
    x: T,
    y: T,
}

/// Distance from the origin.
fn norm(p: &Point<f64>) -> f64 {
    let squared = p.x * p.x + p.y * p.y;
    squared.sqrt()
}

impl<T: Copy + std::fmt::Display> Point<T> {
    pub fn describe(&self) -> String {
        format!("({}, {})", self.x, self.y)
    }
}

fn main() {
    let mut counts: HashMap<&str, u32> = HashMap::new();
    let raw = r#"a "raw" string"#;
    let byte = b'x';
    let ch = '\n';
    let hex = 0xFF_u8;
    let big = 1_000_000i64;
    let float = 3.14e-2;
    for word in "one two two".split(' ') {
        *counts.entry(word).or_insert(0) += 1;
    }
    if counts.len() > 1 && !raw.is_empty() {
        println!("{:?} {} {} {} {} {}", counts, byte, ch, hex, big, float);
    }
    let lifetime: &'static str = "static";
    match hex {
        0..=9 => println!("small"),
        _ => println!("{}", lifetime),
    }
}
