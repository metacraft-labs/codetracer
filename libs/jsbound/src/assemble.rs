//! `ct-jsbound assemble`: staged batches in, a boundary recording out
//! (JS-Boundary-Recording.md §5.6, Boundary-Ingest.md §5).
//!
//! The assembler
//!
//! 1. parses every batch and orders them by `batch_seq` (the order the
//!    batches are given in does not matter);
//! 2. concatenates their records and writes a `Gap` for every `seq` range
//!    no batch carries: reason 1 where an envelope's `dropped` declares it,
//!    reason 3 where it lies between batches whose missing `batch_seq`s the
//!    ingest refused, reason 2 where they simply never arrived. A hole that
//!    neither a `dropped` range nor a missing batch explains is refused;
//! 3. moves every inline body over 1024 bytes into `jsbound.blb`;
//! 4. appends `End{reason: 3}` (idle) or `End{reason: 4}` (session cap) when
//!    the stream has no `End` and the finaliser says why it ended;
//! 5. decodes the assembled log strictly (§5.3), so it never writes a log its
//!    own decoder would refuse; and
//! 6. writes `meta.dat`, `jsbound.log`, `jsbound.blb` and `jsbound.chk`.
//!
//! The output is a pure function of the batches, the `recording_id` and the
//! options: the same input produces a byte-identical `.ct`.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use crate::batch::{parse_batch, Batch, BatchError};
use crate::container::{
    check_blob_refs, derive_checkpoint_index, encode_checkpoint_index, encode_meta,
    write_container, BlobStore, ContainerError, Members,
};
use crate::decode::{decode_log, DecodeError, Termination};
use crate::encode::encode_log;
use crate::record::{end_reason, gap_reason, BlobRef, Record, MAX_INLINE_BLOB};

/// How the finaliser says the session ended, when the stream itself does
/// not end with `End` (Boundary-Ingest.md §5 step 3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Finalisation {
    /// The stream must end with its own `End`; a stream without one is
    /// refused.
    Ended,
    /// No batch for 30 minutes: append `End{reason: 3}` if there is no `End`.
    Idle,
    /// The session cap was reached: append `End{reason: 4}` if there is no
    /// `End`.
    SessionCap,
}

/// The assembler's inputs other than the batches.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssembleOptions {
    /// The server-minted UUIDv7 (canonical lowercase form).
    pub recording_id: String,
    pub finalisation: Finalisation,
    /// `batch_seq`s the ingest refused; a hole that only they explain is a
    /// `Gap` with reason 3.
    pub refused_batches: BTreeSet<u64>,
}

/// Why assembly was refused.
#[derive(Debug, Clone, PartialEq)]
pub enum AssembleError {
    /// No batch was given.
    NoBatches,
    /// The `recording_id` is not a canonical UUIDv7.
    BadRecordingId(String),
    /// Batch number `index` (in the order given) was refused.
    Batch { index: usize, error: BatchError },
    /// Two batches carry the same `batch_seq`.
    DuplicateBatch(u64),
    /// The batches disagree on `session_id` or `build_hash`, or the `Header`
    /// disagrees with the envelopes.
    SessionMismatch(String),
    /// An envelope's `first_seq`/`last_seq` disagrees with its frames.
    EnvelopeSeqMismatch(String),
    /// A recorder wrote a `Gap` (only the assembler writes them).
    GapFromRecorder { batch_seq: u64 },
    /// A `dropped` range overlaps records some batch carries.
    DroppedOverlapsRecords(String),
    /// A `seq` hole nothing explains.
    UnexplainedGap { first_seq: u64, last_seq: u64 },
    /// The stream has no `End` and the finalisation is [`Finalisation::Ended`].
    Unterminated,
    /// The assembled log was refused by the strict decoder.
    Decode(DecodeError),
    /// A `blobref` or the container itself was refused.
    Container(ContainerError),
}

impl AssembleError {
    /// A stable name for the refusal, for the ingest's `boundary_sessions`
    /// row and for tests.
    pub fn name(&self) -> &'static str {
        match self {
            AssembleError::NoBatches => "NoBatches",
            AssembleError::BadRecordingId(_) => "BadRecordingId",
            AssembleError::Batch { .. } => "BadBatch",
            AssembleError::DuplicateBatch(_) => "DuplicateBatch",
            AssembleError::SessionMismatch(_) => "SessionMismatch",
            AssembleError::EnvelopeSeqMismatch(_) => "EnvelopeSeqMismatch",
            AssembleError::GapFromRecorder { .. } => "GapFromRecorder",
            AssembleError::DroppedOverlapsRecords(_) => "DroppedOverlapsRecords",
            AssembleError::UnexplainedGap { .. } => "UnexplainedGap",
            AssembleError::Unterminated => "Unterminated",
            AssembleError::Decode(e) => e.kind.name(),
            AssembleError::Container(ContainerError::MissingBlob(_)) => "MissingBlob",
            AssembleError::Container(_) => "Container",
        }
    }
}

impl fmt::Display for AssembleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: ", self.name())?;
        match self {
            AssembleError::NoBatches => write!(f, "no batches were given"),
            AssembleError::BadRecordingId(id) => write!(f, "recording_id {id:?} is not a canonical UUIDv7"),
            AssembleError::Batch { index, error } => write!(f, "batch #{index}: {error}"),
            AssembleError::DuplicateBatch(n) => write!(f, "two batches carry batch_seq {n}"),
            AssembleError::SessionMismatch(e)
            | AssembleError::EnvelopeSeqMismatch(e)
            | AssembleError::DroppedOverlapsRecords(e) => write!(f, "{e}"),
            AssembleError::GapFromRecorder { batch_seq } => {
                write!(f, "batch {batch_seq} carries a Gap record, which only the assembler writes")
            }
            AssembleError::UnexplainedGap { first_seq, last_seq } => write!(
                f,
                "seq {first_seq}..{last_seq} is missing between consecutive batches and no dropped range covers it"
            ),
            AssembleError::Unterminated => write!(
                f,
                "the stream has no End record and the session was not finalised as idle or capped"
            ),
            AssembleError::Decode(e) => write!(f, "{e}"),
            AssembleError::Container(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for AssembleError {}

/// The assembled recording: its four members and the container holding them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Assembled {
    pub members: Members,
    /// The `.ct` bytes.
    pub container: Vec<u8>,
    /// What the ingest records about the session, read from the assembled
    /// log (JS-Boundary-Recording.md §5.6, "Summary").
    pub summary: Summary,
}

/// One `Gap` of the assembled log.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct GapSummary {
    pub first_seq: u64,
    pub last_seq: u64,
    pub reason: u8,
}

/// The facts about an assembled session that the ingest stores in its
/// session row and passes on registration. The ingest never decodes frames
/// itself: it reads these from the assembler's `--summary` file, as plain
/// JSON, so everything it learns about the records comes from this process,
/// which the ingest runs sandboxed.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Summary {
    /// The `Header`'s session id (the envelopes' `session_id`).
    pub session_id: String,
    /// The `Header`'s build hash (the envelopes' `build_hash`).
    pub build_hash: String,
    /// The number of batches assembled.
    pub batches: u64,
    /// Every record of the assembled log, `Gap` and an appended `End` included.
    pub records: u64,
    /// The first `seq` the log accounts for (a record's or a `Gap`'s), 0 when none.
    pub first_seq: u64,
    /// `End.last_seq`.
    pub last_seq: u64,
    /// `End.reason`.
    pub end_reason: u8,
    /// Every `Gap`, in `seq` order.
    pub gaps: Vec<GapSummary>,
    /// The number of `Refusal` records.
    pub refusals: u64,
    /// Whether the log can be replayed to its end: no `Gap` and no `Refusal`.
    pub replayable: bool,
    /// Whether the log holds an `Error` record.
    pub has_error: bool,
    /// The trace id of `Env.traceparent` (32 lowercase hex digits) when it is
    /// a well-formed W3C `traceparent`
    /// (<https://www.w3.org/TR/trace-context/#traceparent-header>) with a
    /// non-zero trace id and parent id; `None` otherwise.
    pub trace_id: Option<String>,
    /// `Env.arms` when it is a JSON object whose values are all strings
    /// (experiment key to arm); `None` otherwise.
    pub arms: Option<serde_json::Map<String, serde_json::Value>>,
    /// `meta.dat`'s `program`: `Env.url` without query or fragment.
    pub program: String,
    /// The size of the `.ct` in bytes.
    pub container_bytes: u64,
}

/// The trace id of a W3C `traceparent`, or `None` when it is not one.
/// Version `00` has exactly four fields; a later version (not `ff`) is read
/// by the version-00 rules with any further fields ignored, as the
/// specification asks of a version-00 parser.
fn trace_id_of(traceparent: &str) -> Option<String> {
    let parts: Vec<&str> = traceparent.split('-').collect();
    if parts.len() < 4 {
        return None;
    }
    let is_hex = |s: &str, n: usize| {
        s.len() == n && s.bytes().all(|c| matches!(c, b'0'..=b'9' | b'a'..=b'f'))
    };
    let (version, trace_id, parent_id, flags) = (parts[0], parts[1], parts[2], parts[3]);
    if !is_hex(version, 2) || version == "ff" || (version == "00" && parts.len() != 4) {
        return None;
    }
    if !is_hex(trace_id, 32) || !is_hex(parent_id, 16) || !is_hex(flags, 2) {
        return None;
    }
    if trace_id.bytes().all(|c| c == b'0') || parent_id.bytes().all(|c| c == b'0') {
        return None;
    }
    Some(trace_id.to_string())
}

/// `Env.arms` as a map of experiment key to arm, when it is one.
fn arms_of(arms: &str) -> Option<serde_json::Map<String, serde_json::Value>> {
    match serde_json::from_str::<serde_json::Value>(arms) {
        Ok(serde_json::Value::Object(map)) if map.values().all(serde_json::Value::is_string) => {
            Some(map)
        }
        _ => None,
    }
}

/// Summarise a strictly decoded, complete log.
pub(crate) fn summarise(
    decoded: &crate::decode::DecodedLog,
    batches: usize,
    container_bytes: usize,
) -> Summary {
    let mut summary = Summary {
        session_id: String::new(),
        build_hash: String::new(),
        batches: batches as u64,
        records: decoded.records.len() as u64,
        first_seq: 0,
        last_seq: 0,
        end_reason: 0,
        gaps: Vec::new(),
        refusals: 0,
        replayable: true,
        has_error: false,
        trace_id: None,
        arms: None,
        program: String::new(),
        container_bytes: container_bytes as u64,
    };
    for record in &decoded.records {
        if summary.first_seq == 0 {
            summary.first_seq = match record {
                Record::Gap { first_seq, .. } => *first_seq,
                other => other.seq().unwrap_or(0),
            };
        }
        match record {
            Record::Header {
                session_id,
                build_hash,
                ..
            } => {
                summary.session_id = session_id.clone();
                summary.build_hash = build_hash.clone();
            }
            Record::Env {
                url,
                arms,
                traceparent,
                ..
            } => {
                summary.program = program_of(url).to_string();
                summary.trace_id = trace_id_of(traceparent);
                summary.arms = arms_of(arms);
            }
            Record::Gap {
                first_seq,
                last_seq,
                reason,
            } => summary.gaps.push(GapSummary {
                first_seq: *first_seq,
                last_seq: *last_seq,
                reason: *reason,
            }),
            Record::Refusal { .. } => summary.refusals += 1,
            Record::Error { .. } => summary.has_error = true,
            Record::End { last_seq, reason } => {
                summary.last_seq = *last_seq;
                summary.end_reason = *reason;
            }
            _ => {}
        }
    }
    summary.replayable = summary.gaps.is_empty() && summary.refusals == 0;
    summary
}

/// Whether `id` is a canonical lowercase UUID whose version nibble is 7.
fn is_uuid_v7(id: &str) -> bool {
    let b = id.as_bytes();
    b.len() == 36
        && b.iter().enumerate().all(|(i, &c)| match i {
            8 | 13 | 18 | 23 => c == b'-',
            _ => matches!(c, b'0'..=b'9' | b'a'..=b'f'),
        })
        && b[14] == b'7'
}

/// `meta.dat`'s `program`: the page's origin and path, query and fragment
/// removed (§5.1). `Env.url` is already recorded that way; this strips
/// defensively.
fn program_of(url: &str) -> &str {
    let end = url.find(['?', '#']).unwrap_or(url.len());
    &url[..end]
}

/// Inclusive ranges of `[first, last]` not covered by `cover` (sorted,
/// disjoint), and the covered parts, in `seq` order, each tagged covered or
/// not.
fn split_by_cover(first: u64, last: u64, cover: &[(u64, u64)]) -> Vec<(u64, u64, bool)> {
    let mut parts = Vec::new();
    let mut at = first;
    for &(a, b) in cover {
        if b < at || a > last {
            continue;
        }
        if a > at {
            parts.push((at, a - 1, false));
        }
        let end = b.min(last);
        parts.push((at.max(a), end, true));
        if end == last {
            return parts;
        }
        at = end + 1;
    }
    parts.push((at, last, false));
    parts
}

/// Merge overlapping or adjacent inclusive ranges.
fn normalise(mut ranges: Vec<(u64, u64)>) -> Vec<(u64, u64)> {
    ranges.sort_unstable();
    let mut out: Vec<(u64, u64)> = Vec::new();
    for (a, b) in ranges {
        match out.last_mut() {
            Some(last) if a <= last.1.saturating_add(1) => last.1 = last.1.max(b),
            _ => out.push((a, b)),
        }
    }
    out
}

/// Assemble batch bodies into a boundary recording.
pub fn assemble(bodies: &[Vec<u8>], options: &AssembleOptions) -> Result<Assembled, AssembleError> {
    if !is_uuid_v7(&options.recording_id) {
        return Err(AssembleError::BadRecordingId(options.recording_id.clone()));
    }
    if bodies.is_empty() {
        return Err(AssembleError::NoBatches);
    }
    let mut batches: Vec<Batch> = bodies
        .iter()
        .enumerate()
        .map(|(index, body)| {
            parse_batch(body).map_err(|error| AssembleError::Batch { index, error })
        })
        .collect::<Result<_, _>>()?;
    batches.sort_by_key(|b| b.envelope.batch_seq);
    for pair in batches.windows(2) {
        if pair[0].envelope.batch_seq == pair[1].envelope.batch_seq {
            return Err(AssembleError::DuplicateBatch(pair[0].envelope.batch_seq));
        }
    }
    check_envelopes(&batches)?;

    let dropped = normalise(
        batches
            .iter()
            .flat_map(|b| b.envelope.dropped.iter().map(|&[a, z]| (a, z)))
            .collect(),
    );
    let records = merge_with_gaps(&batches, &dropped, &options.refused_batches)?;
    let (records, blobs) = move_large_bodies(records)?;
    let records = terminate(records, options.finalisation)?;

    let (log, _) = encode_log(&records);
    let decoded = decode_log(&log).map_err(AssembleError::Decode)?;
    if decoded.termination != Termination::Complete {
        // `terminate` guarantees an End somewhere; one that is not last is
        // refused above as BytesAfterEnd, so this is unreachable. Refuse
        // rather than write a log that does not end.
        return Err(AssembleError::Unterminated);
    }
    check_blob_refs(&decoded.records, &blobs).map_err(AssembleError::Container)?;

    let (vocab, program) = match (&decoded.records[0], &decoded.records[1]) {
        (Record::Header { vocab, .. }, Record::Env { url, .. }) => (*vocab, program_of(url)),
        _ => unreachable!("a strictly decoded log starts with Header and Env"),
    };
    let members = Members {
        meta_dat: encode_meta(&options.recording_id, program, vocab),
        chk: encode_checkpoint_index(&derive_checkpoint_index(&decoded)),
        blb: blobs.encode(),
        log,
    };
    let container = write_container(&members).map_err(AssembleError::Container)?;
    let summary = summarise(&decoded, bodies.len(), container.len());
    Ok(Assembled {
        members,
        container,
        summary,
    })
}

/// Every batch names the same session and build, the `Header` agrees with
/// them, and each envelope's `first_seq`/`last_seq` are its frames'.
fn check_envelopes(batches: &[Batch]) -> Result<(), AssembleError> {
    let first = &batches[0].envelope;
    for b in batches {
        let e = &b.envelope;
        if e.session_id != first.session_id || e.build_hash != first.build_hash {
            return Err(AssembleError::SessionMismatch(format!(
                "batch {} names session {} build {}, batch {} names session {} build {}",
                first.batch_seq,
                first.session_id,
                first.build_hash,
                e.batch_seq,
                e.session_id,
                e.build_hash
            )));
        }
        let seqs: Vec<u64> = b.records.iter().filter_map(|(_, r)| r.seq()).collect();
        if let (Some(&lo), Some(&hi)) = (seqs.first(), seqs.last()) {
            if (lo, hi) != (e.first_seq, e.last_seq) {
                return Err(AssembleError::EnvelopeSeqMismatch(format!(
                    "batch {} declares seq {}..{} but carries {lo}..{hi}",
                    e.batch_seq, e.first_seq, e.last_seq
                )));
            }
        }
        for (_, r) in &b.records {
            match r {
                Record::Gap { .. } => return Err(AssembleError::GapFromRecorder { batch_seq: e.batch_seq }),
                Record::Header {
                    session_id,
                    build_hash,
                    ..
                } if (session_id, build_hash) != (&e.session_id, &e.build_hash) => {
                    return Err(AssembleError::SessionMismatch(format!(
                        "the Header names session {session_id} build {build_hash}, the envelopes {} {}",
                        e.session_id, e.build_hash
                    )))
                }
                _ => {}
            }
        }
    }
    Ok(())
}

/// Concatenate the batches' records, writing a `Gap` for every hole.
fn merge_with_gaps(
    batches: &[Batch],
    dropped: &[(u64, u64)],
    refused: &BTreeSet<u64>,
) -> Result<Vec<Record>, AssembleError> {
    let present: BTreeSet<u64> = batches.iter().map(|b| b.envelope.batch_seq).collect();
    let mut out = Vec::new();
    let mut next_seq = 1u64;
    // The batch that carried the last seq-bearing record (None before any).
    let mut last_seq_batch: Option<u64> = None;
    for b in batches {
        let batch_seq = b.envelope.batch_seq;
        for (_, record) in &b.records {
            // The first seq this record says is not missing: its own `seq`,
            // or for `End` the one after `End.last_seq`, which counts the
            // stream's trailing seqs (spec §5.3 rule 3). A hole before `End`
            // (the ring overflowing just before `pagehide`, or the batch
            // before a final batch that carries only `End` never arriving)
            // is a hole like any other.
            let upto = match record {
                Record::End { last_seq, .. } => Some(last_seq.saturating_add(1)),
                other => other.seq(),
            };
            if let Some(upto) = upto.filter(|&upto| upto > next_seq) {
                // The batch_seqs absent between the batch that carried the
                // previous seq (or the first batch) and this one. A hole
                // inside one batch has none.
                let lower = last_seq_batch.unwrap_or(batches[0].envelope.batch_seq);
                let missing: Vec<u64> = (lower.saturating_add(1)..batch_seq)
                    .filter(|n| !present.contains(n))
                    .collect();
                for (first_seq, last_seq, covered) in split_by_cover(next_seq, upto - 1, dropped) {
                    let reason = if covered {
                        gap_reason::CLIENT_RING_OVERFLOW
                    } else if missing.is_empty() {
                        return Err(AssembleError::UnexplainedGap {
                            first_seq,
                            last_seq,
                        });
                    } else if missing.iter().all(|n| refused.contains(n)) {
                        gap_reason::BATCH_REFUSED
                    } else {
                        gap_reason::BATCH_NEVER_ARRIVED
                    };
                    out.push(Record::Gap {
                        first_seq,
                        last_seq,
                        reason,
                    });
                }
            }
            if let Some(seq) = record.seq() {
                if dropped.iter().any(|&(a, z)| (a..=z).contains(&seq)) {
                    return Err(AssembleError::DroppedOverlapsRecords(format!(
                        "seq {seq} is declared dropped, but batch {batch_seq} carries it"
                    )));
                }
                // A seq at or below the last one is left for the strict
                // decoder to refuse by name (SeqDiscontinuity).
                next_seq = next_seq.max(seq.saturating_add(1));
                last_seq_batch = Some(batch_seq);
            }
            out.push(record.clone());
        }
    }
    Ok(out)
}

/// Move inline bodies over 1024 bytes into `jsbound.blb` (§5.4), and resolve
/// every reference a recorder sent against the bodies moved before it.
fn move_large_bodies(mut records: Vec<Record>) -> Result<(Vec<Record>, BlobStore), AssembleError> {
    let mut blobs = BlobStore::new();
    let mut seen: BTreeMap<[u8; 32], u64> = BTreeMap::new();
    for record in &mut records {
        let kind = record.kind_name();
        let Some(blob) = record.blob_mut() else {
            continue;
        };
        match blob {
            BlobRef::Inline(bytes) if bytes.len() > MAX_INLINE_BLOB => {
                let len = bytes.len() as u64;
                let sha256 = blobs.insert(std::mem::take(bytes));
                seen.insert(sha256, len);
                *blob = BlobRef::Ref { sha256, len };
            }
            BlobRef::Inline(_) => {}
            BlobRef::Ref { sha256, len } => {
                if seen.get(sha256) != Some(len) {
                    return Err(AssembleError::Container(ContainerError::MissingBlob(
                        format!(
                        "{kind} references body {} ({len} bytes), which no earlier record carried",
                        crate::record::hex(sha256)
                    ),
                    )));
                }
            }
        }
    }
    Ok((records, blobs))
}

/// Append the `End` the finalisation calls for, or refuse a stream without
/// one.
fn terminate(
    mut records: Vec<Record>,
    finalisation: Finalisation,
) -> Result<Vec<Record>, AssembleError> {
    if records.iter().any(|r| matches!(r, Record::End { .. })) {
        return Ok(records);
    }
    let reason = match finalisation {
        Finalisation::Ended => return Err(AssembleError::Unterminated),
        Finalisation::Idle => end_reason::IDLE_FINALISATION,
        Finalisation::SessionCap => end_reason::SESSION_CAP,
    };
    let last_seq = records
        .iter()
        .rev()
        .find_map(|r| match r {
            Record::Gap { last_seq, .. } => Some(*last_seq),
            other => other.seq(),
        })
        .unwrap_or(0);
    records.push(Record::End { last_seq, reason });
    Ok(records)
}
