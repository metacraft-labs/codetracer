//! Arbitrary-precision signed integer arithmetic using base-10 strings.
//!
//! Public helpers operate purely on `&str` and return `Result<String, LongIntError>`
//! so callers never manipulate the internal representation directly. Internally we
//! maintain a `LongInt` with a sign flag and little-endian digit buffer to keep
//! control flow explicit for the CodeTracer demo (multiple nested loops, branches,
//! and helper calls).

use std::cmp::Ordering;
use std::fmt;

/// Sign flag for a `LongInt`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sign {
    Positive,
    Negative,
}

/// Internal representation of an arbitrary-length signed integer.
///
/// Digits are stored little-endian (least significant first). Invariants:
/// - `digits` is never empty.
/// - Zero is `[0]` with `Sign::Positive`.
/// - No unnecessary leading zeros in canonical form.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LongInt {
    sign: Sign,
    digits: Vec<u8>,
}

impl LongInt {
    fn zero() -> Self {
        Self {
            sign: Sign::Positive,
            digits: vec![0],
        }
    }

    fn is_zero(&self) -> bool {
        self.digits.len() == 1 && self.digits[0] == 0
    }

    fn normalize(&mut self) {
        while self.digits.len() > 1 && *self.digits.last().unwrap() == 0 {
            self.digits.pop();
        }
        if self.is_zero() {
            self.sign = Sign::Positive;
        }
    }
}

/// Parsing failures for `LongInt`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParseError {
    Empty,
    SignWithoutDigits,
    InvalidDigit(char),
}

/// Errors surfaced by public string-based operations.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LongIntError {
    Parse(ParseError),
    DivisionByZero,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::Empty => write!(f, "input is empty"),
            ParseError::SignWithoutDigits => write!(f, "sign without digits"),
            ParseError::InvalidDigit(ch) => write!(f, "invalid digit '{}'", ch),
        }
    }
}

impl fmt::Display for LongIntError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LongIntError::Parse(err) => write!(f, "parse error: {}", err),
            LongIntError::DivisionByZero => write!(f, "division by zero"),
        }
    }
}

impl std::error::Error for LongIntError {}

impl From<ParseError> for LongIntError {
    fn from(value: ParseError) -> Self {
        LongIntError::Parse(value)
    }
}

/// Parse a decimal string into a normalized `LongInt`.
pub fn parse_long_int(input: &str) -> Result<LongInt, LongIntError> {
    if input.is_empty() {
        return Err(ParseError::Empty.into());
    }
    let (sign, digits_part) = parse_sign(input);
    if digits_part.is_empty() {
        return Err(ParseError::SignWithoutDigits.into());
    }
    let digits = parse_digits(digits_part)?;
    let mut value = LongInt { sign, digits };
    value.normalize();
    Ok(value)
}

/// Render a `LongInt` into canonical string form.
pub fn format_long_int(value: &LongInt) -> String {
    if value.is_zero() {
        return "0".to_string();
    }
    let mut s = String::new();
    if value.sign == Sign::Negative {
        s.push('-');
    }
    for digit in value.digits.iter().rev() {
        s.push(char::from(b'0' + *digit));
    }
    s
}

fn parse_sign(input: &str) -> (Sign, &str) {
    let mut chars = input.chars();
    if let Some(first) = chars.next() {
        match first {
            '+' => (Sign::Positive, chars.as_str()),
            '-' => (Sign::Negative, chars.as_str()),
            _ => (Sign::Positive, input),
        }
    } else {
        (Sign::Positive, input)
    }
}

fn parse_digits(input: &str) -> Result<Vec<u8>, ParseError> {
    let mut digits = Vec::with_capacity(input.len());
    for ch in input.chars() {
        if let Some(val) = ch.to_digit(10) {
            digits.push(val as u8);
        } else {
            return Err(ParseError::InvalidDigit(ch));
        }
    }
    digits.reverse(); // little-endian
    if digits.is_empty() {
        Err(ParseError::Empty)
    } else {
        Ok(normalize_digits(digits))
    }
}

fn normalize_digits(mut digits: Vec<u8>) -> Vec<u8> {
    while digits.len() > 1 && *digits.last().unwrap() == 0 {
        digits.pop();
    }
    if digits.is_empty() {
        vec![0]
    } else if digits.len() == 1 && digits[0] == 0 {
        vec![0]
    } else {
        digits
    }
}

fn cmp_magnitude(a: &LongInt, b: &LongInt) -> Ordering {
    if a.digits.len() != b.digits.len() {
        return a.digits.len().cmp(&b.digits.len());
    }
    for (da, db) in a.digits.iter().rev().zip(b.digits.iter().rev()) {
        if da != db {
            return da.cmp(db);
        }
    }
    Ordering::Equal
}

fn add_magnitude(a: &LongInt, b: &LongInt) -> LongInt {
    let mut result = Vec::with_capacity(a.digits.len().max(b.digits.len()) + 1);
    let mut carry = 0u8;
    let max_len = a.digits.len().max(b.digits.len());

    for idx in 0..max_len {
        let da = *a.digits.get(idx).unwrap_or(&0);
        let db = *b.digits.get(idx).unwrap_or(&0);
        let sum = da as u16 + db as u16 + carry as u16;
        result.push((sum % 10) as u8);
        carry = (sum / 10) as u8;
    }

    if carry > 0 {
        result.push(carry);
    }

    let mut value = LongInt {
        sign: Sign::Positive,
        digits: result,
    };
    value.normalize();
    value
}

fn sub_magnitude(a: &LongInt, b: &LongInt) -> LongInt {
    // Assumes |a| >= |b|.
    let mut result = Vec::with_capacity(a.digits.len());
    let mut borrow = 0i8;
    for idx in 0..a.digits.len() {
        let mut da = a.digits[idx] as i8 - borrow;
        let db = *b.digits.get(idx).unwrap_or(&0) as i8;
        if da < db {
            da += 10;
            borrow = 1;
        } else {
            borrow = 0;
        }
        result.push((da - db) as u8);
    }
    let mut value = LongInt {
        sign: Sign::Positive,
        digits: result,
    };
    value.normalize();
    value
}

fn add_with_sign(a: &LongInt, b: &LongInt) -> LongInt {
    match (a.sign, b.sign) {
        (Sign::Positive, Sign::Positive) => {
            let mut res = add_magnitude(a, b);
            res.sign = Sign::Positive;
            res
        }
        (Sign::Negative, Sign::Negative) => {
            let mut res = add_magnitude(a, b);
            res.sign = Sign::Negative;
            if res.is_zero() {
                res.sign = Sign::Positive;
            }
            res
        }
        _ => {
            // Different signs: subtract smaller magnitude from larger.
            match cmp_magnitude(a, b) {
                Ordering::Greater => {
                    let mut res = sub_magnitude(a, b);
                    res.sign = a.sign;
                    if res.is_zero() {
                        res.sign = Sign::Positive;
                    }
                    res
                }
                Ordering::Less => {
                    let mut res = sub_magnitude(b, a);
                    res.sign = b.sign;
                    if res.is_zero() {
                        res.sign = Sign::Positive;
                    }
                    res
                }
                Ordering::Equal => LongInt::zero(),
            }
        }
    }
}

fn sub_with_sign(a: &LongInt, b: &LongInt) -> LongInt {
    // a - b == a + (-b)
    let mut neg_b = b.clone();
    if !neg_b.is_zero() {
        neg_b.sign = match b.sign {
            Sign::Positive => Sign::Negative,
            Sign::Negative => Sign::Positive,
        };
    }
    add_with_sign(a, &neg_b)
}

fn mul_by_single_digit(a: &LongInt, digit: u8) -> LongInt {
    if digit == 0 {
        return LongInt::zero();
    }
    let mut result = Vec::with_capacity(a.digits.len() + 1);
    let mut carry = 0u16;
    for da in &a.digits {
        let prod = (*da as u16 * digit as u16) + carry;
        result.push((prod % 10) as u8);
        carry = prod / 10;
    }
    if carry > 0 {
        result.push(carry as u8);
    }
    let mut value = LongInt {
        sign: Sign::Positive,
        digits: result,
    };
    value.normalize();
    value
}

fn shift_left_digits(mut digits: Vec<u8>, shift: usize) -> Vec<u8> {
    if digits == vec![0] {
        return digits;
    }
    digits.splice(0..0, std::iter::repeat(0).take(shift));
    digits
}

fn mul_magnitude(a: &LongInt, b: &LongInt) -> LongInt {
    let mut result = LongInt::zero();
    for (idx, digit) in b.digits.iter().enumerate() {
        let mut partial = mul_by_single_digit(a, *digit);
        partial.digits = shift_left_digits(partial.digits, idx);
        result = add_magnitude(&result, &partial);
    }
    result
}

fn multiply(a: &LongInt, b: &LongInt) -> LongInt {
    let mut res = mul_magnitude(a, b);
    res.sign = if res.is_zero() || a.sign == b.sign {
        Sign::Positive
    } else {
        Sign::Negative
    };
    res
}

fn push_digit_high(remainder: &mut LongInt, digit: u8) {
    remainder.digits.insert(0, 0); // multiply by 10
    let mut carry = digit;
    let mut idx = 0;
    while carry > 0 {
        if idx >= remainder.digits.len() {
            remainder.digits.push(0);
        }
        let sum = remainder.digits[idx] + carry;
        remainder.digits[idx] = sum % 10;
        carry = sum / 10;
        idx += 1;
    }
    remainder.normalize();
}

fn div_mod_magnitude(dividend: &LongInt, divisor: &LongInt) -> (LongInt, LongInt) {
    match cmp_magnitude(dividend, divisor) {
        Ordering::Less => return (LongInt::zero(), dividend.clone()),
        Ordering::Equal => return (LongInt { sign: Sign::Positive, digits: vec![1] }, LongInt::zero()),
        Ordering::Greater => {}
    }

    let mut quotient_be = Vec::with_capacity(dividend.digits.len());
    let mut remainder = LongInt::zero();
    for digit in dividend.digits.iter().rev() {
        push_digit_high(&mut remainder, *digit);
        let mut q_digit = 0u8;
        while cmp_magnitude(&remainder, divisor) != Ordering::Less {
            remainder = sub_magnitude(&remainder, divisor);
            q_digit += 1;
        }
        quotient_be.push(q_digit);
    }

    while quotient_be.first().map(|d| *d == 0).unwrap_or(false) && quotient_be.len() > 1 {
        quotient_be.remove(0);
    }
    quotient_be.reverse();
    let mut quotient = LongInt {
        sign: Sign::Positive,
        digits: quotient_be,
    };
    quotient.normalize();
    remainder.normalize();
    (quotient, remainder)
}

fn div_mod(a: &LongInt, b: &LongInt) -> Result<(LongInt, LongInt), LongIntError> {
    if b.is_zero() {
        return Err(LongIntError::DivisionByZero);
    }
    if a.is_zero() {
        return Ok((LongInt::zero(), LongInt::zero()));
    }
    let (mut q, mut r) = div_mod_magnitude(a, b);
    q.sign = if a.sign == b.sign { Sign::Positive } else { Sign::Negative };
    if q.is_zero() {
        q.sign = Sign::Positive;
    }
    r.sign = a.sign;
    if r.is_zero() {
        r.sign = Sign::Positive;
    }
    Ok((q, r))
}

/// Add two decimal strings.
pub fn add_str(a: &str, b: &str) -> Result<String, LongIntError> {
    let a_val = parse_long_int(a)?;
    let b_val = parse_long_int(b)?;
    let res = add_with_sign(&a_val, &b_val);
    Ok(format_long_int(&res))
}

/// Subtract `b` from `a` using decimal strings.
pub fn sub_str(a: &str, b: &str) -> Result<String, LongIntError> {
    let a_val = parse_long_int(a)?;
    let b_val = parse_long_int(b)?;
    let res = sub_with_sign(&a_val, &b_val);
    Ok(format_long_int(&res))
}

/// Multiply two decimal strings.
pub fn mul_str(a: &str, b: &str) -> Result<String, LongIntError> {
    let a_val = parse_long_int(a)?;
    let b_val = parse_long_int(b)?;
    let res = multiply(&a_val, &b_val);
    Ok(format_long_int(&res))
}

/// Integer division with truncation toward zero.
pub fn div_str(a: &str, b: &str) -> Result<String, LongIntError> {
    let a_val = parse_long_int(a)?;
    let b_val = parse_long_int(b)?;
    let (q, _) = div_mod(&a_val, &b_val)?;
    Ok(format_long_int(&q))
}

/// Remainder with the same sign as the dividend.
pub fn rem_str(a: &str, b: &str) -> Result<String, LongIntError> {
    let a_val = parse_long_int(a)?;
    let b_val = parse_long_int(b)?;
    let (_, r) = div_mod(&a_val, &b_val)?;
    Ok(format_long_int(&r))
}

/// Division that returns both quotient and remainder.
pub fn div_mod_str(a: &str, b: &str) -> Result<(String, String), LongIntError> {
    let a_val = parse_long_int(a)?;
    let b_val = parse_long_int(b)?;
    let (q, r) = div_mod(&a_val, &b_val)?;
    Ok((format_long_int(&q), format_long_int(&r)))
}

/// Negate a decimal string.
pub fn negate_str(a: &str) -> Result<String, LongIntError> {
    let mut value = parse_long_int(a)?;
    if !value.is_zero() {
        value.sign = match value.sign {
            Sign::Positive => Sign::Negative,
            Sign::Negative => Sign::Positive,
        };
    }
    Ok(format_long_int(&value))
}

/// Absolute value of a decimal string.
pub fn abs_str(a: &str) -> Result<String, LongIntError> {
    let mut value = parse_long_int(a)?;
    value.sign = Sign::Positive;
    Ok(format_long_int(&value))
}

/// Compare two decimal strings.
pub fn cmp_str(a: &str, b: &str) -> Result<Ordering, LongIntError> {
    let a_val = parse_long_int(a)?;
    let b_val = parse_long_int(b)?;
    let ordering = match (a_val.sign, b_val.sign) {
        (Sign::Positive, Sign::Negative) => Ordering::Greater,
        (Sign::Negative, Sign::Positive) => Ordering::Less,
        _ => {
            let cmp = cmp_magnitude(&a_val, &b_val);
            if a_val.sign == Sign::Positive {
                cmp
            } else {
                cmp.reverse()
            }
        }
    };
    Ok(ordering)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_ok_eq(result: Result<String, LongIntError>, expected: &str) {
        match result {
            Ok(v) => assert_eq!(v, expected),
            Err(e) => panic!("expected Ok({}), got Err({:?})", expected, e),
        }
    }

    #[test]
    fn parse_basic_inputs() {
        assert_eq!(parse_long_int("0").unwrap(), LongInt::zero());
        assert_eq!(
            parse_long_int("123").unwrap(),
            LongInt {
                sign: Sign::Positive,
                digits: vec![3, 2, 1]
            }
        );
        assert_eq!(
            parse_long_int("-456").unwrap(),
            LongInt {
                sign: Sign::Negative,
                digits: vec![6, 5, 4]
            }
        );
    }

    #[test]
    fn parse_with_leading_zeros_and_plus() {
        assert_eq!(parse_long_int("0000").unwrap(), LongInt::zero());
        assert_eq!(
            parse_long_int("000123").unwrap(),
            LongInt {
                sign: Sign::Positive,
                digits: vec![3, 2, 1]
            }
        );
        assert_eq!(
            parse_long_int("-000123").unwrap(),
            LongInt {
                sign: Sign::Negative,
                digits: vec![3, 2, 1]
            }
        );
        assert_eq!(
            parse_long_int("+42").unwrap(),
            LongInt {
                sign: Sign::Positive,
                digits: vec![2, 4]
            }
        );
        assert_eq!(parse_long_int("+0").unwrap(), LongInt::zero());
        assert_eq!(parse_long_int("-0").unwrap(), LongInt::zero());
    }

    #[test]
    fn parse_invalid_inputs() {
        assert!(matches!(
            parse_long_int(""),
            Err(LongIntError::Parse(ParseError::Empty))
        ));
        assert!(matches!(
            parse_long_int("+"),
            Err(LongIntError::Parse(ParseError::SignWithoutDigits))
        ));
        assert!(matches!(
            parse_long_int("-"),
            Err(LongIntError::Parse(ParseError::SignWithoutDigits))
        ));
        assert!(matches!(
            parse_long_int("12a34"),
            Err(LongIntError::Parse(ParseError::InvalidDigit('a')))
        ));
        assert!(matches!(
            parse_long_int("--1"),
            Err(LongIntError::Parse(ParseError::InvalidDigit('-')))
        ));
        assert!(matches!(
            parse_long_int(" 123"),
            Err(LongIntError::Parse(ParseError::InvalidDigit(' ')))
        ));
    }

    #[test]
    fn round_trip_formatting() {
        let cases = ["000123", "-000123", "+0", "0", "999"];
        for case in cases {
            let parsed = parse_long_int(case).unwrap();
            let rendered = format_long_int(&parsed);
            match case {
                "000123" => assert_eq!(rendered, "123"),
                "-000123" => assert_eq!(rendered, "-123"),
                "+0" | "0" => assert_eq!(rendered, "0"),
                "999" => assert_eq!(rendered, "999"),
                _ => unreachable!(),
            }
        }
    }

    #[test]
    fn add_simple_cases() {
        assert_ok_eq(add_str("0", "0"), "0");
        assert_ok_eq(add_str("0", "123"), "123");
        assert_ok_eq(add_str("123", "0"), "123");
        assert_ok_eq(add_str("1", "2"), "3");
        assert_ok_eq(add_str("10", "20"), "30");
        assert_ok_eq(add_str("9", "1"), "10");
        assert_ok_eq(add_str("99", "1"), "100");
        assert_ok_eq(add_str("9999", "1"), "10000");
        assert_ok_eq(add_str("1234", "5678"), "6912");
        assert_ok_eq(add_str("5", "12345"), "12350");
        assert_ok_eq(add_str("12345", "5"), "12350");
    }

    #[test]
    fn add_mixed_signs() {
        assert_ok_eq(add_str("5", "-3"), "2");
        assert_ok_eq(add_str("-5", "3"), "-2");
        assert_ok_eq(add_str("123", "-123"), "0");
        assert_ok_eq(add_str("-123", "-1"), "-124");
    }

    #[test]
    fn add_commutativity_small_values() {
        let pairs = [("7", "-4"), ("99", "1"), ("0", "0"), ("50", "75")];
        for (a, b) in pairs {
            let ab = add_str(a, b).unwrap();
            let ba = add_str(b, a).unwrap();
            assert_eq!(ab, ba, "commutativity failed for {a}, {b}");
        }
    }

    #[test]
    fn arithmetic_consistency_with_i128() {
        let pairs = [("123456", "-654321"), ("-9999", "-1"), ("5000000", "4000")];
        for (a, b) in pairs {
            let ai: i128 = a.parse().unwrap();
            let bi: i128 = b.parse().unwrap();

            let sum_expected = (ai + bi).to_string();
            let sum_actual = add_str(a, b).unwrap();
            assert_eq!(sum_actual, sum_expected, "add mismatch for {a}, {b}");

            let diff_expected = (ai - bi).to_string();
            let diff_actual = sub_str(a, b).unwrap();
            assert_eq!(diff_actual, diff_expected, "sub mismatch for {a}, {b}");

            // Add a console writeleine here

            let prod_expected = (ai * bi).to_string();
            let prod_actual = mul_str(a, b).unwrap();
            assert_eq!(prod_actual, prod_expected, "mul mismatch for {a}, {b}");

            if bi != 0 {
                let quot_expected = (ai / bi).to_string();
                let rem_expected = (ai % bi).to_string();
                let quot_actual = div_str(a, b).unwrap();
                let rem_actual = rem_str(a, b).unwrap();
                assert_eq!(quot_actual, quot_expected, "div mismatch for {a}, {b}");
                assert_eq!(rem_actual, rem_expected, "rem mismatch for {a}, {b}");
            }
        }
    }

    #[test]
    fn sub_basic_cases() {
        assert_ok_eq(sub_str("5", "3"), "2");
        assert_ok_eq(sub_str("3", "5"), "-2");
        assert_ok_eq(sub_str("0", "0"), "0");
        assert_ok_eq(sub_str("10", "1"), "9");
        assert_ok_eq(sub_str("1000", "1"), "999");
        assert_ok_eq(sub_str("1000", "999"), "1");
    }

    #[test]
    fn sub_mixed_signs() {
        assert_ok_eq(sub_str("5", "-3"), "8");
        assert_ok_eq(sub_str("-5", "3"), "-8");
        assert_ok_eq(sub_str("-5", "-3"), "-2");
        assert_ok_eq(sub_str("-3", "-5"), "2");
        assert_ok_eq(sub_str("123456789", "123456789"), "0");
    }

    #[test]
    fn sub_anti_commutativity() {
        let pairs = [("7", "4"), ("50", "-2"), ("123", "5")];
        for (a, b) in pairs {
            let ab = sub_str(a, b).unwrap();
            let ba = sub_str(b, a).unwrap();
            let neg_ba = negate_str(&ba).unwrap();
            assert_eq!(ab, neg_ba, "anti-commutativity failed for {a}, {b}");
        }
    }

    #[test]
    fn mul_various_cases() {
        assert_ok_eq(mul_str("0", "0"), "0");
        assert_ok_eq(mul_str("0", "123456"), "0");
        assert_ok_eq(mul_str("123456", "0"), "0");
        assert_ok_eq(mul_str("1", "123"), "123");
        assert_ok_eq(mul_str("-1", "123"), "-123");
        assert_ok_eq(mul_str("-1", "-123"), "123");
        assert_ok_eq(mul_str("2", "3"), "6");
        assert_ok_eq(mul_str("12", "12"), "144");
        assert_ok_eq(mul_str("99", "99"), "9801");
        assert_ok_eq(mul_str("1234", "5678"), "7006652");
        assert_ok_eq(mul_str("-3", "4"), "-12");
        assert_ok_eq(mul_str("3", "-4"), "-12");
        assert_ok_eq(mul_str("-3", "-4"), "12");
    }

    #[test]
    fn mul_large_numbers() {
        // 12345678901234567890 * 98765432109876543210
        assert_ok_eq(
            mul_str("12345678901234567890", "98765432109876543210"),
            "1219326311370217952237463801111263526900",
        );
        // Leading zeros should not affect result.
        assert_ok_eq(
            mul_str("000123", "000004"),
            "492",
        );
    }

    #[test]
    fn div_and_rem_behaviors() {
        assert!(matches!(
            div_str("1", "0"),
            Err(LongIntError::DivisionByZero)
        ));
        assert!(matches!(
            rem_str("0", "0"),
            Err(LongIntError::DivisionByZero)
        ));

        assert_ok_eq(div_str("10", "2"), "5");
        assert_ok_eq(rem_str("10", "2"), "0");
        assert_ok_eq(div_str("100", "10"), "10");
        assert_ok_eq(rem_str("100", "10"), "0");

        assert_ok_eq(div_str("7", "2"), "3");
        assert_ok_eq(rem_str("7", "2"), "1");
        assert_ok_eq(div_str("15", "4"), "3");
        assert_ok_eq(rem_str("15", "4"), "3");

        assert_ok_eq(div_str("3", "5"), "0");
        assert_ok_eq(rem_str("3", "5"), "3");

        assert_ok_eq(div_str("7", "-2"), "-3");
        assert_ok_eq(rem_str("7", "-2"), "1");
        assert_ok_eq(div_str("-7", "2"), "-3");
        assert_ok_eq(rem_str("-7", "2"), "-1");
        assert_ok_eq(div_str("-7", "-2"), "3");
        assert_ok_eq(rem_str("-7", "-2"), "-1");
    }

    #[test]
    fn div_mod_invariant() {
        let cases = [
            ("12345", "67"),
            ("1000", "3"),
            ("-999", "7"),
            ("999", "-7"),
            ("50", "4"),
        ];
        for (a, b) in cases {
            let (q_str, r_str) = div_mod_str(a, b).unwrap();
            let recomposed = add_str(&mul_str(b, &q_str).unwrap(), &r_str).unwrap();
            let cmp = cmp_str(&recomposed, a).unwrap();
            assert_eq!(cmp, Ordering::Equal, "failed invariant for {a} / {b}");

            let abs_r_vs_b = cmp_str(&abs_str(&r_str).unwrap(), &abs_str(b).unwrap()).unwrap();
            assert!(
                abs_r_vs_b == Ordering::Less,
                "remainder magnitude too large for {a} / {b}"
            );
        }
    }

    #[test]
    fn negate_and_abs() {
        assert_ok_eq(negate_str("0"), "0");
        assert_ok_eq(negate_str("123"), "-123");
        assert_ok_eq(negate_str("-123"), "123");
        assert_ok_eq(negate_str("0000"), "0");
        assert_ok_eq(negate_str("-0005"), "5");

        assert_ok_eq(abs_str("0"), "0");
        assert_ok_eq(abs_str("123"), "123");
        assert_ok_eq(abs_str("-123"), "123");
        assert_ok_eq(abs_str("000123"), "123");
        assert_ok_eq(abs_str("-000123"), "123");
    }

    #[test]
    fn cmp_cases() {
        assert_eq!(cmp_str("0", "0").unwrap(), Ordering::Equal);
        assert_eq!(cmp_str("1", "0").unwrap(), Ordering::Greater);
        assert_eq!(cmp_str("0", "1").unwrap(), Ordering::Less);
        assert_eq!(cmp_str("123", "122").unwrap(), Ordering::Greater);
        assert_eq!(cmp_str("-123", "-122").unwrap(), Ordering::Less);
        assert_eq!(cmp_str("-1", "1").unwrap(), Ordering::Less);
        assert_eq!(cmp_str("1", "-1").unwrap(), Ordering::Greater);
        assert_eq!(cmp_str("000123", "123").unwrap(), Ordering::Equal);
        assert_eq!(cmp_str("-000123", "-123").unwrap(), Ordering::Equal);
    }

    #[test]
    fn integration_expression() {
        // ((a + b) * c - d) / e for small values
        let a = "1234";
        let b = "-56";
        let c = "7";
        let d = "8";
        let e = "3";
        let sum = add_str(a, b).unwrap();
        let prod = mul_str(&sum, c).unwrap();
        let diff = sub_str(&prod, d).unwrap();
        let quotient = div_str(&diff, e).unwrap();
        let remainder = rem_str(&diff, e).unwrap();

        // Compare with i128
        let expected = ((1234i128 + -56) * 7 - 8) / 3;
        let expected_rem = ((1234i128 + -56) * 7 - 8) % 3;
        assert_eq!(quotient, expected.to_string());
        assert_eq!(remainder, expected_rem.to_string());
    }

    #[test]
    fn long_number_showcase() {
        // Multiply two 50-digit numbers and divide back.
        let a = "12345678901234567890123456789012345678901234567890";
        let b = "99999999999999999999999999999999999999999999999999";
        let expected_product = "1234567890123456789012345678901234567890123456788987654321098765432109876543210987654321098765432110";
        let product = mul_str(a, b).unwrap();
        assert_eq!(product, expected_product);
        let (q, r) = div_mod_str(&product, a).unwrap();
        assert_eq!(q, b);
        assert_eq!(r, "0");
    }
}
