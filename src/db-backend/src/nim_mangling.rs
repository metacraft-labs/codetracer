//! Nim name mangling utilities
//!
//! Nim mangles global variable and procedure names when generating C code.
//! This module provides functions to compute mangled names from Nim source names.
//!
//! Mangling pattern for global symbols:
//!   `<mangled_name>__<encoded_module_name>_u<item_id>`
//!
//! The module name encoding differs by Nim version:
//!
//! **Nim 1.6.x** (ROT13 style):
//!   `intValue__avz95sybj95grfg_u1`
//!   Where `avz95sybj95grfg` is ROT13-encoded "nim_flow_test" (underscores → "95")
//!
//! **Nim 2.x** (direct style):
//!   `intValue__nim95flow95test_u1`
//!   Where `nim95flow95test` is the module name with underscores → "95" (no ROT13)
//!
//! The `MangledNameDualIterator` tries both styles, remembering which one succeeds
//! to optimize future lookups.

use std::path::Path;
use std::sync::atomic::{AtomicU8, Ordering};

/// Nim mangling style - differs between major Nim versions
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(non_camel_case_types)] // Using underscores for version clarity (V1_6 vs V16)
pub enum NimManglingStyle {
    /// Nim 1.6.x style: uses ROT13 encoding for module names
    V1_6_Rot13,
    /// Nim 2.x style: no ROT13 encoding, direct module name
    V2_Direct,
}

/// Global preference for which mangling style to try first.
/// 0 = unknown (try V1_6 first), 1 = V1_6, 2 = V2
static PREFERRED_STYLE: AtomicU8 = AtomicU8::new(0);

impl NimManglingStyle {
    /// Get the currently preferred mangling style (based on past successes)
    pub fn preferred() -> Self {
        match PREFERRED_STYLE.load(Ordering::Relaxed) {
            2 => NimManglingStyle::V2_Direct,
            _ => NimManglingStyle::V1_6_Rot13, // Default to V1_6 when unknown
        }
    }

    /// Record that this style succeeded (for future preference)
    pub fn record_success(style: NimManglingStyle) {
        let value = match style {
            NimManglingStyle::V1_6_Rot13 => 1,
            NimManglingStyle::V2_Direct => 2,
        };
        PREFERRED_STYLE.store(value, Ordering::Relaxed);
    }

    /// Get the alternate style
    pub fn alternate(self) -> Self {
        match self {
            NimManglingStyle::V1_6_Rot13 => NimManglingStyle::V2_Direct,
            NimManglingStyle::V2_Direct => NimManglingStyle::V1_6_Rot13,
        }
    }
}

/// Apply ROT13 encoding to a character
fn rot13_char(c: char) -> char {
    match c {
        'a'..='m' | 'A'..='M' => ((c as u8) + 13) as char,
        'n'..='z' | 'N'..='Z' => ((c as u8) - 13) as char,
        _ => c,
    }
}

/// Encode a module name into a buffer using the specified Nim mangling style
///
/// Nim mangling rules:
/// - Lowercase letters: ROT13 (V1_6) or pass through (V2)
/// - Digits 0-9: pass through unchanged
/// - Underscore: convert to `95` (ASCII ordinal)
/// - Directory separator: convert to `Z`
/// - Dot: convert to `O`
/// - Other characters: convert to ASCII ordinal
fn encode_nim_module_name_into(module_name: &str, style: NimManglingStyle, buf: &mut String) {
    for c in module_name.chars() {
        match c {
            'a'..='z' => {
                if style == NimManglingStyle::V1_6_Rot13 {
                    buf.push(rot13_char(c));
                } else {
                    buf.push(c);
                }
            }
            '0'..='9' => buf.push(c),
            '/' | '\\' => buf.push('Z'),
            '.' => buf.push('O'),
            '_' => buf.push_str("95"),
            _ => {
                // Other characters get their ASCII ordinal
                write_usize_to_string(c as usize, buf);
            }
        }
    }
}

/// Mangle a Nim identifier into a buffer (for special characters in names)
///
/// Based on Nim's `mangle` function:
/// - Alphanumerics pass through
/// - Special operators get word representations
/// - Other characters get hex encoded
#[allow(clippy::unwrap_used)] // char::from_digit always succeeds for 0-15
fn mangle_nim_identifier_into(name: &str, buf: &mut String) {
    let mut requires_underscore = false;
    let mut chars = name.chars().peekable();
    let mut i = 0;

    // Handle leading digit
    if let Some(&first) = chars.peek() {
        if first.is_ascii_digit() {
            buf.push('X');
            buf.push(first);
            chars.next();
            i = 1;
        }
    }

    while let Some(c) = chars.next() {
        match c {
            'a'..='z' | 'A'..='Z' | '0'..='9' => buf.push(c),
            '_' => {
                // Skip underscore if followed by a digit (used for scope disambiguation)
                if i > 0 && chars.peek().is_some_and(|next| next.is_ascii_digit()) {
                    // Skip this underscore
                } else {
                    buf.push(c);
                }
            }
            '$' => {
                buf.push_str("dollar");
                requires_underscore = true;
            }
            '%' => {
                buf.push_str("percent");
                requires_underscore = true;
            }
            '&' => {
                buf.push_str("amp");
                requires_underscore = true;
            }
            '^' => {
                buf.push_str("roof");
                requires_underscore = true;
            }
            '!' => {
                buf.push_str("emark");
                requires_underscore = true;
            }
            '?' => {
                buf.push_str("qmark");
                requires_underscore = true;
            }
            '*' => {
                buf.push_str("star");
                requires_underscore = true;
            }
            '+' => {
                buf.push_str("plus");
                requires_underscore = true;
            }
            '-' => {
                buf.push_str("minus");
                requires_underscore = true;
            }
            '/' => {
                buf.push_str("slash");
                requires_underscore = true;
            }
            '\\' => {
                buf.push_str("backslash");
                requires_underscore = true;
            }
            '=' => {
                buf.push_str("eq");
                requires_underscore = true;
            }
            '<' => {
                buf.push_str("lt");
                requires_underscore = true;
            }
            '>' => {
                buf.push_str("gt");
                requires_underscore = true;
            }
            '~' => {
                buf.push_str("tilde");
                requires_underscore = true;
            }
            ':' => {
                buf.push_str("colon");
                requires_underscore = true;
            }
            '.' => {
                buf.push_str("dot");
                requires_underscore = true;
            }
            '@' => {
                buf.push_str("at");
                requires_underscore = true;
            }
            '|' => {
                buf.push_str("bar");
                requires_underscore = true;
            }
            _ => {
                buf.push('X');
                // Write hex value
                let val = c as u32;
                let high = (val >> 4) & 0xF;
                let low = val & 0xF;
                buf.push(char::from_digit(high, 16).unwrap().to_ascii_uppercase());
                buf.push(char::from_digit(low, 16).unwrap().to_ascii_uppercase());
                requires_underscore = true;
            }
        }
        i += 1;
    }

    if requires_underscore {
        buf.push('_');
    }
}

/// Extract the module name from a file path
///
/// Given "/path/to/my_module.nim", returns "my_module"
pub fn extract_module_name(path: &Path) -> Option<String> {
    path.file_stem().and_then(|s| s.to_str()).map(|s| s.to_string())
}

/// Helper for iterating over mangled name candidates without allocations.
///
/// Generates candidates lazily by mutating an internal buffer.
/// Uses a specific mangling style (V1_6 or V2).
pub struct MangledNameIterator {
    /// Buffer containing "varName__encodedModule_u" + space for numeric suffix
    buffer: String,
    /// Position where the numeric suffix starts
    suffix_start: usize,
    current_id: usize,
    max_id: usize,
    style: NimManglingStyle,
}

impl MangledNameIterator {
    /// Create a new iterator for mangled name candidates with a specific style.
    /// Returns None if the module path is invalid.
    pub fn new(var_name: &str, module_path: &Path, max_id: usize, style: NimManglingStyle) -> Option<Self> {
        let module_name = extract_module_name(module_path)?;

        // Build the base name directly into the buffer
        // Format: "varName__encodedModule_u"
        let mut buffer = String::with_capacity(var_name.len() + module_name.len() * 2 + 10);

        // Mangle identifier directly into buffer
        mangle_nim_identifier_into(var_name, &mut buffer);
        buffer.push_str("__");
        encode_nim_module_name_into(&module_name, style, &mut buffer);
        buffer.push_str("_u");

        let suffix_start = buffer.len();

        Some(MangledNameIterator {
            buffer,
            suffix_start,
            current_id: 1,
            max_id,
            style,
        })
    }

    /// Get the next mangled name candidate, or None if we've exhausted all candidates.
    /// Returns a reference to an internal buffer - valid until next call.
    pub fn next_candidate(&mut self) -> Option<&str> {
        if self.current_id > self.max_id {
            return None;
        }

        // Truncate to base and append new suffix
        self.buffer.truncate(self.suffix_start);
        write_usize_to_string(self.current_id, &mut self.buffer);
        self.current_id += 1;

        Some(&self.buffer)
    }

    /// Get the mangling style used by this iterator
    pub fn style(&self) -> NimManglingStyle {
        self.style
    }
}

/// Write a usize to a String without allocating
fn write_usize_to_string(mut n: usize, buf: &mut String) {
    if n == 0 {
        buf.push('0');
        return;
    }

    // Find the number of digits
    let mut digits = 0;
    let mut temp = n;
    while temp > 0 {
        digits += 1;
        temp /= 10;
    }

    // Write digits in reverse order
    let start = buf.len();
    for _ in 0..digits {
        buf.push('0'); // placeholder
    }

    let bytes = unsafe { buf.as_bytes_mut() };
    let mut pos = start + digits - 1;
    while n > 0 {
        bytes[pos] = b'0' + (n % 10) as u8;
        n /= 10;
        if pos > start {
            pos -= 1;
        }
    }
}

/// A dual-style iterator that tries both Nim 1.6 and Nim 2.x mangling styles.
///
/// Starts with the preferred style (based on past successes), then falls back
/// to the alternate style. When a match is found, call `record_success()` to
/// remember the working style for future lookups.
pub struct MangledNameDualIterator {
    var_name: String,
    module_path: std::path::PathBuf,
    max_id: usize,
    primary_iter: Option<MangledNameIterator>,
    secondary_iter: Option<MangledNameIterator>,
    current_style: NimManglingStyle,
    on_secondary: bool,
}

impl MangledNameDualIterator {
    /// Create a new dual-style iterator.
    /// Returns None if the module path is invalid.
    pub fn new(var_name: &str, module_path: &Path, max_id: usize) -> Option<Self> {
        let preferred = NimManglingStyle::preferred();
        let primary_iter = MangledNameIterator::new(var_name, module_path, max_id, preferred)?;

        Some(MangledNameDualIterator {
            var_name: var_name.to_string(),
            module_path: module_path.to_path_buf(),
            max_id,
            primary_iter: Some(primary_iter),
            secondary_iter: None,
            current_style: preferred,
            on_secondary: false,
        })
    }

    /// Get the next mangled name candidate, or None if we've exhausted all candidates.
    /// Tries the preferred style first, then falls back to the alternate style.
    /// Returns a reference to an internal buffer - caller must copy if needed.
    pub fn next_candidate(&mut self) -> Option<&str> {
        // Try primary iterator first
        if let Some(ref mut iter) = self.primary_iter {
            if iter.next_candidate().is_some() {
                // Return reference to primary's buffer
                return self.primary_iter.as_ref().map(|i| i.buffer.as_str());
            }
            // Primary exhausted, switch to secondary
            self.primary_iter = None;
        }

        // Initialize secondary iterator if needed
        if self.secondary_iter.is_none() && !self.on_secondary {
            let alt_style = self.current_style.alternate();
            self.secondary_iter = MangledNameIterator::new(&self.var_name, &self.module_path, self.max_id, alt_style);
            self.current_style = alt_style;
            self.on_secondary = true;
        }

        // Try secondary iterator
        if let Some(ref mut iter) = self.secondary_iter {
            if iter.next_candidate().is_some() {
                return self.secondary_iter.as_ref().map(|i| i.buffer.as_str());
            }
        }

        None
    }

    /// Get the current mangling style being tried
    pub fn current_style(&self) -> NimManglingStyle {
        self.current_style
    }

    /// Record that the current style succeeded (optimizes future lookups)
    pub fn record_success(&self) {
        NimManglingStyle::record_success(self.current_style);
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
#[allow(clippy::panic)]
mod tests {
    use super::*;

    /// Helper to encode module name and return as String (for tests only)
    fn encode_module_name_test(name: &str, style: NimManglingStyle) -> String {
        let mut buf = String::new();
        encode_nim_module_name_into(name, style, &mut buf);
        buf
    }

    /// Helper to mangle identifier and return as String (for tests only)
    fn mangle_identifier_test(name: &str) -> String {
        let mut buf = String::new();
        mangle_nim_identifier_into(name, &mut buf);
        buf
    }

    #[test]
    fn test_rot13() {
        assert_eq!(rot13_char('a'), 'n');
        assert_eq!(rot13_char('n'), 'a');
        assert_eq!(rot13_char('z'), 'm');
        assert_eq!(rot13_char('m'), 'z');
        assert_eq!(rot13_char('A'), 'N');
        assert_eq!(rot13_char('0'), '0');
    }

    #[test]
    fn test_encode_module_name_v1_6() {
        // "nim_flow_test" should become "avz95sybj95grfg" (ROT13)
        let encoded = encode_module_name_test("nim_flow_test", NimManglingStyle::V1_6_Rot13);
        assert_eq!(encoded, "avz95sybj95grfg");

        // "local_vars" should become "ybpny95inef"
        let encoded = encode_module_name_test("local_vars", NimManglingStyle::V1_6_Rot13);
        assert_eq!(encoded, "ybpny95inef");

        // Simple name without underscore
        let encoded = encode_module_name_test("test", NimManglingStyle::V1_6_Rot13);
        assert_eq!(encoded, "grfg");
    }

    #[test]
    fn test_encode_module_name_v2() {
        // "nim_flow_test" should become "nim95flow95test" (NO ROT13)
        let encoded = encode_module_name_test("nim_flow_test", NimManglingStyle::V2_Direct);
        assert_eq!(encoded, "nim95flow95test");

        // "local_vars" should become "local95vars"
        let encoded = encode_module_name_test("local_vars", NimManglingStyle::V2_Direct);
        assert_eq!(encoded, "local95vars");

        // Simple name without underscore
        let encoded = encode_module_name_test("test", NimManglingStyle::V2_Direct);
        assert_eq!(encoded, "test");
    }

    #[test]
    fn test_encode_with_style() {
        // V1_6 style uses ROT13
        let encoded = encode_module_name_test("test", NimManglingStyle::V1_6_Rot13);
        assert_eq!(encoded, "grfg");

        // V2 style does NOT use ROT13
        let encoded = encode_module_name_test("test", NimManglingStyle::V2_Direct);
        assert_eq!(encoded, "test");
    }

    #[test]
    fn test_mangle_identifier() {
        // Simple identifier
        assert_eq!(mangle_identifier_test("intValue"), "intValue");

        // Identifier with special chars
        assert_eq!(mangle_identifier_test("foo$bar"), "foodollarbar_");

        // Leading digit
        assert_eq!(mangle_identifier_test("1test"), "X1test");
    }

    #[test]
    fn test_iterator_candidates_v1_6() {
        let path = Path::new("/tmp/nim_flow_test.nim");
        let mut iter = MangledNameIterator::new("intValue", path, 5, NimManglingStyle::V1_6_Rot13).unwrap();

        // Collect candidates (must copy since buffer is reused)
        let mut candidates = Vec::new();
        while let Some(name) = iter.next_candidate() {
            candidates.push(name.to_string());
        }

        assert_eq!(candidates.len(), 5);
        assert_eq!(candidates[0], "intValue__avz95sybj95grfg_u1");
        assert_eq!(candidates[1], "intValue__avz95sybj95grfg_u2");
    }

    #[test]
    fn test_iterator_candidates_v2() {
        let path = Path::new("/tmp/nim_flow_test.nim");
        let mut iter = MangledNameIterator::new("intValue", path, 5, NimManglingStyle::V2_Direct).unwrap();

        // Collect candidates (must copy since buffer is reused)
        let mut candidates = Vec::new();
        while let Some(name) = iter.next_candidate() {
            candidates.push(name.to_string());
        }

        assert_eq!(candidates.len(), 5);
        assert_eq!(candidates[0], "intValue__nim95flow95test_u1");
        assert_eq!(candidates[1], "intValue__nim95flow95test_u2");
    }

    #[test]
    fn test_dual_iterator() {
        let path = Path::new("/tmp/test.nim");
        let mut iter = MangledNameDualIterator::new("x", path, 2).unwrap();

        // Should get 4 candidates total (2 for preferred style, 2 for alternate)
        // Must copy strings since buffer is reused between iterations
        let mut candidates = Vec::new();
        while let Some(name) = iter.next_candidate() {
            candidates.push(name.to_string());
        }

        assert_eq!(candidates.len(), 4);
    }

    #[test]
    fn test_style_preference() {
        // Record V2 as successful
        NimManglingStyle::record_success(NimManglingStyle::V2_Direct);
        assert_eq!(NimManglingStyle::preferred(), NimManglingStyle::V2_Direct);

        // Record V1_6 as successful
        NimManglingStyle::record_success(NimManglingStyle::V1_6_Rot13);
        assert_eq!(NimManglingStyle::preferred(), NimManglingStyle::V1_6_Rot13);
    }

    #[test]
    fn test_write_usize_to_string() {
        let mut buf = String::new();
        write_usize_to_string(0, &mut buf);
        assert_eq!(buf, "0");

        buf.clear();
        write_usize_to_string(123, &mut buf);
        assert_eq!(buf, "123");

        buf.clear();
        write_usize_to_string(9999, &mut buf);
        assert_eq!(buf, "9999");
    }
}
