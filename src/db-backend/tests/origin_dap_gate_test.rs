#[allow(dead_code)]
#[path = "common/origin_dap_gate.rs"]
mod origin_dap_gate;

use origin_dap_gate::{required_mode_from_value, unavailable_reporting_to};

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
    let outcome: Option<()> = unavailable_reporting_to(false, "fixture", "missing recorder", None);
    assert!(outcome.is_none());
}

#[test]
#[should_panic(expected = "required origin-DAP gate cannot skip fixture: missing recorder")]
fn required_mode_turns_the_same_skip_into_a_failure() {
    let _: Option<()> = unavailable_reporting_to(true, "fixture", "missing recorder", None);
}

#[test]
fn a_skip_is_written_to_the_lanes_report() {
    let dir = tempfile::tempdir().expect("tempdir");
    let report = dir.path().join("skips.txt");
    let _: Option<()> = unavailable_reporting_to(false, "fixture", "missing\nrecorder", Some(&report));
    let _: Option<()> = unavailable_reporting_to(false, "other", "no tool", Some(&report));
    assert_eq!(
        std::fs::read_to_string(&report).expect("the report was written"),
        "fixture: missing recorder\nother: no tool\n",
        "one line per skip, each naming the test and the missing prerequisite"
    );
}

#[test]
fn a_required_failure_is_not_reported_as_a_skip() {
    let dir = tempfile::tempdir().expect("tempdir");
    let report = dir.path().join("skips.txt");
    let panicked = std::panic::catch_unwind(|| {
        let _: Option<()> = unavailable_reporting_to(true, "fixture", "missing recorder", Some(&report));
    });
    assert!(panicked.is_err(), "required mode must fail");
    assert!(
        !report.exists(),
        "a failure is not a skip and must not be listed as one"
    );
}

#[test]
fn graceful_skipping_is_disabled_only_by_an_explicit_false() {
    use origin_dap_gate::graceful_skipping_disabled_from_value;
    for value in ["false", "0", "no", "FALSE", " No "] {
        assert!(
            graceful_skipping_disabled_from_value(Some(value)),
            "{value:?} must make a missing prerequisite a failure"
        );
    }
    for value in [None, Some("true"), Some("1"), Some("")] {
        assert!(
            !graceful_skipping_disabled_from_value(value),
            "{value:?} must keep the developer-optional skip"
        );
    }
}

#[test]
fn a_skip_is_announced_as_having_asserted_nothing() {
    use origin_dap_gate::skip_banner;
    let banner = skip_banner("fixture", "missing recorder");
    assert!(banner.starts_with("SKIPPED: fixture: missing recorder"), "{banner}");
    assert!(banner.contains("asserted NOTHING"), "{banner}");
    assert!(
        banner.contains("CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false"),
        "{banner}"
    );
}
