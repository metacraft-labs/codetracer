//! Rust renderers for the canonical `OriginChain` wire shape (spec §4.1).
//!
//! The renderers convert a `serde_json::Value` payload — the body of a
//! `ct/originChain` DAP response — into either:
//!
//! - [`render_text`] — the ASCII chain layout from spec §3.2.2
//!   (newest-hop first, terminator at the bottom).
//! - [`render_markdown`] — a GitHub-issue-friendly markdown report.
//!
//! Both renderers are pure functions and operate off the wire JSON
//! directly, so this crate does not have to take a build-time dependency
//! on `db-backend`. The output must match the Python twins
//! (`python-api/codetracer/origin.py::_render_text` /
//! `_render_markdown`) up to whitespace — the M8 acceptance tests
//! compare them line by line.
//!
//! The `OriginChain` wire shape (spec §4.1) is documented in
//! `src/db-backend/src/task.rs`. Quick refresher of the camelCase fields
//! consumed here:
//!
//! - `queryVariable: string`
//! - `queryStepId: i64`
//! - `hops: OriginHop[]` — `{ kind, targetExpr, sourceExpr, location:
//!   { path, line, column }, sourceText, stepId, frameTransition?,
//!   operandSnapshots?, truncatedOperands, confidence }`
//! - `terminator: { kind, expression, function?, sourceLine? }`
//! - `truncated: bool`
//! - `continuationToken?: string`
//! - `metrics?: { stepsScanned, elapsedMs, classifierHits }`

use std::fmt::Write;

use serde_json::Value;

/// Render the chain in the ASCII layout from spec §3.2.2.
///
/// Output shape (matches `OriginChain.to_text()` on the Python side):
///
/// ```text
/// Origin chain for 'c' @ step=42
///   hops=3 terminator=literal truncated=no
///
///   0. [=] main.py:11
///      c = b
///   1. [=] main.py:10
///      b = a
///   2. [L] main.py:9
///      a = 10
///   [lit] 10
/// ```
pub fn render_text(chain: &Value) -> String {
    let mut out = String::new();
    let query_variable = chain
        .get("queryVariable")
        .and_then(Value::as_str)
        .unwrap_or("");
    let query_step_id = chain
        .get("queryStepId")
        .and_then(Value::as_i64)
        .unwrap_or(0);

    let hops = chain
        .get("hops")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let terminator = chain.get("terminator").cloned().unwrap_or(Value::Null);
    let terminator_kind = terminator
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or("unknownSource");
    let truncated = chain
        .get("truncated")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    let _ = writeln!(
        out,
        "Origin chain for '{query_variable}' @ step={query_step_id}"
    );
    let _ = writeln!(
        out,
        "  hops={} terminator={} truncated={}",
        hops.len(),
        terminator_kind,
        if truncated { "yes" } else { "no" }
    );
    let _ = writeln!(out);

    for (idx, hop) in hops.iter().enumerate() {
        let kind = hop.get("kind").and_then(Value::as_str).unwrap_or("unknown");
        let glyph = origin_glyph(kind);
        let location = format_location(hop.get("location"));
        let frame_suffix = format_frame_transition(hop.get("frameTransition"));
        let _ = writeln!(out, "  {idx}. [{glyph}] {location}{frame_suffix}");

        let source_text = hop
            .get("sourceText")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| {
                let target = hop.get("targetExpr").and_then(Value::as_str).unwrap_or("");
                let source = hop.get("sourceExpr").and_then(Value::as_str).unwrap_or("");
                format!("{target} = {source}")
            });
        let _ = writeln!(out, "     {source_text}");

        if kind == "computational"
            && let Some(snapshots) = hop.get("operandSnapshots").and_then(Value::as_array)
        {
            for snap in snapshots {
                let name = snap.get("name").and_then(Value::as_str).unwrap_or("");
                let value = render_value_record(snap.get("value"));
                let _ = writeln!(out, "       - {name} = {value}");
            }
            let truncated_operands = hop
                .get("truncatedOperands")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            if truncated_operands {
                out.push_str("       - (more operands hidden)\n");
            }
        }
    }

    let term_glyph = terminator_glyph(terminator_kind);
    let terminator_expr = terminator
        .get("expression")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| terminator_kind.to_string());
    let _ = writeln!(out, "  {term_glyph} {terminator_expr}");

    if let Some(function) = terminator
        .get("function")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    {
        let _ = writeln!(out, "      @ {function}");
    }

    // Trim trailing newline so callers can `println!("{}", render_text(chain))`
    // without an extra blank line.
    if out.ends_with('\n') {
        out.pop();
    }
    out
}

/// Render the chain as a GitHub-issue-friendly markdown report.
pub fn render_markdown(chain: &Value) -> String {
    let mut out = String::new();
    let query_variable = chain
        .get("queryVariable")
        .and_then(Value::as_str)
        .unwrap_or("");
    let query_step_id = chain
        .get("queryStepId")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let terminator = chain.get("terminator").cloned().unwrap_or(Value::Null);
    let terminator_kind = terminator
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or("unknownSource");
    let terminator_expr = terminator
        .get("expression")
        .and_then(Value::as_str)
        .unwrap_or("");
    let terminator_function = terminator
        .get("function")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty());
    let truncated = chain
        .get("truncated")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let continuation_token = chain
        .get("continuationToken")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty());
    let hops = chain
        .get("hops")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    let _ = writeln!(
        out,
        "### Origin chain — `{query_variable}` @ step `{query_step_id}`"
    );
    let _ = writeln!(out);
    let _ = writeln!(
        out,
        "- **Terminator:** `{terminator_kind}` — `{terminator_expr}`"
    );
    if let Some(function) = terminator_function {
        let _ = writeln!(out, "- **Terminator function:** `{function}`");
    }
    let _ = writeln!(out, "- **Hops:** {}", hops.len());
    let _ = writeln!(
        out,
        "- **Truncated:** {}",
        if truncated { "yes" } else { "no" }
    );
    if let Some(token) = continuation_token {
        let _ = writeln!(out, "- **Continuation token:** `{token}`");
    }
    let _ = writeln!(out);

    if !hops.is_empty() {
        let _ = writeln!(out, "| # | Kind | Location | Source | Confidence |");
        let _ = writeln!(out, "| - | ---- | -------- | ------ | ---------- |");
        for (idx, hop) in hops.iter().enumerate() {
            let kind = hop.get("kind").and_then(Value::as_str).unwrap_or("unknown");
            let location = format_location(hop.get("location")).replace('|', "\\|");
            let source_text = hop
                .get("sourceText")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| {
                    let target = hop.get("targetExpr").and_then(Value::as_str).unwrap_or("");
                    let source = hop.get("sourceExpr").and_then(Value::as_str).unwrap_or("");
                    format!("{target} = {source}")
                })
                .replace('|', "\\|");
            let confidence = hop.get("confidence").and_then(Value::as_f64).unwrap_or(0.0);
            let _ = writeln!(
                out,
                "| {idx} | `{kind}` | `{location}` | `{source_text}` | {confidence:.2} |"
            );
        }
    }

    // Operand snapshots — one section per Computational hop.
    let computational: Vec<(usize, &Value)> = hops
        .iter()
        .enumerate()
        .filter(|(_, hop)| {
            hop.get("kind").and_then(Value::as_str) == Some("computational")
                && hop
                    .get("operandSnapshots")
                    .and_then(Value::as_array)
                    .is_some_and(|a| !a.is_empty())
        })
        .collect();
    if !computational.is_empty() {
        let _ = writeln!(out);
        let _ = writeln!(out, "#### Operand snapshots");
        for (idx, hop) in computational {
            let _ = writeln!(out);
            let header = hop
                .get("sourceText")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| hop.get("sourceExpr").and_then(Value::as_str).unwrap_or(""));
            let _ = writeln!(out, "Hop {idx} — `{header}`:");
            if let Some(snapshots) = hop.get("operandSnapshots").and_then(Value::as_array) {
                for snap in snapshots {
                    let name = snap.get("name").and_then(Value::as_str).unwrap_or("");
                    let value = render_value_record(snap.get("value"));
                    let source_step = snap.get("sourceStep").and_then(Value::as_i64).unwrap_or(0);
                    let _ = writeln!(out, "- `{name}` = `{value}` (step {source_step})");
                }
                let truncated_operands = hop
                    .get("truncatedOperands")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                if truncated_operands {
                    out.push_str("- *(more operands hidden)*\n");
                }
            }
        }
    }

    if out.ends_with('\n') {
        out.pop();
    }
    out
}

/// Glyph table for `OriginKind` — mirrors `origin.py::_ORIGIN_GLYPHS`.
///
/// Plain-ASCII only so the renderers stay friendly to copy-paste into
/// GitHub issues and chat surfaces. The Python and Rust tables must
/// remain in lock-step.
fn origin_glyph(kind: &str) -> &'static str {
    match kind {
        "trivialCopy" => "=",
        "fieldAccess" => ".",
        "indexAccess" => "[]",
        "computational" => "*",
        "functionCall" => "()",
        "literal" => "L",
        "returnCapture" => "<-",
        "functionReturn" => "<<",
        "parameterPass" => "->",
        "crossThreadCopy" => "~",
        _ => "?",
    }
}

fn terminator_glyph(kind: &str) -> &'static str {
    match kind {
        "computational" => "(o)",
        "literal" => "[lit]",
        "parameterAtRecordStart" => "[param]",
        "readFromExternal" => "[io]",
        "recordingStart" => "[start]",
        "unknownSource" => "[?src]",
        "unknownVariable" => "[?var]",
        "depthLimit" => "[depth]",
        "outOfBudget" => "[budget]",
        _ => "[?]",
    }
}

fn format_location(location: Option<&Value>) -> String {
    let path = location
        .and_then(|l| l.get("path"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let line = location
        .and_then(|l| l.get("line"))
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let base = basename(path);
    if base.is_empty() {
        format!("<unknown>:{line}")
    } else {
        format!("{base}:{line}")
    }
}

fn format_frame_transition(transition: Option<&Value>) -> String {
    let Some(ft) = transition else {
        return String::new();
    };
    if ft.is_null() {
        return String::new();
    }
    let kind = ft.get("kind").and_then(Value::as_str).unwrap_or("");
    let arrow = match kind {
        "parameterPass" => "[>]",
        "returnCapture" => "[<]",
        _ => "[?]",
    };
    let from = ft.get("fromFunction").and_then(Value::as_str).unwrap_or("");
    let to = ft.get("toFunction").and_then(Value::as_str).unwrap_or("");
    format!("  {arrow} {from} -> {to}")
}

/// Resolve a `ValueRecordWithType` JSON envelope to a printable string.
/// Mirrors `python_bridge::extract_value_str` and Python's
/// `_render_value_record`. The three must remain identical for the
/// operand rendering to agree across surfaces.
fn render_value_record(value: Option<&Value>) -> String {
    let Some(v) = value else {
        return String::new();
    };
    if let Some(s) = v.as_str() {
        return s.to_string();
    }
    if !v.is_object() {
        return v.to_string();
    }
    let kind = v.get("kind").and_then(Value::as_u64);
    match kind {
        Some(7) => str_field(v, "i"),
        Some(8) => str_field(v, "f"),
        Some(9) => str_field(v, "text"),
        Some(10) => str_field(v, "cText"),
        Some(11) => str_field(v, "c"),
        Some(12) => match v.get("b").and_then(Value::as_bool) {
            Some(true) => "true".to_string(),
            _ => "false".to_string(),
        },
        Some(16) => str_field(v, "r"),
        _ => {
            for field in ["i", "f", "text", "r"] {
                let s = str_field(v, field);
                if !s.is_empty() {
                    return s;
                }
            }
            serde_json::to_string(v).unwrap_or_default()
        }
    }
}

fn str_field(value: &Value, field: &str) -> String {
    value
        .get(field)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

fn basename(path: &str) -> String {
    if path.is_empty() {
        return String::new();
    }
    // POSIX-style and Windows-style separators are both handled
    // (CodeTracer traces normalise paths but tests pass raw strings).
    let after_unix = path.rsplit('/').next().unwrap_or(path);
    let after_win = after_unix.rsplit('\\').next().unwrap_or(after_unix);
    after_win.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Fixture mirroring the Python canonical `simple_trivial_chain`
    /// fixture (`c = b`, `b = a`, `a = 10`).
    fn simple_chain() -> Value {
        json!({
            "queryVariable": "c",
            "queryStepId": 42,
            "hops": [
                {
                    "kind": "trivialCopy",
                    "targetExpr": "c",
                    "sourceExpr": "b",
                    "sourceVariable": "b",
                    "location": {"path": "main.py", "line": 11, "column": 0},
                    "sourceText": "c = b",
                    "stepId": 42,
                    "frameTransition": null,
                    "operandSnapshots": [],
                    "truncatedOperands": false,
                    "confidence": 0.9,
                },
                {
                    "kind": "trivialCopy",
                    "targetExpr": "b",
                    "sourceExpr": "a",
                    "sourceVariable": "a",
                    "location": {"path": "main.py", "line": 10, "column": 0},
                    "sourceText": "b = a",
                    "stepId": 41,
                    "frameTransition": null,
                    "operandSnapshots": [],
                    "truncatedOperands": false,
                    "confidence": 0.9,
                },
                {
                    "kind": "literal",
                    "targetExpr": "a",
                    "sourceExpr": "10",
                    "sourceVariable": null,
                    "location": {"path": "main.py", "line": 9, "column": 0},
                    "sourceText": "a = 10",
                    "stepId": 40,
                    "frameTransition": null,
                    "operandSnapshots": [],
                    "truncatedOperands": false,
                    "confidence": 0.95,
                },
            ],
            "terminator": {"kind": "literal", "expression": "10", "function": "main"},
            "truncated": false,
            "confidence": 0.9,
        })
    }

    #[test]
    fn text_renderer_emits_spec_layout() {
        let chain = simple_chain();
        let rendered = render_text(&chain);
        // The header line carries the queried variable.
        assert!(rendered.contains("Origin chain for 'c' @ step=42"));
        // Hops are listed newest-first.
        assert!(rendered.contains("0. [=] main.py:11"));
        assert!(rendered.contains("2. [L] main.py:9"));
        // The terminator row uses the Literal glyph.
        assert!(rendered.contains("[lit] 10"));
        // The function name is annotated below the terminator.
        assert!(rendered.contains("@ main"));
    }

    #[test]
    fn markdown_renderer_contains_table_header() {
        let chain = simple_chain();
        let rendered = render_markdown(&chain);
        assert!(rendered.contains("### Origin chain — `c` @ step `42`"));
        assert!(rendered.contains("| # | Kind | Location | Source | Confidence |"));
        // Every hop ends up as a row.
        assert!(rendered.contains("| 0 | `trivialCopy` | `main.py:11`"));
        assert!(rendered.contains("| 2 | `literal` | `main.py:9`"));
        // Terminator metadata.
        assert!(rendered.contains("**Terminator:** `literal` — `10`"));
    }

    #[test]
    fn markdown_renderer_emits_operand_section_for_computational() {
        let chain = json!({
            "queryVariable": "result",
            "queryStepId": 7,
            "hops": [
                {
                    "kind": "computational",
                    "targetExpr": "result",
                    "sourceExpr": "a + b",
                    "sourceVariable": null,
                    "location": {"path": "main.py", "line": 4, "column": 0},
                    "sourceText": "result = a + b",
                    "stepId": 7,
                    "frameTransition": null,
                    "operandSnapshots": [
                        {"name": "a", "value": {"kind": 7, "i": "3"}, "sourceStep": 5},
                        {"name": "b", "value": {"kind": 7, "i": "4"}, "sourceStep": 6},
                    ],
                    "truncatedOperands": false,
                    "confidence": 0.9,
                }
            ],
            "terminator": {"kind": "computational", "expression": "a + b"},
            "truncated": false,
            "confidence": 0.9,
        });
        let rendered = render_markdown(&chain);
        assert!(rendered.contains("#### Operand snapshots"));
        // Operand rows surface the Int payload via `i`.
        assert!(rendered.contains("`a` = `3`"));
        assert!(rendered.contains("`b` = `4`"));
    }

    #[test]
    fn text_renderer_handles_frame_transition() {
        let chain = json!({
            "queryVariable": "local",
            "queryStepId": 12,
            "hops": [
                {
                    "kind": "parameterPass",
                    "targetExpr": "local",
                    "sourceExpr": "outer",
                    "sourceVariable": "outer",
                    "location": {"path": "main.py", "line": 6, "column": 0},
                    "sourceText": "receive(outer)",
                    "stepId": 12,
                    "frameTransition": {
                        "kind": "parameterPass",
                        "fromFunction": "main",
                        "toFunction": "receive",
                        "callKey": 1,
                    },
                    "operandSnapshots": [],
                    "truncatedOperands": false,
                    "confidence": 0.9,
                }
            ],
            "terminator": {"kind": "literal", "expression": "0"},
            "truncated": false,
            "confidence": 0.9,
        });
        let rendered = render_text(&chain);
        assert!(rendered.contains("[>] main -> receive"));
    }
}
