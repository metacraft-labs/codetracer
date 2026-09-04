//! Evaluating a user-entered watch expression against a recorded step.
//!
//! # Why this module exists at all
//!
//! `CtLoadLocalsArguments` has carried a `watch_expressions: Vec<String>`
//! field for as long as the State pane has existed, and the frontend has
//! always populated it. Nothing on the backend ever read it. `db.rs` held
//! this, verbatim:
//!
//! ```text
//! // TODO: watches require tracepoint-like evaluate_expression or would duplicate locals
//! // for now don't evaluate/support them for db traces: just ignoring
//! if !arg.watch_expressions.is_empty() {
//!     warn!("watch expressions not supported for db traces currently");
//! }
//! ```
//!
//! So a user typed an expression, the request carried it, and the response
//! came back with no row for it and no reason — the pane's two states were
//! "a local" and "nothing".
//!
//! # Why NOT the tracepoint interpreter the TODO points at
//!
//! `tracepoint_interpreter` is a real expression evaluator, and it is the
//! obvious answer until you check which builds have it. It is gated behind
//! the `syntax-highlight` feature because it compiles expressions with
//! tree-sitter, and `src/db-backend/build_wasm.sh` builds the browser
//! engine with `--no-default-features --features browser-transport`. In
//! that build `TracepointInterpreter::evaluate` is the stub in
//! `tracepoint_interpreter/mod.rs` that returns `vec![]`.
//!
//! Routing watches through it would therefore have shipped a feature that
//! works on the desktop and silently answers nothing in the browser —
//! which is the exact failure mode being fixed, reintroduced one layer
//! down. This module deliberately depends on nothing but the trace's own
//! value records, so the same code answers in both builds.
//!
//! # What it evaluates, and what it refuses
//!
//! A recorded trace is not a live process. There is no frame to call into,
//! no allocator, no way to run arithmetic the recorder did not record. So
//! the honest surface is *navigation of recorded values*:
//!
//! * `total`        — a recorded name at this step
//! * `p.x`          — a field of a recorded struct
//! * `xs[2]`        — an element of a recorded sequence or tuple
//! * `board[1].row` — any chain of the two
//!
//! Everything else is REFUSED WITH A STATED REASON rather than answered
//! wrongly or dropped. `x + y` is refused because the sum was never
//! recorded and inventing it would be a debugger lying about a recording.
//! The reason travels to the pane as a `ValueRecord::Error`, which both
//! sides of the wire already understand (`text_representation.nim` renders
//! an `Error` value as its `msg`), so a refusal is a visible row and never
//! an empty pane.

use codetracer_trace_types::{TypeKind, TypeSpecificInfo};

use crate::value::{Type, ValueRecordWithType};

/// One navigation step away from the base name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WatchSegment {
    /// `.name` — a named field of a struct.
    Field(String),
    /// `[n]` — a positional element of a sequence, tuple or struct.
    Index(usize),
}

/// A parsed watch expression: a recorded name plus a navigation chain.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WatchPath {
    /// The recorded variable name the walk starts from.
    pub base: String,
    /// Zero or more field / index hops applied left to right.
    pub segments: Vec<WatchSegment>,
}

/// Why an expression could not be turned into a [`WatchPath`], or could not
/// be resolved against the step.
///
/// Kept as a plain `String` at the boundary because it is user-facing text
/// that ends up rendered in the pane; the constructors below are what keep
/// the wording consistent.
pub type WatchRefusal = String;

/// True for a byte that may start an identifier in any language we replay.
fn is_ident_start(c: char) -> bool {
    c.is_alphabetic() || c == '_'
}

/// True for a byte that may continue an identifier.
fn is_ident_continue(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Parse a user-entered expression into a base name and a navigation chain.
///
/// Returns a refusal — never a panic and never a silent empty result — for
/// anything outside the grammar documented at module level. The refusals
/// name the expression so a pane showing several watches stays legible.
pub fn parse_watch_expression(expression: &str) -> Result<WatchPath, WatchRefusal> {
    let trimmed = expression.trim();
    if trimmed.is_empty() {
        return Err("an empty watch expression has nothing to evaluate".to_string());
    }

    let chars: Vec<char> = trimmed.chars().collect();
    let mut at = 0usize;

    // ---- the base name -------------------------------------------------
    if !is_ident_start(chars[at]) {
        return Err(format!(
            "cannot evaluate `{trimmed}`: a watch expression has to start with a recorded variable name"
        ));
    }
    let start = at;
    while at < chars.len() && is_ident_continue(chars[at]) {
        at += 1;
    }
    let base: String = chars[start..at].iter().collect();

    // ---- the navigation chain ------------------------------------------
    let mut segments = Vec::new();
    while at < chars.len() {
        // SKIP INTERIOR WHITESPACE BEFORE DECIDING, so the refusal blames
        // the operator and not the space in front of it. Measured: `x + 1`
        // reported "` ` would have to be computed", which names a character
        // the user does not think of as the problem and reads like a bug in
        // the parser rather than a statement about the recording.
        if chars[at].is_whitespace() {
            at += 1;
            continue;
        }
        match chars[at] {
            '.' => {
                at += 1;
                if at >= chars.len() || !is_ident_start(chars[at]) {
                    return Err(format!(
                        "cannot evaluate `{trimmed}`: `.` is not followed by a field name"
                    ));
                }
                let field_start = at;
                while at < chars.len() && is_ident_continue(chars[at]) {
                    at += 1;
                }
                segments.push(WatchSegment::Field(chars[field_start..at].iter().collect()));
            }
            '[' => {
                at += 1;
                let index_start = at;
                while at < chars.len() && chars[at].is_ascii_digit() {
                    at += 1;
                }
                if index_start == at {
                    return Err(format!(
                        "cannot evaluate `{trimmed}`: `[` is not followed by a whole-number index. \
                         Only literal indices can be resolved against a recording"
                    ));
                }
                let digits: String = chars[index_start..at].iter().collect();
                let index: usize = digits.parse().map_err(|_| {
                    format!("cannot evaluate `{trimmed}`: `{digits}` is not an index this trace can address")
                })?;
                if at >= chars.len() || chars[at] != ']' {
                    return Err(format!(
                        "cannot evaluate `{trimmed}`: an index is opened with `[` and never closed"
                    ));
                }
                at += 1;
                segments.push(WatchSegment::Index(index));
            }
            other => {
                // THE REFUSAL THAT MATTERS MOST, and the reason it is worded
                // this way. Arithmetic and calls are what users try first,
                // and "unsupported" alone reads as a missing feature rather
                // than as a property of replaying a recording. Say which
                // character stopped us and what CAN be asked.
                return Err(format!(
                    "cannot evaluate `{trimmed}`: `{other}` would have to be computed, and a recording \
                     only holds the values that were actually recorded. Watch a recorded name (`total`), \
                     a field (`p.x`) or an element (`xs[0]`)"
                ));
            }
        }
    }

    Ok(WatchPath { base, segments })
}

/// The field names of a struct type, in `field_values` order.
///
/// Returns an empty slice for any other type, which the caller reports as
/// "this value has no fields" rather than treating as an absent name.
fn struct_field_names(typ: &codetracer_trace_types::TypeRecord) -> &[codetracer_trace_types::FieldTypeRecord] {
    match &typ.specific_info {
        TypeSpecificInfo::Struct { fields } => fields,
        _ => &[],
    }
}

/// A short human name for a value's shape, used only in refusal text.
fn shape_of(value: &ValueRecordWithType) -> &'static str {
    match value {
        ValueRecordWithType::Int { .. } => "an integer",
        ValueRecordWithType::Float { .. } => "a float",
        ValueRecordWithType::Bool { .. } => "a boolean",
        ValueRecordWithType::String { .. } => "a string",
        ValueRecordWithType::Sequence { .. } => "a sequence",
        ValueRecordWithType::Tuple { .. } => "a tuple",
        ValueRecordWithType::Struct { .. } => "a struct",
        ValueRecordWithType::Variant { .. } => "a variant",
        ValueRecordWithType::Reference { .. } => "a reference",
        ValueRecordWithType::Raw { .. } => "a raw value",
        ValueRecordWithType::Error { .. } => "an error",
        ValueRecordWithType::None { .. } => "none",
        _ => "a value",
    }
}

/// Follow one segment into `value`.
fn step_into<'a>(
    value: &'a ValueRecordWithType,
    segment: &WatchSegment,
    expression: &str,
) -> Result<&'a ValueRecordWithType, WatchRefusal> {
    // A reference is followed transparently: a user watching `p.x` on a
    // `&Point` means the pointee's field, and refusing there would be a
    // technicality rather than a limit of the recording.
    if let ValueRecordWithType::Reference { dereferenced, .. } = value {
        return step_into(dereferenced, segment, expression);
    }

    match segment {
        WatchSegment::Field(name) => match value {
            ValueRecordWithType::Struct { field_values, typ } => {
                let fields = struct_field_names(typ);
                let position = fields.iter().position(|f| &f.name == name);
                match position {
                    Some(index) => field_values.get(index).ok_or_else(|| {
                        format!(
                            "cannot evaluate `{expression}`: the recording declares a field `{name}` \
                             whose value was not recorded at this step"
                        )
                    }),
                    None => {
                        let known: Vec<&str> = fields.iter().map(|f| f.name.as_str()).collect();
                        if known.is_empty() {
                            Err(format!(
                                "cannot evaluate `{expression}`: this value records no field names, \
                                 so `{name}` cannot be resolved — try a positional index like `[0]`"
                            ))
                        } else {
                            Err(format!(
                                "cannot evaluate `{expression}`: there is no field `{name}` here; \
                                 this value has {}",
                                known.join(", ")
                            ))
                        }
                    }
                }
            }
            other => Err(format!(
                "cannot evaluate `{expression}`: `.{name}` asks for a field of {}, which has none",
                shape_of(other)
            )),
        },
        WatchSegment::Index(index) => {
            let elements = match value {
                ValueRecordWithType::Sequence { elements, .. } => elements,
                ValueRecordWithType::Tuple { elements, .. } => elements,
                ValueRecordWithType::Struct { field_values, .. } => field_values,
                other => {
                    return Err(format!(
                        "cannot evaluate `{expression}`: `[{index}]` asks for an element of {}, \
                         which is not indexable",
                        shape_of(other)
                    ));
                }
            };
            elements.get(*index).ok_or_else(|| {
                format!(
                    "cannot evaluate `{expression}`: index {index} is past the end — \
                     {} element(s) were recorded here",
                    elements.len()
                )
            })
        }
    }
}

/// Walk a parsed path from an already-resolved base value.
pub fn navigate<'a>(
    root: &'a ValueRecordWithType,
    path: &WatchPath,
    expression: &str,
) -> Result<&'a ValueRecordWithType, WatchRefusal> {
    let mut current = root;
    for segment in &path.segments {
        current = step_into(current, segment, expression)?;
    }
    Ok(current)
}

/// Build the value a refused watch is rendered as.
///
/// `ValueRecord::Error` is used deliberately instead of a new wire field:
/// the Nim `Value` already has an `Error` kind whose text representation is
/// its `msg` (`common_types/utils/text_representation.nim`), so a refusal
/// arrives as a visible row on every existing frontend without any of them
/// being taught a new case. A watch that cannot be answered therefore shows
/// its reason; it never shows an empty row and never vanishes.
pub fn refusal_value(reason: &str) -> ValueRecordWithType {
    ValueRecordWithType::Error {
        msg: reason.to_string(),
        typ: codetracer_trace_types::TypeRecord {
            kind: codetracer_trace_types::TypeKind::Error,
            lang_type: "watch error".to_string(),
            specific_info: TypeSpecificInfo::None,
        },
    }
}

/// The `Type` a refusal carries once converted for the wire.
///
/// Exposed so the conversion in `db.rs` and the tests agree on one spelling.
pub fn refusal_type() -> Type {
    Type::new(TypeKind::Error, "watch error")
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use codetracer_trace_types::{FieldTypeRecord, TypeId, TypeRecord};

    fn int_type() -> TypeRecord {
        TypeRecord {
            kind: codetracer_trace_types::TypeKind::Int,
            lang_type: "int".to_string(),
            specific_info: TypeSpecificInfo::None,
        }
    }

    fn int(i: i64) -> ValueRecordWithType {
        ValueRecordWithType::Int { i, typ: int_type() }
    }

    /// `ValueRecordWithType` does not derive `PartialEq`, and the tests
    /// below care about ONE thing: which recorded integer the walk landed
    /// on. Asserting on that number is also stricter than a whole-value
    /// comparison would be here — a walk that stopped one hop early would
    /// yield a struct, and this panics naming what it found instead.
    fn as_int(value: &ValueRecordWithType) -> i64 {
        match value {
            ValueRecordWithType::Int { i, .. } => *i,
            other => panic!("expected the walk to land on an Int, got {other:?}"),
        }
    }

    fn point(x: i64, y: i64) -> ValueRecordWithType {
        ValueRecordWithType::Struct {
            field_values: vec![int(x), int(y)],
            typ: TypeRecord {
                kind: codetracer_trace_types::TypeKind::Struct,
                lang_type: "Point".to_string(),
                specific_info: TypeSpecificInfo::Struct {
                    fields: vec![
                        FieldTypeRecord {
                            name: "x".to_string(),
                            type_id: TypeId(0),
                        },
                        FieldTypeRecord {
                            name: "y".to_string(),
                            type_id: TypeId(0),
                        },
                    ],
                },
            },
        }
    }

    #[test]
    fn parses_a_bare_name() {
        let path = parse_watch_expression("total").expect("bare name parses");
        assert_eq!(path.base, "total");
        assert!(path.segments.is_empty());
    }

    #[test]
    fn parses_a_field_and_index_chain() {
        let path = parse_watch_expression("board[1].row[2]").expect("chain parses");
        assert_eq!(path.base, "board");
        assert_eq!(
            path.segments,
            vec![
                WatchSegment::Index(1),
                WatchSegment::Field("row".to_string()),
                WatchSegment::Index(2),
            ]
        );
    }

    #[test]
    fn whitespace_around_the_expression_is_not_a_refusal() {
        assert_eq!(parse_watch_expression("  total  ").expect("trimmed").base, "total");
    }

    /// THE REFUSAL PATH, asserted on its TEXT and not merely on being an
    /// `Err`. A refusal whose message is empty is the same empty pane this
    /// module exists to remove.
    #[test]
    fn arithmetic_is_refused_and_says_why() {
        let refusal = parse_watch_expression("x + y").expect_err("arithmetic is refused");
        assert!(refusal.contains("x + y"), "the refusal names the expression: {refusal}");
        assert!(
            refusal.contains("only holds the values that were actually recorded"),
            "the refusal says why a recording cannot answer it: {refusal}"
        );
    }

    /// The refusal must blame the OPERATOR, not the space before it.
    #[test]
    fn a_spaced_operator_is_named_in_the_refusal() {
        let refusal = parse_watch_expression("shield + 1").expect_err("refused");
        assert!(refusal.contains("`+` would have to be computed"), "{refusal}");
    }

    #[test]
    fn an_empty_expression_is_refused() {
        assert!(parse_watch_expression("   ").is_err());
    }

    #[test]
    fn an_unclosed_index_is_refused() {
        let refusal = parse_watch_expression("xs[0").expect_err("unclosed index is refused");
        assert!(refusal.contains("never closed"), "{refusal}");
    }

    #[test]
    fn a_non_literal_index_is_refused() {
        let refusal = parse_watch_expression("xs[i]").expect_err("computed index is refused");
        assert!(refusal.contains("whole-number index"), "{refusal}");
    }

    #[test]
    fn navigates_to_a_struct_field() {
        let path = parse_watch_expression("p.y").expect("parses");
        let value = point(3, 7);
        let found = navigate(&value, &path, "p.y").expect("resolves");
        assert_eq!(as_int(found), 7);
    }

    #[test]
    fn navigates_through_a_sequence_into_a_struct() {
        let path = parse_watch_expression("ps[1].x").expect("parses");
        let value = ValueRecordWithType::Sequence {
            elements: vec![point(1, 2), point(30, 40)],
            is_slice: false,
            typ: int_type(),
        };
        let found = navigate(&value, &path, "ps[1].x").expect("resolves");
        assert_eq!(as_int(found), 30);
    }

    #[test]
    fn a_reference_is_followed_transparently() {
        let path = parse_watch_expression("p.x").expect("parses");
        let value = ValueRecordWithType::Reference {
            dereferenced: Box::new(point(9, 9)),
            address: 0,
            mutable: false,
            typ: int_type(),
        };
        assert_eq!(as_int(navigate(&value, &path, "p.x").expect("resolves")), 9);
    }

    /// An index past the end must say HOW MANY were recorded — "not found"
    /// alone cannot be told apart from "the name is wrong".
    #[test]
    fn an_out_of_range_index_reports_the_recorded_length() {
        let path = parse_watch_expression("xs[5]").expect("parses");
        let value = ValueRecordWithType::Sequence {
            elements: vec![int(1), int(2)],
            is_slice: false,
            typ: int_type(),
        };
        let refusal = navigate(&value, &path, "xs[5]").expect_err("refused");
        assert!(refusal.contains("past the end"), "{refusal}");
        assert!(refusal.contains("2 element(s)"), "{refusal}");
    }

    /// An unknown field must list the fields that DO exist. This is the
    /// difference between a pane that says "no" and one that helps.
    #[test]
    fn an_unknown_field_lists_the_known_ones() {
        let path = parse_watch_expression("p.z").expect("parses");
        let refusal = navigate(&point(1, 2), &path, "p.z").expect_err("refused");
        assert!(refusal.contains("no field `z`"), "{refusal}");
        assert!(refusal.contains("x, y"), "{refusal}");
    }

    #[test]
    fn indexing_a_scalar_is_refused_by_shape() {
        let path = parse_watch_expression("n[0]").expect("parses");
        let refusal = navigate(&int(4), &path, "n[0]").expect_err("refused");
        assert!(refusal.contains("an integer"), "{refusal}");
        assert!(refusal.contains("not indexable"), "{refusal}");
    }

    /// The refusal must survive the trip to the pane as a value the
    /// frontend already renders, carrying its own text.
    #[test]
    fn a_refusal_becomes_an_error_value_carrying_the_reason() {
        let value = refusal_value("because the recording says so");
        match value {
            ValueRecordWithType::Error { msg, typ } => {
                assert_eq!(msg, "because the recording says so");
                assert_eq!(typ.kind, codetracer_trace_types::TypeKind::Error);
            }
            other => panic!("a refusal must be an Error value, got {other:?}"),
        }
    }
}
