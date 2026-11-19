//! The replay server's flow value encoding against the fixtures the front
//! ends' tests read (`libs/ct-flow-wire/tests/fixtures`): the full update
//! elides to exactly the elided one, which restores to exactly the full one.
//! `src/common/flow_wire_test.nim` restores the same elided fixture, natively
//! and on the raw object the desktop reads, so a value this server elides
//! reads the same in every front end.

use serde_json::Value;

fn fixture(name: &str) -> Value {
    let path = format!(
        "{}/../../libs/ct-flow-wire/tests/fixtures/{name}",
        env!("CARGO_MANIFEST_DIR")
    );
    serde_json::from_str(&std::fs::read_to_string(&path).expect("the fixture")).expect("JSON")
}

#[test]
fn the_server_elides_the_fixture_as_the_front_ends_read_it() {
    let full = fixture("flow-update.full.json");
    let mut elided = full.clone();
    ct_flow_wire::elide_flow_update(&mut elided);
    assert_eq!(elided, fixture("flow-update.elided.json"));
    assert_eq!(elided[ct_flow_wire::ENCODING_FIELD], ct_flow_wire::ELIDED_DEFAULTS_V1);
    let mut restored = elided;
    ct_flow_wire::restore_flow_update(&mut restored).expect("readable");
    assert_eq!(restored, full);
}
