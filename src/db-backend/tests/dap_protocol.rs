use db_backend::dap::{from_json, to_json, DapMessage, ProtocolMessage, RequestArguments, Response};
use serde_json::json;

#[test]
fn test_parse_initialize_request() {
    let json_text = r#"{"seq":1,"type":"request","command":"initialize","arguments":{"adapterID":"small-lang"}}"#;
    let message = from_json(json_text).expect("valid message");
    match message {
        DapMessage::Request(req) => {
            assert_eq!(req.base.seq, 1);
            assert_eq!(req.command, "initialize");
            // println!("{:?}", req);
            match req.arguments {
                RequestArguments::Other(ref v) => {
                    assert_eq!(v["adapterID"], "small-lang");
                }
                other => {
                    panic!("unexpected arguments object: {:?}", other)
                }
            }
        }
        _ => panic!("expected request"),
    }
}

#[test]
fn test_serialize_initialize_response() {
    let body = json!({
        "supportsLoadedSourcesRequest": true,
        "supportsStepBack": true,
        "supportsConfigurationDoneRequest": true,
        "supportsDisassembleRequest": true,
        "supportsLogPoints": true,
        "supportsRestartRequest": true
    });
    let resp = Response {
        base: ProtocolMessage {
            seq: 2,
            type_: "response".to_string(),
        },
        request_seq: 1,
        success: true,
        command: "initialize".to_string(),
        message: None,
        body,
    };
    let original = DapMessage::Response(resp);
    let json_text = to_json(&original).expect("serialize");
    let deserialized = from_json(&json_text).expect("deserialize");
    assert_eq!(original, deserialized);
}

#[test]
fn test_session_sequence_parse() {
    let messages = vec![
        r#"{"seq":1,"type":"request","command":"initialize","arguments":{}}"#,
        r#"{"seq":2,"type":"response","request_seq":1,"success":true,"command":"initialize","body":{"supportsLoadedSourcesRequest":true,"supportsStepBack":true,"supportsConfigurationDoneRequest":true,"supportsDisassembleRequest":true,"supportsLogPoints":true,"supportsRestartRequest":true}}"#,
        r#"{"seq":3,"type":"event","event":"initialized"}"#,
        r#"{"seq":4,"type":"request","command":"launch","arguments":{"program":"main"}}"#,
        r#"{"seq":5,"type":"response","request_seq":4,"success":true,"command":"launch"}"#,
    ];
    let parsed: Vec<_> = messages.iter().map(|m| from_json(m).unwrap()).collect();
    assert_eq!(parsed.len(), messages.len());
    match &parsed[0] {
        DapMessage::Request(req) => assert_eq!(req.command, "initialize"),
        _ => panic!("unexpected type"),
    }
    match &parsed[1] {
        DapMessage::Response(resp) => {
            assert_eq!(resp.command, "initialize");
            assert!(resp.body["supportsLoadedSourcesRequest"].as_bool().unwrap());
            assert!(resp.body["supportsStepBack"].as_bool().unwrap());
            assert!(resp.body["supportsConfigurationDoneRequest"].as_bool().unwrap());
            assert!(resp.body["supportsDisassembleRequest"].as_bool().unwrap());
            assert!(resp.body["supportsLogPoints"].as_bool().unwrap());
            assert!(resp.body["supportsRestartRequest"].as_bool().unwrap());
        }
        _ => panic!("unexpected type"),
    }
    match &parsed[2] {
        DapMessage::Event(ev) => assert_eq!(ev.event, "initialized"),
        _ => panic!("unexpected type"),
    }
    match &parsed[4] {
        DapMessage::Response(resp) => {
            assert!(resp.success);
            assert_eq!(resp.command, "launch");
        }
        _ => panic!("unexpected type"),
    }
}
