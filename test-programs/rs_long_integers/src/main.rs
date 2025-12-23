//! Scripted demo for the long integer string calculator.
//! Instead of prompting for input, it runs a fixed suite of scenarios
//! (mirroring the library tests) defined as raw strings for easy editing
//! during CodeTracer demos.

use rs_long_integers::{
    abs_str, add_str, cmp_str, div_mod_str, div_str, mul_str, negate_str, rem_str, sub_str,
    LongIntError,
};

/// Raw scenario lines: `op arg1 [arg2] => expected`.
const SCENARIOS: &[&str] = &[
    "add 9 1 => 10",
    "add -5 3 => -2",
    "sub 3 5 => -2",
    "sub -3 -5 => 2",
    "mul 1234 5678 => 7006652",
    "mul 12345678901234567890 98765432109876543210 => 1219326311370217952237463801111263526900",
    "div 7 2 => 3",
    "rem 7 2 => 1",
    "div -7 -2 => 3",
    "rem -7 2 => -1",
    "divmod 12345 67 => 184|17",
    "neg -0005 => 5",
    "abs -000123 => 123",
    "cmp 123 123 => Equal",
    "cmp -1 1 => Less",
];

#[derive(Debug)]
struct Scenario {
    raw: &'static str,
    op: String,
    first: String,
    second: Option<String>,
    expected: String,
}

fn parse_scenario(raw: &'static str) -> Result<Scenario, String> {
    let mut parts = raw.split("=>").map(str::trim);
    let left = parts.next().ok_or("missing left side")?;
    let expected = parts
        .next()
        .ok_or("missing expected value")?
        .trim()
        .to_string();

    let mut tokens = left.split_whitespace();
    let op = tokens.next().ok_or("missing operation")?.to_string();
    let first = tokens.next().ok_or("missing first operand")?.to_string();
    let second = tokens.next().map(|s| s.to_string());

    let needs_second = matches!(op.as_str(), "add" | "sub" | "mul" | "div" | "rem" | "divmod" | "cmp");
    if needs_second && second.is_none() {
        return Err("second operand required".to_string());
    }

    Ok(Scenario {
        raw,
        op,
        first,
        second,
        expected,
    })
}

fn run_scenario(s: &Scenario) -> Result<String, LongIntError> {
    match s.op.as_str() {
        "add" => add_str(&s.first, s.second.as_deref().unwrap()),
        "sub" => sub_str(&s.first, s.second.as_deref().unwrap()),
        "mul" => mul_str(&s.first, s.second.as_deref().unwrap()),
        "div" => div_str(&s.first, s.second.as_deref().unwrap()),
        "rem" => rem_str(&s.first, s.second.as_deref().unwrap()),
        "divmod" => div_mod_str(&s.first, s.second.as_deref().unwrap())
            .map(|(q, r)| format!("{q}|{r}")),
        "neg" => negate_str(&s.first),
        "abs" => abs_str(&s.first),
        "cmp" => cmp_str(&s.first, s.second.as_deref().unwrap())
            .map(|ord| format!("{ord:?}")),
        other => Err(LongIntError::Parse(
            rs_long_integers::ParseError::InvalidDigit(other.chars().next().unwrap_or('?')),
        )),
    }
}

fn main() {
    println!("Long integer calculator scripted demo:");
    for raw in SCENARIOS {
        match parse_scenario(raw) {
            Ok(s) => match run_scenario(&s) {
                Ok(result) => {
                    let status = if result == s.expected { "OK" } else { "MISMATCH" };
                    println!(
                        "[{status}] {} -> got: {} | expected: {}",
                        s.raw, result, s.expected
                    );
                }
                Err(err) => println!("[ERROR] {} -> error: {}", s.raw, err),
            },
            Err(err) => println!("[PARSE ERROR] {} -> {}", raw, err),
        }
    }
}
