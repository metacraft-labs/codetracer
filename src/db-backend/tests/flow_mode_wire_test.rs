//! The `ct/load-flow` `flowMode` contract, pinned on both sides of the
//! language boundary.
//!
//! # The defect this replaces
//!
//! `flowMode` used to be a `serde_repr` `u8`, which made the protocol depend
//! on two enums in two languages agreeing about *declaration order*:
//!
//!   * `FlowMode` here — `Call | Diff`, a query mode;
//!   * `FlowMode` in `src/frontend/viewmodel/viewmodels/flow_vm.nim` —
//!     `fmCall | fmLine | fmFunction`, a view granularity.
//!
//! They never agreed. The ViewModel sent `$mode` (`"fmCall"`), which usually
//! failed the parse — but "usually" is the problem, not the fix. An ordinal
//! crossing that boundary does not fail: `fmLine` is `1` is `Diff`, a
//! different query that answers with a plausible-looking window for the wrong
//! thing. A silent wrong answer is strictly worse than a parse error, and no
//! test on either side could have caught it, because there was nothing tying
//! the two vocabularies together.
//!
//! # What is pinned here
//!
//! 1. The wire form is a **name**, so a wrong value is a loud error.
//! 2. The legacy ordinal is still accepted inbound (the Karax renderer
//!    serialises the canonical Nim enum through `toJs`, and the Rust
//!    integration suites write `"flowMode": 0`), and it means what the Nim
//!    enum says it means.
//! 3. The Rust vocabulary and the Nim vocabulary are **read from the same
//!    two files and compared**. Adding a member to either enum without the
//!    other fails here or at Nim compile time — that mechanical link is the
//!    actual fix; the strings are just its subject.

use std::path::{Path, PathBuf};

use db_backend::task::{CtLoadFlowArguments, FLOW_MODE_WIRE_NAMES, FlowMode};
use serde_json::json;

fn repo_root() -> PathBuf {
    // `src/db-backend` -> repo root
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("db-backend lives two levels under the repo root")
        .to_path_buf()
}

const NIM_VOCABULARY: &str = "src/common/flow_mode_wire.nim";
const NIM_VIEW_ENUM: &str = "src/frontend/viewmodel/viewmodels/flow_vm.nim";

/// Extract the string literals of `FlowModeWireNames* = [...]`.
fn nim_wire_names(source: &str) -> Vec<String> {
    let start = source
        .find("FlowModeWireNames* = [")
        .unwrap_or_else(|| panic!("{NIM_VOCABULARY} no longer declares `FlowModeWireNames* = [...]`"));
    let rest = &source[start..];
    let open = rest.find('[').expect("array literal");
    let close = rest.find(']').expect("array literal end");
    let body = &rest[open + 1..close];

    // The literal is written with named constants (`[FlowModeWireCall,
    // FlowModeWireDiff]`), so resolve each name to its `const NAME* = "..."`.
    body.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|name| {
            let needle = format!("{name}* = \"");
            let at = source
                .find(&needle)
                .unwrap_or_else(|| panic!("{NIM_VOCABULARY} references `{name}` but never defines it"));
            let after = &source[at + needle.len()..];
            let end = after.find('"').expect("unterminated string literal");
            after[..end].to_string()
        })
        .collect()
}

fn read(relative: &str) -> String {
    let path = repo_root().join(relative);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// The mechanical link. If this fails, one language grew a flow mode the
/// other has never heard of.
#[test]
fn the_rust_and_nim_vocabularies_are_the_same_list() {
    let nim = nim_wire_names(&read(NIM_VOCABULARY));
    assert_eq!(
        nim,
        FLOW_MODE_WIRE_NAMES.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
        "`FlowModeWireNames` in {NIM_VOCABULARY} and `FLOW_MODE_WIRE_NAMES` in \
         src/db-backend/src/task.rs must be the same list, in the same order. \
         They are the `ct/load-flow` wire contract.",
    );
}

/// Every name in the shared vocabulary must actually parse, and every
/// variant must actually serialise to one. A list that agreed with the Nim
/// file but not with the enum would be a vocabulary nobody speaks.
#[test]
fn every_wire_name_round_trips_through_the_enum() {
    for name in FLOW_MODE_WIRE_NAMES {
        let mode = FlowMode::from_wire_name(name).unwrap_or_else(|| panic!("`{name}` does not parse"));
        assert_eq!(mode.wire_name(), *name);
    }
    // And the other direction, exhaustively — a new variant without a
    // spelling would not compile past the `match` in `wire_name`, but a
    // variant whose spelling is missing from the list would.
    for mode in [FlowMode::Call, FlowMode::Diff] {
        assert!(
            FLOW_MODE_WIRE_NAMES.contains(&mode.wire_name()),
            "{mode:?} serialises to `{}`, which is not in the shared vocabulary",
            mode.wire_name(),
        );
    }
}

/// The argument struct the ViewModel now builds must deserialize.
#[test]
fn the_view_model_request_shape_parses() {
    let args: CtLoadFlowArguments = serde_json::from_value(json!({
        "flowMode": "call",
        "location": { "path": "main.nr", "line": 9, "rrTicks": 314, "callstackDepth": 2 },
    }))
    .expect("the shape flow_vm.nim now sends must parse");
    assert_eq!(args.flow_mode, FlowMode::Call);
    assert_eq!(args.location.rr_ticks.0, 314);
    assert_eq!(args.location.line, 9);
}

/// The shape that used to be sent must fail, and fail *by name*.
#[test]
fn the_old_view_model_request_shape_is_rejected_by_name() {
    let err = serde_json::from_value::<CtLoadFlowArguments>(json!({
        "rrTicks": 200,
        "flowMode": "fmCall",
    }))
    .expect_err("`fmCall` is not a flow mode and there is no location");
    let message = err.to_string();
    assert!(
        message.contains("fmCall") || message.contains("location"),
        "the rejection must say what was wrong, got: {message}",
    );
}

/// A view granularity that has no engine meaning must not be silently
/// accepted under any spelling.
#[test]
fn a_view_granularity_is_never_mistaken_for_a_query_mode() {
    for spelling in ["fmCall", "fmLine", "fmFunction", "line", "function", "Call", "CALL"] {
        assert!(
            FlowMode::from_wire_name(spelling).is_none(),
            "`{spelling}` must not parse as a flow mode: the engine has exactly \
             {FLOW_MODE_WIRE_NAMES:?} and a near-miss that resolves is how a \
             wrong query looks like a right one",
        );
    }
}

/// The legacy ordinal stays readable — the Karax renderer serialises the
/// canonical Nim enum through `toJs`, which is an ordinal — but only within
/// range. `2` (what `fmFunction` would have produced) must be an error, not
/// a default.
#[test]
fn the_legacy_ordinal_is_accepted_in_range_and_refused_outside_it() {
    for (ordinal, expected) in [(0u64, FlowMode::Call), (1, FlowMode::Diff)] {
        let args: CtLoadFlowArguments =
            serde_json::from_value(json!({ "flowMode": ordinal, "location": {} })).expect("legacy ordinal");
        assert_eq!(args.flow_mode, expected);
    }
    let err = serde_json::from_value::<CtLoadFlowArguments>(json!({ "flowMode": 2, "location": {} }))
        .expect_err("ordinal 2 is the ViewModel's `fmFunction`; the engine has no third mode");
    assert!(err.to_string().contains('2'), "got: {}", err);
}

/// Serialisation emits the name, so anything this engine writes is readable
/// by a parser that only knows names.
#[test]
fn serialisation_emits_the_name_not_the_ordinal() {
    let value = serde_json::to_value(CtLoadFlowArguments {
        flow_mode: FlowMode::Diff,
        ..Default::default()
    })
    .expect("serialise");
    assert_eq!(value["flowMode"], json!("diff"));
}

/// The ViewModel must keep routing its three-valued granularity through one
/// named translation rather than stringifying the enum at the call site.
/// This is the half a Rust test can check cheaply: that the old `$mode`
/// spelling is gone from the request builder.
#[test]
fn the_view_model_no_longer_stringifies_its_own_enum_onto_the_wire() {
    let source = read(NIM_VIEW_ENUM);
    assert!(
        source.contains("engineFlowModeWireName"),
        "{NIM_VIEW_ENUM} must translate its view granularity through one named proc",
    );
    let request = source
        .split("\"ct/load-flow\"")
        .next()
        .expect("the request builder precedes the send");
    assert!(
        !request.contains("\"flowMode\": $mode") && !request.contains("\"flowMode\": viewMode"),
        "{NIM_VIEW_ENUM} must not put its own enum's spelling on the wire",
    );
    assert!(
        request.contains("\"flowMode\": wireMode"),
        "{NIM_VIEW_ENUM} must send the engine's vocabulary",
    );
    assert!(
        request.contains("\"location\""),
        "{NIM_VIEW_ENUM} must send the required `location`",
    );
}
