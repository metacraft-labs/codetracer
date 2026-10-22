//! The records of `jsbound.log` (JS-Boundary-Recording.md §5.2) and their
//! field encodings.
//!
//! Every record is declared ONCE, in the [`define_records!`] table at the
//! bottom of this file: tag, name, and its fields in wire order with their
//! wire types. The enum, the body encoder, the body decoder and the canonical
//! JSON form (the one the shared byte vectors' expectations are written in)
//! are all generated from that table, so the four cannot drift apart. Every
//! `u8` field is an enumeration whose value set is [`VALUE_SETS`]; the
//! decoder refuses a value outside it (spec §5.3 rule 2). The
//! TypeScript implementation (codetracer-js-recorder
//! `packages/boundary-format/src/schema.ts`) carries the same table and is
//! held to the same vectors.

use serde_json::{Map, Value};
use std::fmt::Write as _;

use crate::decode::{DecodeErrorKind, PayloadReader};

/// The CTBL framing version `jsbound.log` uses (Browser-Recording-Container.md §3).
pub const CTBL_VERSION: u8 = 1;
/// The four magic bytes every CTBL stream starts with.
pub const CTBL_MAGIC: &[u8; 4] = b"CTBL";
/// The `vocab` this implementation reads and writes (the `Header` field).
pub const VOCAB: u16 = 1;
/// The largest frame a decoder accepts (spec §5.3 rule 2): 64 MiB.
pub const MAX_FRAME_LEN: u32 = 64 * 1024 * 1024;
/// The largest body a `blobref` may carry inline in `jsbound.log` (spec §5.2).
/// The assembler moves anything longer into `jsbound.blb`.
pub const MAX_INLINE_BLOB: usize = 1024;

/// A body that is either carried inline or referenced in `jsbound.blb`
/// (spec §5.2: `blobref := kind:u8 body`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BlobRef {
    /// Kind 0: the bytes themselves (`len:u32` raw bytes).
    Inline(Vec<u8>),
    /// Kind 1: `sha256:32 bytes, len:u64`, a key into `jsbound.blb`.
    Ref { sha256: [u8; 32], len: u64 },
}

const BLOB_INLINE: u8 = 0;
const BLOB_REF: u8 = 1;

/// One wire field type. Implemented for each type the record table uses.
pub(crate) trait Field: Sized {
    fn put(&self, out: &mut Vec<u8>);
    fn get(r: &mut PayloadReader<'_>) -> Result<Self, (DecodeErrorKind, String)>;
    fn to_json(&self) -> Value;
}

macro_rules! int_field {
    ($t:ty, $n:literal) => {
        impl Field for $t {
            fn put(&self, out: &mut Vec<u8>) {
                out.extend_from_slice(&self.to_le_bytes());
            }
            fn get(r: &mut PayloadReader<'_>) -> Result<Self, (DecodeErrorKind, String)> {
                let b = r.take($n)?;
                let mut a = [0u8; $n];
                a.copy_from_slice(b);
                Ok(<$t>::from_le_bytes(a))
            }
            fn to_json(&self) -> Value {
                Value::from(*self)
            }
        }
    };
}
int_field!(u8, 1);
int_field!(u16, 2);
int_field!(u32, 4);

/// `u64` values are spelled as decimal strings in the canonical JSON: a JSON
/// number is an IEEE-754 double in JavaScript and cannot carry a `seq` or the
/// bits of a clock value past 2^53 exactly.
impl Field for u64 {
    fn put(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.to_le_bytes());
    }
    fn get(r: &mut PayloadReader<'_>) -> Result<Self, (DecodeErrorKind, String)> {
        let b = r.take(8)?;
        Ok(u64::from_le_bytes(
            b.try_into().expect("take(8) returns 8 bytes"),
        ))
    }
    fn to_json(&self) -> Value {
        Value::String(self.to_string())
    }
}

/// `f64` fields (`dpr`, `delay_ms`) are spelled as JSON numbers. The shared
/// vectors use finite values only; a non-finite one has no JSON spelling and
/// is written as `null`, which no vector carries.
impl Field for f64 {
    fn put(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.to_bits().to_le_bytes());
    }
    fn get(r: &mut PayloadReader<'_>) -> Result<Self, (DecodeErrorKind, String)> {
        Ok(f64::from_bits(u64::get(r)?))
    }
    fn to_json(&self) -> Value {
        serde_json::Number::from_f64(*self).map_or(Value::Null, Value::Number)
    }
}

/// `str := len:u32 UTF-8`. A string that is not UTF-8 is refused.
impl Field for String {
    fn put(&self, out: &mut Vec<u8>) {
        put_len_prefixed(out, self.as_bytes());
    }
    fn get(r: &mut PayloadReader<'_>) -> Result<Self, (DecodeErrorKind, String)> {
        let at = r.position();
        let bytes = get_len_prefixed(r)?;
        String::from_utf8(bytes.to_vec()).map_err(|e| {
            (
                DecodeErrorKind::InvalidUtf8,
                format!("the string at payload offset {at} is not UTF-8 ({e})"),
            )
        })
    }
    fn to_json(&self) -> Value {
        Value::String(self.clone())
    }
}

/// `str-of-bytes := len:u32 raw bytes` (`Random.bytes`). Hex in JSON.
impl Field for Vec<u8> {
    fn put(&self, out: &mut Vec<u8>) {
        put_len_prefixed(out, self);
    }
    fn get(r: &mut PayloadReader<'_>) -> Result<Self, (DecodeErrorKind, String)> {
        Ok(get_len_prefixed(r)?.to_vec())
    }
    fn to_json(&self) -> Value {
        Value::String(hex(self))
    }
}

impl Field for BlobRef {
    fn put(&self, out: &mut Vec<u8>) {
        match self {
            BlobRef::Inline(bytes) => {
                out.push(BLOB_INLINE);
                put_len_prefixed(out, bytes);
            }
            BlobRef::Ref { sha256, len } => {
                out.push(BLOB_REF);
                out.extend_from_slice(sha256);
                len.put(out);
            }
        }
    }
    fn get(r: &mut PayloadReader<'_>) -> Result<Self, (DecodeErrorKind, String)> {
        match u8::get(r)? {
            BLOB_INLINE => Ok(BlobRef::Inline(get_len_prefixed(r)?.to_vec())),
            BLOB_REF => {
                let mut sha256 = [0u8; 32];
                sha256.copy_from_slice(r.take(32)?);
                Ok(BlobRef::Ref {
                    sha256,
                    len: u64::get(r)?,
                })
            }
            other => Err((
                DecodeErrorKind::UnknownBlobKind,
                format!("blobref kind {other} is neither 0 (inline) nor 1 (reference)"),
            )),
        }
    }
    fn to_json(&self) -> Value {
        let mut m = Map::new();
        match self {
            BlobRef::Inline(bytes) => {
                m.insert("kind".into(), "inline".into());
                m.insert("bytes".into(), hex(bytes).into());
            }
            BlobRef::Ref { sha256, len } => {
                m.insert("kind".into(), "ref".into());
                m.insert("sha256".into(), hex(sha256).into());
                m.insert("len".into(), len.to_json());
            }
        }
        Value::Object(m)
    }
}

/// The value set of every enumerated field of §5.2, as `(record, field,
/// least, greatest)`: the values from `least` to `greatest` are defined,
/// every other is refused as [`DecodeErrorKind::UnknownEnumValue`]. Every
/// `u8` field of the record table is one of these, and only those are
/// (`tests` below checks both directions). The TypeScript implementation
/// carries the same table (`ENUM_VALUE_SETS` in
/// `packages/boundary-format/src/schema.ts`), and the shared refusal vectors
/// hold both to every bound.
pub const VALUE_SETS: &[(&str, &str, u8, u8)] = &[
    // §9.1 levels.
    ("Header", "protocol_level", 0, 1),
    // §10.4: 0 no preference, 1 light, 2 dark; 1 when reduced motion.
    ("Env", "color_scheme", 0, 2),
    ("Env", "reduced_motion", 0, 1),
    ("Task", "kind", 1, 12),
    ("TaskReg", "kind", 1, 12),
    ("Clock", "src", 1, 5),
    ("Random", "src", 1, 3),
    ("NetRequest", "api", 1, 5),
    ("NetResponse", "outcome", 1, 5),
    ("WsMessage", "dir", 1, 4),
    ("StorageRead", "area", 1, 3),
    ("StorageRead", "present", 0, 2),
    ("DomEffect", "effect", 1, 6),
    ("Navigation", "kind", 1, 5),
    ("Error", "kind", 1, 2),
    ("Scrubbed", "class", 1, 4),
    ("Gap", "reason", 1, 3),
    ("End", "reason", 1, 4),
    // 1 the request, 2 its upload object; the seven `ProgressEvent` types
    // an XMLHttpRequest dispatches; a boolean.
    ("XhrEvent", "target", 1, 2),
    ("XhrEvent", "event", 1, 7),
    ("XhrEvent", "length_computable", 0, 1),
];

/// The value set of `record`.`field`, if it is an enumerated field.
pub fn value_set(record: &str, field: &str) -> Option<(u8, u8)> {
    VALUE_SETS
        .iter()
        .find(|(r, f, _, _)| *r == record && *f == field)
        .map(|&(_, _, lo, hi)| (lo, hi))
}

/// A decoded field checked against its value set (spec §5.3 rule 2). Only
/// the `u8` fields are enumerations; every other wire type has no set.
pub(crate) trait ValueSet {
    fn check(&self, _record: &str, _field: &str) -> Result<(), String> {
        Ok(())
    }
}

impl ValueSet for u8 {
    fn check(&self, record: &str, field: &str) -> Result<(), String> {
        match value_set(record, field) {
            Some((lo, hi)) if (lo..=hi).contains(self) => Ok(()),
            Some((lo, hi)) => Err(format!(
                "{record}.{field} is {self}; vocab {VOCAB} defines {lo} to {hi}"
            )),
            None => Err(format!(
                "{record}.{field} is a u8 field with no value set in this decoder"
            )),
        }
    }
}
/// Sets a `u8` field by name (the shared vectors' enumeration edits).
pub(crate) trait SetU8 {
    fn set_u8(&mut self, _v: u8) -> bool {
        false
    }
}
impl SetU8 for u8 {
    fn set_u8(&mut self, v: u8) -> bool {
        *self = v;
        true
    }
}
impl SetU8 for u16 {}
impl SetU8 for u32 {}
impl SetU8 for u64 {}
impl SetU8 for f64 {}
impl SetU8 for String {}
impl SetU8 for Vec<u8> {}
impl SetU8 for BlobRef {}

impl ValueSet for u16 {}
impl ValueSet for u32 {}
impl ValueSet for u64 {}
impl ValueSet for f64 {}
impl ValueSet for String {}
impl ValueSet for Vec<u8> {}
impl ValueSet for BlobRef {}

fn put_len_prefixed(out: &mut Vec<u8>, bytes: &[u8]) {
    let len = u32::try_from(bytes.len()).expect("a jsbound field is smaller than 4 GiB");
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(bytes);
}

fn get_len_prefixed<'a>(r: &mut PayloadReader<'a>) -> Result<&'a [u8], (DecodeErrorKind, String)> {
    let len = u32::get(r)?;
    r.take(len as usize)
}

/// Lowercase hexadecimal, the spelling of every byte string in the canonical
/// JSON and of every digest in the format.
pub fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(s, "{b:02x}");
    }
    s
}

/// Declares every record: `tag => Name { field: wire_type, ... }`, fields in
/// wire order. See the module documentation.
macro_rules! define_records {
    ( $( $tag:literal => $name:ident { $( $field:ident : $ty:ty ),* $(,)? } ),* $(,)? ) => {
        /// One record of `jsbound.log` (spec §5.2).
        ///
        /// Field names are the spec's (`r#type` is the spec's `type`).
        #[derive(Debug, Clone, PartialEq)]
        pub enum Record {
            $( #[allow(missing_docs)] $name { $( $field: $ty ),* } ),*
        }

        /// Every record kind as `(tag, name)`, in tag order.
        pub const RECORD_KINDS: &[(u8, &str)] = &[ $( ($tag, stringify!($name)) ),* ];

        /// Every field as `(record, field, wire type)`, in table order.
        pub const RECORD_FIELDS: &[(&str, &str, &str)] = &[
            $( $( (
                stringify!($name),
                stringify!($field),
                stringify!($ty),
            ), )* )*
        ];

        impl Record {
            /// The frame tag of this record.
            pub fn tag(&self) -> u8 {
                match self { $( Record::$name { .. } => $tag ),* }
            }

            /// The record's name as the spec spells it (`Clock`, `Gap`, …).
            pub fn kind_name(&self) -> &'static str {
                match self { $( Record::$name { .. } => stringify!($name) ),* }
            }

            /// Append the record's body (everything after the tag).
            pub(crate) fn encode_body(&self, out: &mut Vec<u8>) {
                match self {
                    $( Record::$name { $( $field ),* } => { $( Field::put($field, out); )* } ),*
                }
            }

            /// Decode a body for `tag`; `Ok(None)` for a tag this vocabulary
            /// does not define.
            pub(crate) fn decode_body(
                tag: u8,
                r: &mut PayloadReader<'_>,
            ) -> Result<Option<Record>, (DecodeErrorKind, String)> {
                match tag {
                    $( $tag => Ok(Some(Record::$name { $( $field: <$ty as Field>::get(r)? ),* })), )*
                    _ => Ok(None),
                }
            }

            /// Check every enumerated field against its value set, in wire
            /// order; the first value outside its set is the error.
            pub(crate) fn check_value_sets(&self) -> Result<(), String> {
                match self {
                    $( Record::$name { $( $field ),* } => {
                        $( ValueSet::check(
                            $field,
                            stringify!($name),
                            stringify!($field).trim_start_matches("r#"),
                        )?; )*
                    } ),*
                }
                Ok(())
            }

            /// Set the `u8` field `field` to `v`; false if the record has no
            /// such `u8` field.
            pub(crate) fn set_u8_field(&mut self, field: &str, v: u8) -> bool {
                match self {
                    $( Record::$name { $( $field ),* } => {
                        $( if stringify!($field) == field {
                            return SetU8::set_u8($field, v);
                        } )*
                        let _ = v;
                        false
                    } ),*
                }
            }

            /// The canonical JSON form the shared vectors' expectations are
            /// written in: `{"record": "<Name>", "<field>": <value>, …}`,
            /// with `u64` as decimal strings, byte strings as lowercase hex
            /// and a `blobref` as `{"kind": "inline", "bytes"}` or
            /// `{"kind": "ref", "sha256", "len"}`.
            pub fn to_json(&self) -> Value {
                let mut m = Map::new();
                match self {
                    $( Record::$name { $( $field ),* } => {
                        m.insert("record".into(), Value::from(stringify!($name)));
                        $( m.insert(
                            stringify!($field).trim_start_matches("r#").to_string(),
                            Field::to_json($field),
                        ); )*
                    } ),*
                }
                Value::Object(m)
            }
        }
    };
}

define_records! {
    0x40 => Header {
        vocab: u16,
        protocol_level: u8,
        recorder_id: String,
        framework: String,
        build_hash: String,
        session_id: String,
        prev_session: String,
        capabilities: String,
    },
    0x41 => Env {
        ua: String,
        ua_major: u16,
        viewport_w: u32,
        viewport_h: u32,
        dpr: f64,
        locale: String,
        tz: String,
        fonts_digest: String,
        color_scheme: u8,
        reduced_motion: u8,
        arms: String,
        url: String,
        referrer_origin: String,
        traceparent: String,
    },
    0x42 => Task { seq: u64, task_id: u64, kind: u8 },
    0x43 => TaskReg { seq: u64, task_id: u64, kind: u8, delay_ms: f64 },
    0x44 => Clock { seq: u64, src: u8, bits: u64 },
    0x45 => Random { seq: u64, src: u8, bytes: Vec<u8> },
    0x46 => NetRequest { seq: u64, req_id: u64, api: u8, method: String, url: String, body_digest: String },
    0x47 => NetResponse { seq: u64, req_id: u64, outcome: u8, status: u16, headers: String, body: BlobRef },
    0x48 => WsMessage { seq: u64, req_id: u64, dir: u8, data: BlobRef },
    0x49 => StorageRead { seq: u64, area: u8, key: String, present: u8, value: String },
    0x4A => LayoutRead { seq: u64, target: String, prop: String, value: String },
    0x4B => Input { seq: u64, task_id: u64, r#type: String, target: String, props: String, label: String },
    0x4C => DomEffect { seq: u64, target: String, effect: u8, value: String },
    0x4D => Checkpoint { seq: u64, ordinal: u32, scheme: String, state_hash: String, dom_digest: String },
    0x4E => Refusal { seq: u64, feature: String, detail: String },
    0x4F => Navigation { seq: u64, kind: u8, url: String },
    0x50 => Error { seq: u64, kind: u8, message: String, frames: String },
    0x51 => Scrubbed { seq: u64, target: String, class: u8, length: u32 },
    0x52 => Gap { first_seq: u64, last_seq: u64, reason: u8 },
    0x53 => Mark { seq: u64, name: String, data: String },
    0x56 => XhrEvent {
        seq: u64,
        req_id: u64,
        target: u8,
        event: u8,
        loaded: u64,
        total: u64,
        length_computable: u8,
    },
    0x5F => End { last_seq: u64, reason: u8 },
}

/// `Gap.reason` values (spec §5.2).
pub mod gap_reason {
    /// The client's ring overflowed (the batch envelope's `dropped`).
    pub const CLIENT_RING_OVERFLOW: u8 = 1;
    /// A batch never arrived.
    pub const BATCH_NEVER_ARRIVED: u8 = 2;
    /// A batch was refused by the ingest.
    pub const BATCH_REFUSED: u8 = 3;
}

/// `XhrEvent.target` and `XhrEvent.event` values (spec §5.2).
pub mod xhr_event {
    /// The event was dispatched at the `XMLHttpRequest` itself.
    pub const TARGET_REQUEST: u8 = 1;
    /// The event was dispatched at the request's `upload` object.
    pub const TARGET_UPLOAD: u8 = 2;
    /// `loadstart`.
    pub const LOADSTART: u8 = 1;
    /// `progress`.
    pub const PROGRESS: u8 = 2;
    /// `abort`.
    pub const ABORT: u8 = 3;
    /// `error`.
    pub const ERROR: u8 = 4;
    /// `load`.
    pub const LOAD: u8 = 5;
    /// `timeout`.
    pub const TIMEOUT: u8 = 6;
    /// `loadend`.
    pub const LOADEND: u8 = 7;
}

/// `End.reason` values (spec §5.2).
pub mod end_reason {
    /// `pagehide`.
    pub const PAGEHIDE: u8 = 1;
    /// The recorder was stopped explicitly.
    pub const EXPLICIT_STOP: u8 = 2;
    /// The ingest finalised the session after it went idle.
    pub const IDLE_FINALISATION: u8 = 3;
    /// The session reached the ingest's cap.
    pub const SESSION_CAP: u8 = 4;
}

impl Record {
    /// The record's `seq`, for every record that carries one (all but
    /// `Header`, `Env`, `Gap` and `End`).
    pub fn seq(&self) -> Option<u64> {
        match self {
            Record::Header { .. }
            | Record::Env { .. }
            | Record::Gap { .. }
            | Record::End { .. } => None,
            Record::Task { seq, .. }
            | Record::TaskReg { seq, .. }
            | Record::Clock { seq, .. }
            | Record::Random { seq, .. }
            | Record::NetRequest { seq, .. }
            | Record::NetResponse { seq, .. }
            | Record::WsMessage { seq, .. }
            | Record::StorageRead { seq, .. }
            | Record::LayoutRead { seq, .. }
            | Record::Input { seq, .. }
            | Record::DomEffect { seq, .. }
            | Record::Checkpoint { seq, .. }
            | Record::Refusal { seq, .. }
            | Record::Navigation { seq, .. }
            | Record::Error { seq, .. }
            | Record::Scrubbed { seq, .. }
            | Record::Mark { seq, .. }
            | Record::XhrEvent { seq, .. } => Some(*seq),
        }
    }

    /// The record's `blobref`, for the two records that carry one.
    pub fn blob(&self) -> Option<&BlobRef> {
        match self {
            Record::NetResponse { body, .. } => Some(body),
            Record::WsMessage { data, .. } => Some(data),
            _ => None,
        }
    }

    /// Mutable access to the record's `blobref` (the assembler rewrites
    /// large inline bodies into references).
    pub fn blob_mut(&mut self) -> Option<&mut BlobRef> {
        match self {
            Record::NetResponse { body, .. } => Some(body),
            Record::WsMessage { data, .. } => Some(data),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{RECORD_FIELDS, VALUE_SETS};

    /// Every `u8` field of the record table has a value set, and every
    /// value set names a `u8` field: a field added to the table without
    /// one, or a stale entry, fails here rather than in a decoder.
    #[test]
    fn every_u8_field_has_exactly_one_value_set() {
        let u8_fields: Vec<(&str, &str)> = RECORD_FIELDS
            .iter()
            .filter(|(_, _, ty)| *ty == "u8")
            .map(|&(r, f, _)| (r, f))
            .collect();
        let mut sets: Vec<(&str, &str)> = VALUE_SETS.iter().map(|&(r, f, _, _)| (r, f)).collect();
        let mut fields = u8_fields.clone();
        fields.sort_unstable();
        sets.sort_unstable();
        assert_eq!(fields, sets);
        assert!(VALUE_SETS.iter().all(|&(_, _, lo, hi)| lo <= hi));
        // Vacuity: the table has its twenty-one enumerated fields.
        assert_eq!(u8_fields.len(), 21);
    }
}
