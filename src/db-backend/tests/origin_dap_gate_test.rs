#[allow(dead_code)]
#[path = "common/origin_dap_gate.rs"]
mod origin_dap_gate;

use origin_dap_gate::{required_mode_from_value, unavailable};

#[test]
fn required_mode_accepts_only_the_documented_values() {
    assert_eq!(required_mode_from_value(None), Ok(false));
    assert_eq!(required_mode_from_value(Some("0")), Ok(false));
    assert_eq!(required_mode_from_value(Some("1")), Ok(true));
}

#[test]
fn required_mode_rejects_empty_and_unknown_values() {
    for value in ["", "true", "yes", "2", " 1"] {
        let error =
            required_mode_from_value(Some(value)).expect_err("an undocumented required-mode value must fail closed");
        assert!(
            error.contains("must be unset, '0', or '1'"),
            "unexpected validation error for {value:?}: {error}"
        );
    }
}

#[test]
fn optional_mode_retains_the_explicit_skip_result() {
    let outcome: Option<()> = unavailable(false, "fixture", "missing recorder");
    assert!(outcome.is_none());
}

#[test]
#[should_panic(expected = "required origin-DAP gate cannot skip fixture: missing recorder")]
fn required_mode_turns_the_same_skip_into_a_failure() {
    let _: Option<()> = unavailable(true, "fixture", "missing recorder");
}
