//! The strict decoder of `jsbound.log` (JS-Boundary-Recording.md §5.3).
//!
//! Three layers, each usable on its own:
//!
//! * [`FrameSplitter`] cuts a run of CTBL frames (`len:u32 tag:u8 body`) into
//!   payloads and classifies where the input stops. The assembler uses it on
//!   the frame runs of uploaded batches, which carry no stream prefix.
//! * [`decode_record`] decodes one payload into a [`Record`], refusing an
//!   unknown tag, a frame shorter or longer than its fields, a string that is
//!   not UTF-8 and an unknown `blobref` kind.
//! * [`StreamRules`] holds the stream-level rules: `Header` first, `Env`
//!   second, `vocab` 1, the `seq` rule with its `Gap` exception, `End`'s
//!   `last_seq`, nothing after `End`, inline bodies at most 1024 bytes.
//!
//! [`decode_log`] puts the three together for a whole `jsbound.log`.
//!
//! Every refusal is a [`DecodeError`] whose [`DecodeErrorKind::name`] is the
//! name the TypeScript decoder (codetracer-js-recorder
//! `packages/boundary-format`) reports for the same input; the shared
//! refusal vectors pin both.
//!
//! The model is the CTBL v1 decoder in codetracer-wasm-recorder
//! `internal/boundarylog/ctbl.go` (Browser-Recording-Container.md §3).

use std::fmt;

use crate::record::{Record, CTBL_MAGIC, CTBL_VERSION, MAX_FRAME_LEN, MAX_INLINE_BLOB, VOCAB};

/// Why a stream was refused. The names are part of the format's contract
/// (the shared refusal vectors name them), so they never change spelling.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DecodeErrorKind {
    /// The stream does not start with `"CTBL"`.
    BadMagic,
    /// The CTBL `version` byte is not 1.
    UnsupportedVersion,
    /// The `Header`'s `vocab` is not 1.
    UnsupportedVocab,
    /// A frame tag this vocabulary does not define.
    UnknownTag,
    /// A frame whose `len` is 0 (it has no room for a tag).
    EmptyFrame,
    /// A frame whose `len` exceeds 64 MiB.
    FrameTooLarge,
    /// A frame shorter than the fields its tag declares.
    FieldOverrun,
    /// A frame with bytes after its last field.
    TrailingFieldBytes,
    /// A `str` field that is not UTF-8.
    InvalidUtf8,
    /// A `blobref` whose kind is neither 0 nor 1.
    UnknownBlobKind,
    /// An inline `blobref` longer than 1024 bytes in `jsbound.log`.
    InlineBlobTooLarge,
    /// The first frame is not `Header`, or a `Header` appears again later.
    HeaderNotFirst,
    /// The second frame is not `Env`, or an `Env` appears anywhere else.
    EnvNotSecond,
    /// A `seq` that is not the previous `seq` plus one, with no `Gap`
    /// covering exactly the missing range before it.
    SeqDiscontinuity,
    /// A `Gap` that does not start right after the previous `seq`, or whose
    /// `last_seq` is below its `first_seq`.
    GapMismatch,
    /// An `End` whose `last_seq` is not the last `seq` of the stream.
    EndSeqMismatch,
    /// Any byte after the `End` frame.
    BytesAfterEnd,
}

impl DecodeErrorKind {
    /// Every kind, for tests that check each has a refusal vector.
    pub const ALL: &'static [DecodeErrorKind] = &[
        DecodeErrorKind::BadMagic,
        DecodeErrorKind::UnsupportedVersion,
        DecodeErrorKind::UnsupportedVocab,
        DecodeErrorKind::UnknownTag,
        DecodeErrorKind::EmptyFrame,
        DecodeErrorKind::FrameTooLarge,
        DecodeErrorKind::FieldOverrun,
        DecodeErrorKind::TrailingFieldBytes,
        DecodeErrorKind::InvalidUtf8,
        DecodeErrorKind::UnknownBlobKind,
        DecodeErrorKind::InlineBlobTooLarge,
        DecodeErrorKind::HeaderNotFirst,
        DecodeErrorKind::EnvNotSecond,
        DecodeErrorKind::SeqDiscontinuity,
        DecodeErrorKind::GapMismatch,
        DecodeErrorKind::EndSeqMismatch,
        DecodeErrorKind::BytesAfterEnd,
    ];

    /// The contract name of this refusal.
    pub fn name(self) -> &'static str {
        match self {
            DecodeErrorKind::BadMagic => "BadMagic",
            DecodeErrorKind::UnsupportedVersion => "UnsupportedVersion",
            DecodeErrorKind::UnsupportedVocab => "UnsupportedVocab",
            DecodeErrorKind::UnknownTag => "UnknownTag",
            DecodeErrorKind::EmptyFrame => "EmptyFrame",
            DecodeErrorKind::FrameTooLarge => "FrameTooLarge",
            DecodeErrorKind::FieldOverrun => "FieldOverrun",
            DecodeErrorKind::TrailingFieldBytes => "TrailingFieldBytes",
            DecodeErrorKind::InvalidUtf8 => "InvalidUtf8",
            DecodeErrorKind::UnknownBlobKind => "UnknownBlobKind",
            DecodeErrorKind::InlineBlobTooLarge => "InlineBlobTooLarge",
            DecodeErrorKind::HeaderNotFirst => "HeaderNotFirst",
            DecodeErrorKind::EnvNotSecond => "EnvNotSecond",
            DecodeErrorKind::SeqDiscontinuity => "SeqDiscontinuity",
            DecodeErrorKind::GapMismatch => "GapMismatch",
            DecodeErrorKind::EndSeqMismatch => "EndSeqMismatch",
            DecodeErrorKind::BytesAfterEnd => "BytesAfterEnd",
        }
    }
}

/// A refused stream: what was wrong, and the byte offset of the frame (or
/// prefix) it was found in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodeError {
    pub kind: DecodeErrorKind,
    /// Offset, in the decoded input, of the frame the refusal is about.
    pub offset: u64,
    pub detail: String,
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} at byte {}: {}",
            self.kind.name(),
            self.offset,
            self.detail
        )
    }
}

impl std::error::Error for DecodeError {}

impl DecodeError {
    fn new(kind: DecodeErrorKind, offset: u64, detail: impl Into<String>) -> Self {
        DecodeError {
            kind,
            offset,
            detail: detail.into(),
        }
    }
}

/// How a decoded stream ended (spec §5.3 rule 4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Termination {
    /// The stream ends with its `End` frame.
    Complete,
    /// The stream stops at a frame boundary with no `End`; every record it
    /// carries is complete.
    TruncatedUnterminated,
    /// The stream stops inside a frame (or inside the stream prefix); the
    /// partial frame is discarded.
    TruncatedMidRecord,
}

impl Termination {
    /// The contract name, as the vectors' expectations spell it.
    pub fn name(self) -> &'static str {
        match self {
            Termination::Complete => "Complete",
            Termination::TruncatedUnterminated => "TruncatedUnterminated",
            Termination::TruncatedMidRecord => "TruncatedMidRecord",
        }
    }
}

/// Reads one frame's payload field by field. The first shortfall is a
/// [`DecodeErrorKind::FieldOverrun`].
pub struct PayloadReader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> PayloadReader<'a> {
    pub(crate) fn new(bytes: &'a [u8]) -> Self {
        PayloadReader { bytes, pos: 0 }
    }

    /// Bytes consumed so far.
    pub(crate) fn position(&self) -> usize {
        self.pos
    }

    pub(crate) fn take(&mut self, n: usize) -> Result<&'a [u8], (DecodeErrorKind, String)> {
        let end = self
            .pos
            .checked_add(n)
            .filter(|&end| end <= self.bytes.len());
        match end {
            Some(end) => {
                let s = &self.bytes[self.pos..end];
                self.pos = end;
                Ok(s)
            }
            None => Err((
                DecodeErrorKind::FieldOverrun,
                format!(
                    "the frame is shorter than its fields: wanted {n} byte(s) at payload offset {} of {}",
                    self.pos,
                    self.bytes.len()
                ),
            )),
        }
    }
}

/// Decode one frame payload (`tag:u8 body`) into a record.
///
/// `offset` is the frame's offset in the input, used only for the error.
pub fn decode_record(payload: &[u8], offset: u64) -> Result<Record, DecodeError> {
    let mut r = PayloadReader::new(payload);
    let tag = r.take(1).map_err(|(k, d)| DecodeError::new(k, offset, d))?[0];
    let record = Record::decode_body(tag, &mut r)
        .map_err(|(k, d)| DecodeError::new(k, offset, d))?
        .ok_or_else(|| {
            DecodeError::new(
                DecodeErrorKind::UnknownTag,
                offset,
                format!("frame tag 0x{tag:02x} is not a jsbound record (vocab {VOCAB} defines 0x40-0x53 and 0x5f)"),
            )
        })?;
    if r.position() != payload.len() {
        return Err(DecodeError::new(
            DecodeErrorKind::TrailingFieldBytes,
            offset,
            format!(
                "the {} frame has {} byte(s) after its last field",
                record.kind_name(),
                payload.len() - r.position()
            ),
        ));
    }
    Ok(record)
}

/// One complete frame cut out of the input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Frame<'a> {
    /// Offset of the frame's `len` field in the input given to the splitter
    /// (plus the splitter's base offset).
    pub offset: u64,
    /// `tag:u8 body`.
    pub payload: &'a [u8],
}

/// Where a frame run stops.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameRunEnd {
    /// The input ends exactly after a frame (or is empty).
    AtBoundary,
    /// The input ends inside a frame; this many bytes of it are discarded.
    MidFrame { partial: usize },
}

/// Cuts CTBL frames out of a byte run.
///
/// A `len` of 0 or over [`MAX_FRAME_LEN`] is refused as soon as its four
/// bytes are seen, before waiting for the body: a corrupted length prefix
/// would otherwise be reported as a truncation.
pub struct FrameSplitter<'a> {
    bytes: &'a [u8],
    pos: usize,
    base: u64,
}

impl<'a> FrameSplitter<'a> {
    /// Split `bytes`, reporting offsets as `base + position`.
    pub fn new(bytes: &'a [u8], base: u64) -> Self {
        FrameSplitter {
            bytes,
            pos: 0,
            base,
        }
    }

    /// The offset (in the input, plus base) of the next unread byte.
    pub fn offset(&self) -> u64 {
        self.base + self.pos as u64
    }

    /// Bytes not yet returned as frames.
    pub fn remaining(&self) -> usize {
        self.bytes.len() - self.pos
    }

    /// The next whole frame; `Ok(None)` at the end of the input, where
    /// [`FrameSplitter::end`] says how the run stopped.
    pub fn next_frame(&mut self) -> Result<Option<Frame<'a>>, DecodeError> {
        let rest = &self.bytes[self.pos..];
        if rest.len() < 4 {
            return Ok(None);
        }
        let len = u32::from_le_bytes(rest[..4].try_into().expect("4 bytes"));
        if len == 0 {
            return Err(DecodeError::new(
                DecodeErrorKind::EmptyFrame,
                self.offset(),
                "a frame of length 0 has no room for its tag",
            ));
        }
        if len > MAX_FRAME_LEN {
            return Err(DecodeError::new(
                DecodeErrorKind::FrameTooLarge,
                self.offset(),
                format!("a frame declares {len} bytes; the limit is {MAX_FRAME_LEN} (64 MiB)"),
            ));
        }
        let total = 4 + len as usize;
        if rest.len() < total {
            return Ok(None);
        }
        let frame = Frame {
            offset: self.offset(),
            payload: &rest[4..total],
        };
        self.pos += total;
        Ok(Some(frame))
    }

    /// How the run stops, once [`FrameSplitter::next_frame`] returned `None`.
    pub fn end(&self) -> FrameRunEnd {
        match self.remaining() {
            0 => FrameRunEnd::AtBoundary,
            partial => FrameRunEnd::MidFrame { partial },
        }
    }
}

/// The stream-level rules of spec §5.3, applied record by record.
#[derive(Debug, Default)]
pub struct StreamRules {
    /// Records accepted so far.
    count: u64,
    /// The `seq` the next seq-bearing record (or `Gap`) must start at.
    next_seq: u64,
    ended: bool,
}

impl StreamRules {
    pub fn new() -> Self {
        StreamRules {
            count: 0,
            next_seq: 1,
            ended: false,
        }
    }

    /// Whether the `End` record has been accepted.
    pub fn ended(&self) -> bool {
        self.ended
    }

    /// The last `seq` accepted (0 before any).
    pub fn last_seq(&self) -> u64 {
        self.next_seq - 1
    }

    /// Check `record`, found at `offset`, against the rules, and advance.
    pub fn accept(&mut self, record: &Record, offset: u64) -> Result<(), DecodeError> {
        let err = |kind, detail: String| Err(DecodeError::new(kind, offset, detail));
        if self.ended {
            return err(
                DecodeErrorKind::BytesAfterEnd,
                format!("a {} frame follows the End frame", record.kind_name()),
            );
        }
        match (self.count, record) {
            (0, Record::Header { vocab, .. }) => {
                if *vocab != VOCAB {
                    return err(
                        DecodeErrorKind::UnsupportedVocab,
                        format!("Header vocab {vocab} is not supported: this decoder reads vocab {VOCAB} only"),
                    );
                }
            }
            (0, other) => {
                return err(
                    DecodeErrorKind::HeaderNotFirst,
                    format!(
                        "the first frame must be Header, but it is {}",
                        other.kind_name()
                    ),
                )
            }
            (_, Record::Header { .. }) => {
                return err(
                    DecodeErrorKind::HeaderNotFirst,
                    "a second Header frame".to_string(),
                )
            }
            (1, Record::Env { .. }) => {}
            (1, other) => {
                return err(
                    DecodeErrorKind::EnvNotSecond,
                    format!(
                        "the second frame must be Env, but it is {}",
                        other.kind_name()
                    ),
                )
            }
            (_, Record::Env { .. }) => {
                return err(
                    DecodeErrorKind::EnvNotSecond,
                    "a second Env frame".to_string(),
                )
            }
            (
                _,
                Record::Gap {
                    first_seq,
                    last_seq,
                    ..
                },
            ) => {
                if *first_seq != self.next_seq || last_seq < first_seq {
                    return err(
                        DecodeErrorKind::GapMismatch,
                        format!(
                            "Gap {first_seq}..{last_seq} does not cover a range starting at the next seq {}",
                            self.next_seq
                        ),
                    );
                }
                self.next_seq = Self::after(*last_seq, offset)?;
            }
            (_, Record::End { last_seq, .. }) => {
                if *last_seq != self.last_seq() {
                    return err(
                        DecodeErrorKind::EndSeqMismatch,
                        format!(
                            "End.last_seq is {last_seq}, but the last seq is {}",
                            self.last_seq()
                        ),
                    );
                }
                self.ended = true;
            }
            (_, other) => {
                let seq = other.seq().expect("every other record carries a seq");
                if seq != self.next_seq {
                    return err(
                        DecodeErrorKind::SeqDiscontinuity,
                        format!(
                            "{} has seq {seq}, but the next seq is {} and no Gap covers the difference",
                            other.kind_name(),
                            self.next_seq
                        ),
                    );
                }
                self.next_seq = Self::after(seq, offset)?;
            }
        }
        if let Some(crate::record::BlobRef::Inline(bytes)) = record.blob() {
            if bytes.len() > MAX_INLINE_BLOB {
                return err(
                    DecodeErrorKind::InlineBlobTooLarge,
                    format!(
                        "{} carries a {}-byte inline body; jsbound.log inlines at most {MAX_INLINE_BLOB}",
                        record.kind_name(),
                        bytes.len()
                    ),
                );
            }
        }
        self.count += 1;
        Ok(())
    }

    fn after(seq: u64, offset: u64) -> Result<u64, DecodeError> {
        seq.checked_add(1).ok_or_else(|| {
            DecodeError::new(
                DecodeErrorKind::SeqDiscontinuity,
                offset,
                "seq overflows u64",
            )
        })
    }
}

/// A decoded `jsbound.log`.
#[derive(Debug, Clone, PartialEq)]
pub struct DecodedLog {
    /// The complete records, in stream order.
    pub records: Vec<Record>,
    /// The byte offset of each record's frame in the log (parallel to
    /// `records`); `jsbound.chk`'s `log_offset` is one of these.
    pub offsets: Vec<u64>,
    pub termination: Termination,
}

/// The stream prefix: `"CTBL"` and the version byte.
pub fn stream_prefix() -> [u8; 5] {
    let mut p = [0u8; 5];
    p[..4].copy_from_slice(CTBL_MAGIC);
    p[4] = CTBL_VERSION;
    p
}

/// Decode a whole `jsbound.log` strictly (spec §5.3).
///
/// A refusal is an `Err`. A stream that merely stops early is `Ok`, with its
/// complete records and its [`Termination`] class; a caller that needs a
/// complete stream checks `termination == Complete`.
pub fn decode_log(bytes: &[u8]) -> Result<DecodedLog, DecodeError> {
    let prefix_len = bytes.len().min(5);
    if bytes[..prefix_len.min(4)] != CTBL_MAGIC[..prefix_len.min(4)] {
        return Err(DecodeError::new(
            DecodeErrorKind::BadMagic,
            0,
            format!(
                "a jsbound.log starts with \"CTBL\", but this one starts with {:02x?}",
                &bytes[..prefix_len.min(4)]
            ),
        ));
    }
    if bytes.len() >= 5 && bytes[4] != CTBL_VERSION {
        return Err(DecodeError::new(
            DecodeErrorKind::UnsupportedVersion,
            4,
            format!(
                "CTBL version {} is not supported: this decoder reads version {CTBL_VERSION} only",
                bytes[4]
            ),
        ));
    }
    if bytes.len() < 5 {
        return Ok(DecodedLog {
            records: Vec::new(),
            offsets: Vec::new(),
            termination: Termination::TruncatedMidRecord,
        });
    }

    let mut splitter = FrameSplitter::new(&bytes[5..], 5);
    let mut rules = StreamRules::new();
    let mut records = Vec::new();
    let mut offsets = Vec::new();
    loop {
        if rules.ended() && splitter.remaining() > 0 {
            return Err(DecodeError::new(
                DecodeErrorKind::BytesAfterEnd,
                splitter.offset(),
                format!("{} byte(s) follow the End frame", splitter.remaining()),
            ));
        }
        let Some(frame) = splitter.next_frame()? else {
            break;
        };
        let record = decode_record(frame.payload, frame.offset)?;
        rules.accept(&record, frame.offset)?;
        records.push(record);
        offsets.push(frame.offset);
    }
    let termination = match splitter.end() {
        FrameRunEnd::MidFrame { .. } => Termination::TruncatedMidRecord,
        FrameRunEnd::AtBoundary if rules.ended() => Termination::Complete,
        FrameRunEnd::AtBoundary => Termination::TruncatedUnterminated,
    };
    Ok(DecodedLog {
        records,
        offsets,
        termination,
    })
}
