//! The boundary log, CTBL v1: the record sequence `codetracer-wasm-recorder`
//! replays a WebAssembly module against.
//!
//! Specified by `codetracer-specs/Recording-Backends/Browser-Recording-Container.md`
//! §3. A boundary log is an *internal* format with exactly two carriers:
//!
//! * the `boundary.log` internal file of the `.ct` that `record-web` writes,
//!   which `wazero run --boundary-log <program>.ct` reads; and
//! * the stdin of the `--snapshot-consumer` process, which
//!   `wazero run --boundary-stream -` reads while the page is still running.
//!
//! Both carry the same bytes. CodeTracer writes them and never reads them:
//! the recording CodeTracer opens is the CTFS container around them.
//!
//! # Layout
//!
//! All integers are little-endian.
//!
//! ```text
//! stream  := "CTBL" version:u8 frame*
//! frame   := len:u32 payload[len]
//! payload := tag:u8 body
//! str     := len:u32 utf8[len]
//! value   := vtag:u8 body
//! ```
//!
//! Every frame is assembled into one buffer before it is written, so a
//! producer that dies leaves whole frames and no `End` — a stream the
//! consumer classifies as unterminated rather than torn.

/// The four magic bytes every boundary log starts with.
pub const MAGIC: &[u8; 4] = b"CTBL";

/// The one version this module writes.
pub const VERSION: u8 = 1;

/// Name of the CTFS internal file the log is stored under inside a `.ct`.
///
/// Twelve characters, which is the CTFS internal-name limit (base40 packs
/// at most twelve into the u64 `FileEntry.Name`).
pub const INTERNAL_FILE_NAME: &str = "boundary.log";

const TAG_HEADER: u8 = 0x01;
const TAG_PATH: u8 = 0x02;
const TAG_FUNCTION: u8 = 0x03;
const TAG_STEP: u8 = 0x04;
const TAG_CALL: u8 = 0x05;
const TAG_RETURN: u8 = 0x06;
const TAG_VALUE: u8 = 0x07;
const TAG_VARIABLE_NAME: u8 = 0x08;
const TAG_EVENT: u8 = 0x09;
const TAG_END: u8 = 0x0A;

const VTAG_INT: u8 = 0x01;
const VTAG_FLOAT: u8 = 0x02;
const VTAG_BOOL: u8 = 0x03;
const VTAG_STRING: u8 = 0x04;
const VTAG_RAW: u8 = 0x05;
const VTAG_NONE: u8 = 0x06;

/// One recorded value, in the producer's exact spelling.
///
/// Integers and floats stay text: a JS `BigInt` does not fit `i64`, and a
/// NaN payload has no `f64` spelling that survives a round trip, so the
/// replay compares against the text the page reported.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    Int(String),
    Float(String),
    Bool(bool),
    String(String),
    Raw(String),
    None,
}

/// One record of a boundary log.
///
/// Apart from `Header` and `End`, these are the records of the recording
/// itself, one for one and in the same order: the `Path`, `Function` and
/// `VariableName` tables are positional, exactly as in CTFS.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Record {
    Header {
        program: String,
        args: Vec<String>,
        workdir: String,
        recorder_name: String,
        recorder_version: String,
    },
    Path(String),
    Function {
        name: String,
        path_id: u32,
        line: i64,
    },
    Step {
        path_id: u32,
        line: i64,
    },
    Call {
        function_id: u32,
        args: Vec<(u32, Value)>,
    },
    Return(Value),
    Value {
        variable_id: u32,
        value: Value,
    },
    VariableName(String),
    Event {
        kind: i32,
        metadata: String,
        content: String,
    },
    End,
}

/// The bytes a boundary log starts with, before its first frame.
pub fn stream_prefix() -> [u8; 5] {
    let mut prefix = [0u8; 5];
    prefix[..4].copy_from_slice(MAGIC);
    prefix[4] = VERSION;
    prefix
}

/// Encode one record as a complete frame: its `u32` length, then its payload.
pub fn encode_frame(record: &Record) -> Vec<u8> {
    let mut payload = Vec::new();
    encode_payload(record, &mut payload);
    let len = u32::try_from(payload.len()).expect("a boundary-log record is smaller than 4 GiB");
    let mut frame = Vec::with_capacity(4 + payload.len());
    frame.extend_from_slice(&len.to_le_bytes());
    frame.extend_from_slice(&payload);
    frame
}

fn encode_payload(record: &Record, out: &mut Vec<u8>) {
    match record {
        Record::Header {
            program,
            args,
            workdir,
            recorder_name,
            recorder_version,
        } => {
            out.push(TAG_HEADER);
            put_str(out, program);
            put_u32(out, len_u32(args.len()));
            for arg in args {
                put_str(out, arg);
            }
            put_str(out, workdir);
            put_str(out, recorder_name);
            put_str(out, recorder_version);
        }
        Record::Path(path) => {
            out.push(TAG_PATH);
            put_str(out, path);
        }
        Record::Function {
            name,
            path_id,
            line,
        } => {
            out.push(TAG_FUNCTION);
            put_str(out, name);
            put_u32(out, *path_id);
            out.extend_from_slice(&line.to_le_bytes());
        }
        Record::Step { path_id, line } => {
            out.push(TAG_STEP);
            put_u32(out, *path_id);
            out.extend_from_slice(&line.to_le_bytes());
        }
        Record::Call { function_id, args } => {
            out.push(TAG_CALL);
            put_u32(out, *function_id);
            put_u32(out, len_u32(args.len()));
            for (variable_id, value) in args {
                put_u32(out, *variable_id);
                put_value(out, value);
            }
        }
        Record::Return(value) => {
            out.push(TAG_RETURN);
            put_value(out, value);
        }
        Record::Value { variable_id, value } => {
            out.push(TAG_VALUE);
            put_u32(out, *variable_id);
            put_value(out, value);
        }
        Record::VariableName(name) => {
            out.push(TAG_VARIABLE_NAME);
            put_str(out, name);
        }
        Record::Event {
            kind,
            metadata,
            content,
        } => {
            out.push(TAG_EVENT);
            out.extend_from_slice(&kind.to_le_bytes());
            put_str(out, metadata);
            put_str(out, content);
        }
        Record::End => out.push(TAG_END),
    }
}

fn put_value(out: &mut Vec<u8>, value: &Value) {
    match value {
        Value::Int(text) => {
            out.push(VTAG_INT);
            put_str(out, text);
        }
        Value::Float(text) => {
            out.push(VTAG_FLOAT);
            put_str(out, text);
        }
        Value::Bool(b) => {
            out.push(VTAG_BOOL);
            out.push(u8::from(*b));
        }
        Value::String(text) => {
            out.push(VTAG_STRING);
            put_str(out, text);
        }
        Value::Raw(text) => {
            out.push(VTAG_RAW);
            put_str(out, text);
        }
        Value::None => out.push(VTAG_NONE),
    }
}

fn put_u32(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_le_bytes());
}

fn put_str(out: &mut Vec<u8>, s: &str) {
    put_u32(out, len_u32(s.len()));
    out.extend_from_slice(s.as_bytes());
}

fn len_u32(len: usize) -> u32 {
    u32::try_from(len).expect("a boundary-log field is smaller than 4 GiB")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The encoding is pinned byte for byte, because the decoder that has to
    /// agree with it is in another repository and another language
    /// (`codetracer-wasm-recorder/internal/boundarylog`). The same vectors
    /// are pinned there; a change on one side that is not made on the other
    /// fails one of the two.
    #[test]
    fn frames_are_encoded_exactly_as_the_spec_lays_them_out() {
        assert_eq!(stream_prefix(), [b'C', b'T', b'B', b'L', 1]);

        assert_eq!(
            encode_frame(&Record::Path("a.js".into())),
            [9, 0, 0, 0, 0x02, 4, 0, 0, 0, b'a', b'.', b'j', b's'],
        );
        assert_eq!(
            encode_frame(&Record::Step {
                path_id: 1,
                line: -2
            }),
            [
                13, 0, 0, 0, 0x04, 1, 0, 0, 0, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
            ],
        );
        assert_eq!(
            encode_frame(&Record::Value {
                variable_id: 3,
                value: Value::Int("-7".into()),
            }),
            [12, 0, 0, 0, 0x07, 3, 0, 0, 0, 0x01, 2, 0, 0, 0, b'-', b'7'],
        );
        assert_eq!(
            encode_frame(&Record::Return(Value::Bool(true))),
            [3, 0, 0, 0, 0x06, 0x03, 1],
        );
        assert_eq!(
            encode_frame(&Record::Call {
                function_id: 2,
                args: vec![(0, Value::None)],
            }),
            [14, 0, 0, 0, 0x05, 2, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0x06],
        );
        assert_eq!(
            encode_frame(&Record::Event {
                kind: 12,
                metadata: "m".into(),
                content: String::new(),
            }),
            [14, 0, 0, 0, 0x09, 12, 0, 0, 0, 1, 0, 0, 0, b'm', 0, 0, 0, 0],
        );
        assert_eq!(encode_frame(&Record::End), [1, 0, 0, 0, 0x0A]);
        assert_eq!(
            encode_frame(&Record::Header {
                program: "p".into(),
                args: vec!["x".into()],
                workdir: "/".into(),
                recorder_name: "r".into(),
                recorder_version: "1".into(),
            }),
            [
                30, 0, 0, 0, 0x01, 1, 0, 0, 0, b'p', 1, 0, 0, 0, 1, 0, 0, 0, b'x', 1, 0, 0, 0,
                b'/', 1, 0, 0, 0, b'r', 1, 0, 0, 0, b'1'
            ],
        );
    }

    /// A field is length-prefixed by its UTF-8 byte count, not its character
    /// count; a decoder that read characters would desynchronise on the
    /// first non-ASCII name.
    #[test]
    fn string_lengths_count_bytes_not_characters() {
        let frame = encode_frame(&Record::VariableName("é".into()));
        assert_eq!(frame, [7, 0, 0, 0, 0x08, 2, 0, 0, 0, 0xC3, 0xA9]);
    }
}
