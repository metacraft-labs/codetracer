//! The wire encoding of the values a flow update carries (`ct/updated-flow`).
//!
//! A flow sends a value for every step whose line mentions it, and every node
//! of a value carries every field of the `Value` and `Type` records, most of
//! them at their defaults: on the Pascal sudoku solver's `main` (about 1,900
//! steps) the update was 8.8 MB, of which the values were 99%, half of it
//! empty strings, `false`, `0`, `null` and `[]`, and the window stopped
//! answering while it took the update in.
//!
//! So the replay server elides, on the values of a flow's steps, every field
//! whose value is its default ([`VALUE_DEFAULTS`], [`TYPE_DEFAULTS`]), and
//! says so: the update's [`ENCODING_FIELD`] is [`ELIDED_DEFAULTS_V1`]. A reader
//! restores the defaults before it reads the update ([`restore_flow_update`]),
//! and refuses an encoding it does not know, rather than reading a value
//! with fields missing as a value whose fields are empty. An update without
//! the field carries its values whole.
//!
//! The same table and the same two walks are in the front ends' Nim module
//! (`src/common/flow_wire.nim`); `tests/fixtures/` holds an update in both
//! encodings, which the tests of both read.

use serde_json::{Map, Value as Json};

/// The flow update's field naming how its values are encoded.
pub const ENCODING_FIELD: &str = "valueEncoding";

/// Default-valued fields of the step values are elided.
pub const ELIDED_DEFAULTS_V1: &str = "elided-defaults-1";

/// A `Value` node's fields and their defaults. `kind` and `typ` are always
/// written.
pub const VALUE_DEFAULTS: &[(&str, &str)] = &[
    ("activeVariant", "\"\""),
    ("activeVariantValue", "null"),
    ("address", "\"\""),
    ("b", "false"),
    ("c", "\"\""),
    ("cText", "\"\""),
    ("elements", "[]"),
    ("elementsTotal", "0"),
    ("f", "\"\""),
    ("i", "\"\""),
    ("isMutable", "false"),
    ("isWatch", "false"),
    ("msg", "\"\""),
    ("r", "\"\""),
    ("refValue", "null"),
    ("text", "\"\""),
];

/// A `Type` node's fields and their defaults. `kind` is always written.
pub const TYPE_DEFAULTS: &[(&str, &str)] = &[
    ("cType", "\"\""),
    ("elementType", "null"),
    ("labels", "[]"),
    ("langType", "\"\""),
    ("memberTypes", "[]"),
];

fn default_of(table: &[(&str, &str)], key: &str) -> Option<Json> {
    table
        .iter()
        .find(|(k, _)| *k == key)
        .map(|(_, d)| serde_json::from_str(d).expect("a default in the table is JSON"))
}

/// The step value maps of a flow update: `viewUpdates[].steps[].beforeValues`
/// and `.afterValues`.
fn for_each_step_value(body: &mut Json, f: &mut dyn FnMut(&mut Json)) {
    let Some(views) = body.get_mut("viewUpdates").and_then(Json::as_array_mut) else {
        return;
    };
    for view in views {
        let Some(steps) = view.get_mut("steps").and_then(Json::as_array_mut) else {
            continue;
        };
        for step in steps {
            for side in ["beforeValues", "afterValues"] {
                if let Some(values) = step.get_mut(side).and_then(Json::as_object_mut) {
                    for value in values.values_mut() {
                        f(value);
                    }
                }
            }
        }
    }
}

fn elide_type(typ: &mut Json) {
    let Some(fields) = typ.as_object_mut() else {
        return;
    };
    if let Some(element) = fields.get_mut("elementType") {
        elide_type(element);
    }
    if let Some(members) = fields.get_mut("memberTypes").and_then(Json::as_array_mut) {
        members.iter_mut().for_each(elide_type);
    }
    elide_fields(fields, TYPE_DEFAULTS);
}

fn elide_value(value: &mut Json) {
    let Some(fields) = value.as_object_mut() else {
        return;
    };
    if let Some(elements) = fields.get_mut("elements").and_then(Json::as_array_mut) {
        elements.iter_mut().for_each(elide_value);
    }
    for key in ["refValue", "activeVariantValue"] {
        if let Some(inner) = fields.get_mut(key) {
            elide_value(inner);
        }
    }
    if let Some(typ) = fields.get_mut("typ") {
        elide_type(typ);
    }
    elide_fields(fields, VALUE_DEFAULTS);
}

fn elide_fields(fields: &mut Map<String, Json>, table: &[(&str, &str)]) {
    fields.retain(|key, value| default_of(table, key).as_ref() != Some(value));
}

fn restore_type(typ: &mut Json) {
    let Some(fields) = typ.as_object_mut() else {
        return;
    };
    restore_fields(fields, TYPE_DEFAULTS);
    if let Some(element) = fields.get_mut("elementType") {
        restore_type(element);
    }
    if let Some(members) = fields.get_mut("memberTypes").and_then(Json::as_array_mut) {
        members.iter_mut().for_each(restore_type);
    }
}

fn restore_value(value: &mut Json) {
    let Some(fields) = value.as_object_mut() else {
        return;
    };
    restore_fields(fields, VALUE_DEFAULTS);
    if let Some(elements) = fields.get_mut("elements").and_then(Json::as_array_mut) {
        elements.iter_mut().for_each(restore_value);
    }
    for key in ["refValue", "activeVariantValue"] {
        if let Some(inner) = fields.get_mut(key) {
            restore_value(inner);
        }
    }
    if let Some(typ) = fields.get_mut("typ") {
        restore_type(typ);
    }
}

fn restore_fields(fields: &mut Map<String, Json>, table: &[(&str, &str)]) {
    for (key, default) in table {
        if !fields.contains_key(*key) {
            fields.insert(
                (*key).to_string(),
                serde_json::from_str(default).expect("a default in the table is JSON"),
            );
        }
    }
}

/// Elide the default-valued fields of a flow update's step values, and mark
/// the update as [`ELIDED_DEFAULTS_V1`]. An update already marked is left
/// as it is.
pub fn elide_flow_update(body: &mut Json) {
    if !body.is_object() || body.get(ENCODING_FIELD).is_some() {
        return;
    }
    for_each_step_value(body, &mut elide_value);
    body[ENCODING_FIELD] = Json::String(ELIDED_DEFAULTS_V1.to_string());
}

/// Restore what [`elide_flow_update`] elided, so the update reads as if its
/// values had been sent whole, and drop the marker. An update without the
/// marker is left as it is; one with an encoding this reader does not know is
/// refused.
pub fn restore_flow_update(body: &mut Json) -> Result<(), String> {
    let encoding = match body.get(ENCODING_FIELD) {
        None => return Ok(()),
        Some(Json::String(encoding)) => encoding.clone(),
        Some(other) => {
            return Err(format!(
                "a flow update's {ENCODING_FIELD} is not a name: {other}"
            ))
        }
    };
    if encoding != ELIDED_DEFAULTS_V1 {
        return Err(format!(
            "a flow update encodes its values as {encoding:?}, which this reader does not know \
             (it reads {ELIDED_DEFAULTS_V1:?})"
        ));
    }
    for_each_step_value(body, &mut restore_value);
    if let Some(fields) = body.as_object_mut() {
        fields.remove(ENCODING_FIELD);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> Json {
        let path = format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
        serde_json::from_str(&std::fs::read_to_string(&path).expect("the fixture")).expect("JSON")
    }

    #[test]
    fn the_fixture_elides_to_the_elided_fixture_and_restores_to_itself() {
        let full = fixture("flow-update.full.json");
        let mut elided = full.clone();
        elide_flow_update(&mut elided);
        assert_eq!(
            elided,
            fixture("flow-update.elided.json"),
            "elided as the front ends' tests read it"
        );
        let mut restored = elided.clone();
        restore_flow_update(&mut restored).expect("restore");
        assert_eq!(restored, full, "restored to exactly the original");
        let (full_len, elided_len) = (full.to_string().len(), elided.to_string().len());
        // Six steps of a Pascal grid flow keep 58% of their bytes; the whole
        // 224-step flow of that program keeps 32%.
        assert!(
            elided_len * 100 < full_len * 65,
            "elided {elided_len} of {full_len} bytes"
        );
    }

    #[test]
    fn a_value_whose_fields_are_all_set_survives_unchanged() {
        let mut body = serde_json::json!({"viewUpdates": [{"steps": [{"beforeValues": {"x": {
            "kind": 7, "i": "3", "f": "1.5", "b": true, "c": "a", "text": "t", "cText": "ct",
            "elements": [{"kind": 7, "i": "1", "typ": {"kind": 7, "langType": "int"}}],
            "elementsTotal": 9, "msg": "m", "r": "r", "address": "0x1", "refValue": {"kind": 7},
            "isMutable": true, "activeVariant": "v", "activeVariantValue": {"kind": 7},
            "isWatch": true,
            "typ": {"kind": 4, "langType": "T", "cType": "C", "labels": ["l"],
                    "elementType": {"kind": 7}, "memberTypes": [{"kind": 7}]}
        }}}]}]});
        let mut round = body.clone();
        elide_flow_update(&mut round);
        restore_flow_update(&mut round).expect("restore");
        restore_flow_update(&mut body).expect("an unmarked update is read as it is");
        // The nested nodes that came without their defaults come back with
        // them; the set fields are untouched.
        assert_eq!(
            round["viewUpdates"][0]["steps"][0]["beforeValues"]["x"]["i"],
            "3"
        );
        assert_eq!(
            round["viewUpdates"][0]["steps"][0]["beforeValues"]["x"]["typ"]["labels"][0],
            "l"
        );
        assert_eq!(
            round["viewUpdates"][0]["steps"][0]["beforeValues"]["x"]["elementsTotal"],
            9
        );
    }

    #[test]
    fn an_unknown_encoding_is_refused() {
        let mut body = serde_json::json!({"valueEncoding": "elided-defaults-2", "viewUpdates": []});
        let err = restore_flow_update(&mut body).expect_err("refused");
        assert!(err.contains("elided-defaults-2"), "{err}");
    }

    #[test]
    fn an_update_without_the_marker_is_read_as_it_is() {
        let full = fixture("flow-update.full.json");
        let mut read = full.clone();
        restore_flow_update(&mut read).expect("read");
        assert_eq!(read, full);
    }
}
