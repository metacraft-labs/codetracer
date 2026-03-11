use crate::types::common::ProgramEvent;
use crate::types::tracepoint::TracepointResultsAggregate;
use crate::types::values::TypeKind;

/// An expected trace output line: a label and its expected value as a string.
#[derive(Debug, Clone)]
pub struct ExpectedTrace {
    pub label: String,
    pub value: String,
}

/// Parse "TRACE:label=value" lines from stdout text.
pub fn parse_trace_output(stdout: &str) -> Vec<ExpectedTrace> {
    let mut results = Vec::new();
    for line in stdout.lines() {
        if let Some(rest) = line.strip_prefix("TRACE:") {
            if let Some((label, value)) = rest.split_once('=') {
                results.push(ExpectedTrace {
                    label: label.to_string(),
                    value: value.to_string(),
                });
            }
        }
    }
    results
}

/// Extract text content from terminal ProgramEvent records.
/// Joins all event content strings to reconstruct the terminal output.
pub fn terminal_events_to_string(events: &[ProgramEvent]) -> String {
    let mut output = String::new();
    for event in events {
        if event.stdout {
            output.push_str(&event.content);
        }
    }
    output
}

/// Compare tracepoint Stop results against expected (label, value) pairs.
///
/// For each tracepoint hit (Stop), the locals field contains StringAndValueTuple
/// entries. This function collects all values from the results and compares
/// them against the expected traces in order.
///
/// Loop tracepoints produce multiple hits — these are gathered and compared
/// sequentially.
pub fn assert_tracepoint_results_match(
    results: &TracepointResultsAggregate,
    expected: &[ExpectedTrace],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Collect all (label, value_str) pairs from results, grouped by tracepoint_id
    let mut actual_values: Vec<(usize, String, String)> = Vec::new();

    for stop in &results.results {
        for local in &stop.locals {
            let label = local.field0.clone();
            let value_str = value_to_string(&local.field1);
            actual_values.push((stop.tracepoint_id, label, value_str));
        }
    }

    // Report any tracepoint errors
    if !results.errors.is_empty() {
        eprintln!("Tracepoint errors:");
        for (id, msg) in &results.errors {
            eprintln!("  tracepoint {}: {}", id, msg);
        }
    }

    // Compare against expected
    if actual_values.len() != expected.len() {
        return Err(format!(
            "Expected {} trace values but got {}.\nExpected: {:?}\nActual: {:?}",
            expected.len(),
            actual_values.len(),
            expected.iter().map(|e| format!("{}={}", e.label, e.value)).collect::<Vec<_>>(),
            actual_values.iter().map(|(id, l, v)| format!("[tp{}] {}={}", id, l, v)).collect::<Vec<_>>(),
        ).into());
    }

    for (i, (expected_trace, (_tp_id, actual_label, actual_value))) in
        expected.iter().zip(actual_values.iter()).enumerate()
    {
        if expected_trace.value != *actual_value {
            return Err(format!(
                "Mismatch at index {}: expected {}={} but got {}={}",
                i, expected_trace.label, expected_trace.value, actual_label, actual_value,
            ).into());
        }
    }

    Ok(())
}

/// Convert a Value to its string representation for comparison.
fn value_to_string(value: &crate::types::values::Value) -> String {
    match value.kind {
        TypeKind::Int => value.i.clone(),
        TypeKind::Float => value.f.clone(),
        TypeKind::String => value.text.clone(),
        TypeKind::CString => value.c_text.clone(),
        TypeKind::Char => value.c.clone(),
        TypeKind::Bool => if value.b { "true" } else { "false" }.to_string(),
        TypeKind::Raw => value.r.clone(),
        TypeKind::Error => format!("<error: {}>", value.msg),
        TypeKind::None => "nil".to_string(),
        _ => value.text_repr(),
    }
}
