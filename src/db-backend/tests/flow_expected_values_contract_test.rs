//! Fault controls for the actual shared flow-value oracle and serialized schema.
//! Constructed missing/corrupt responses deliberately exercise this boundary;
//! they are not mock recorders/compilers and do not replace real language flows.
mod test_harness;
use codetracer_trace_types::TypeKind;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use test_harness::{ExpectedFlowValues, FlowData, FlowTestConfig, Language, verify_flow_results};

fn check(value: Option<Value>, expected: ExpectedFlowValues) -> Result<(), String> {
    let config = FlowTestConfig {
        source_path: PathBuf::from("actual-oracle-boundary.sh"),
        language: Language::Bash,
        breakpoint_line: 1,
        expected_variables: vec!["a".into()],
        excluded_identifiers: vec![],
        expected_values: expected,
    };
    let flow = FlowData {
        steps: vec![],
        all_variables: vec!["a".into()],
        values: value.map(|v| HashMap::from([("a".into(), v)])).unwrap_or_default(),
    };
    verify_flow_results(&config, &flow)
}
fn integer() -> ExpectedFlowValues {
    HashMap::from([("a".into(), 10_i64)]).into()
}
fn string() -> ExpectedFlowValues {
    HashMap::from([("a".into(), "10".to_string())]).into()
}
fn value(kind: TypeKind, i: &str, text: &str, r: &str) -> Value {
    json!({"kind":kind,"i":i,"text":text,"r":r})
}
#[test]
fn exact_modern_integer_and_legacy_raw_are_checked() {
    assert!(check(Some(value(TypeKind::Int, "10", "", "")), integer()).is_ok());
    assert!(check(Some(json!({"i":"10","r":"10"})), integer()).is_ok());
    assert!(
        check(Some(value(TypeKind::Int, "11", "", "")), integer())
            .unwrap_err()
            .contains("should be")
    );
}
#[test]
fn exact_shell_string_is_checked_without_numeric_coercion() {
    assert!(check(Some(value(TypeKind::String, "", "10", "")), string()).is_ok());
    assert!(
        check(Some(value(TypeKind::String, "", "11", "")), string())
            .unwrap_err()
            .contains("should be")
    );
    assert!(check(Some(value(TypeKind::String, "", " 10", "")), string()).is_err());
}
#[test]
fn missing_and_unloaded_required_values_fail() {
    for expected in [integer(), string()] {
        assert!(check(None, expected).unwrap_err().contains("missing"));
    }
    for kind in [TypeKind::None, TypeKind::Error] {
        assert!(
            check(Some(value(kind, "10", "10", "")), integer())
                .unwrap_err()
                .contains("not loaded")
        );
        assert!(
            check(Some(value(kind, "10", "10", "")), string())
                .unwrap_err()
                .contains("not loaded")
        );
    }
}
#[test]
fn wrong_representation_and_invalid_payload_fail() {
    assert!(
        check(Some(value(TypeKind::String, "10", "10", "10")), integer())
            .unwrap_err()
            .contains("not an integer")
    );
    assert!(
        check(Some(value(TypeKind::Int, "10", "10", "10")), string())
            .unwrap_err()
            .contains("not a string")
    );
    assert!(check(Some(value(TypeKind::Bool, "10", "10", "10")), integer()).is_err());
    assert!(
        check(Some(json!({"kind":TypeKind::String,"text":10})), string())
            .unwrap_err()
            .contains("invalid text")
    );
    assert!(check(Some(json!({"kind":255,"i":"10","r":"10"})), integer()).is_err());
    assert!(check(Some(value(TypeKind::Int, "not-int", "", "")), integer()).is_err());
}
