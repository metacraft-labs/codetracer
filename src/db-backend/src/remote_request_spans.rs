//! RS-M11 — the live HTTP Request panel over a container that is *somewhere
//! else*, read with HTTP byte-range requests.
//!
//! Spec: `codetracer-specs/Trace-Files/CTFS-Request-Span-Streams.md`
//! §"Streaming and Remote Access"; milestone RS-M11 in
//! `codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org`.
//!
//! # The claim this module exists to test
//!
//! The spec states it plainly: *"a remote live request panel needs no new
//! protocol. It is the existing `.ct` range reader pointed at a growing file."*
//! That is the whole justification for having moved request spans off the
//! `session_manifest.jsonl` / `codetracer_spans.jsonl` sidecars and into the
//! container — a sidecar would need its own transport, its own consistency
//! rules and its own partial-transfer semantics.
//!
//! This module is what the claim costs, stated precisely. There is **no new
//! wire protocol**: the payload is [`RequestSpanDelta`], byte-identical to what
//! the local [`RequestSpanTail`](crate::request_spans::RequestSpanTail)
//! serialises, so the frontend's ViewModel cannot tell a remote session from a
//! local one and needs no code for the difference.  What *is* new is one poll
//! loop, because the two things a local tail gets from the filesystem for free
//! — "did it change?" and "give me these bytes" — are a network round trip
//! each when the container is remote.
//!
//! ## Three things that are NOT the same as the local tail
//!
//! 1. **`Content-Length` is not a growth signal.** A `.ct` is block-padded, so
//!    a container routinely gains a whole span chunk without gaining a single
//!    byte of length. All four RS-M3 tail-stage fixtures are exactly 155 648
//!    bytes while their `spans.idx` grows 40 → 56 → 88 → 136. The local tail
//!    has `mtime` to fall back on; HTTP has no equivalent that a plain object
//!    store is guaranteed to update. The growth signal here is therefore the
//!    container's own Block 0 directory — `spans.idx`'s committed
//!    `FileEntry.Size` — which is the authority the format defines
//!    (CTFS-Binary-Format.md §6) and which no transport can lose.
//!
//! 2. **Re-opening is not free.** The local tail may re-open a container per
//!    poll because `CtfsReader::open` is a page-cache read. Doing that remotely
//!    would re-download `spans.dat` every poll. So this tail holds ONE
//!    [`CtfsReader`] over ONE [`HttpRangeSource`] for the whole session, calls
//!    [`CtfsReader::refresh`] to re-observe the directory, and range-reads only
//!    the `spans.dat` bytes of the chunks it has not already decoded
//!    ([`CtfsReader::read_file_range_available`] +
//!    [`SpanStreamReader::from_partial_files`]).
//!
//! 3. **A short read is ordinary, not exceptional.** A local reader either sees
//!    a byte or the file does not have it. A remote reader is looking at a file
//!    someone else is still writing or still uploading, so "the directory
//!    promises 2082 bytes of `spans.dat` and 1600 have landed" is the normal
//!    steady state, not damage. The append-only stream makes that answerable:
//!    the reader decodes whole chunks and stops at the first one whose bytes
//!    have not all arrived. See "Fail-closed" below.
//!
//! # Fail-closed: what a torn transfer may and may not do
//!
//! Two failure shapes have to be told apart, and conflating them is the bug
//! this design is built to avoid:
//!
//! | Shape                                     | Meaning                    | Behaviour                                   |
//! | ----------------------------------------- | -------------------------- | ------------------------------------------- |
//! | A chunk's bytes have not all arrived      | The prefix is valid; wait  | Stop at the previous chunk; cursor does not advance past it |
//! | A chunk's bytes are all there but bad     | The container is damaged   | Hard error; NO spans from that poll         |
//!
//! In neither case is a partial span ever produced. Availability is decided
//! byte-wise by [`SpanStreamReader::chunk_is_resident`] before any decode;
//! content is decided by the ordinary fail-closed record decoder, which rejects
//! truncated fields and trailing bytes rather than repairing them. A record
//! that straddles the truncation point is inside a chunk that is not resident,
//! so it is never decoded at all.
//!
//! Because the cursor advances only over chunks that decoded cleanly, and
//! because the CLIENT owns the cursor (it is an argument to [`poll`](
//! RemoteRequestSpanTail::poll), not tail state), a failed poll costs nothing:
//! the next poll with the same cursor returns the same delta. That is what
//! makes "the server stopped mid-request" a latency event rather than a
//! correctness one.

use std::path::Path;
use std::time::Duration;

use crate::ctfs_trace_reader::ctfs_container::{BlockSource, CtfsReader};
#[cfg(not(target_arch = "wasm32"))]
use crate::ctfs_trace_reader::http_range_source::HttpRangeSource;
use crate::ctfs_trace_reader::span_stream::{
    SPAN_TYPE_WEB_REQUEST, SPANS_DATA_FILE_NAME, SPANS_INDEX_ENTRY_SIZE, SPANS_INDEX_FILE_NAME,
    SPANS_INDEX_HEADER_SIZE, SpanStreamReader, resolve_spans,
};
use crate::request_spans::{RequestSpanDelta, RequestSpanSource, to_request_record};

/// The container's terminal metadata file, which carries the recording id and
/// the feature-bit word that gates the span stream.
const META_DAT_FILE_NAME: &str = "meta.dat";

// ── Poll / backoff policy ───────────────────────────────────────────────

/// The bounded poll schedule a remote live panel runs on.
///
/// # Why a policy object rather than a `sleep` in a loop
///
/// An unbounded tight poll against a remote object store is a defect: it costs
/// the operator money and the server capacity, it is invisible in local testing
/// (where a poll is a `stat`), and nothing in the reader itself pushes back on
/// it. Making the schedule an explicit, testable value is what stops "poll
/// until something happens" from being written five times with five different
/// constants.
///
/// # The schedule
///
/// ```text
///                 idle polls ->   0     1     2     3     4     5+
///   delay before next poll:     250ms  500ms 1s    2s    4s    5s (cap)
///   after a delta with spans:   back to 250ms
///   after an error:             1s, 2s, 4s, 8s, 16s, 30s (cap)
/// ```
///
/// # Why these numbers
///
/// * **250 ms floor.** A live panel's job is to make a request appear "as it
///   happens"; a quarter second is at the edge of what reads as immediate, and
///   halving it would double the request rate to buy latency nobody can see.
///   It is a floor and not merely a default: no code path may poll faster.
/// * **×2 growth.** The cheapest schedule that reaches the cap in a handful of
///   polls without a tuning table. Five idle polls (≈7.75 s of quiet) is a
///   server that is genuinely idle rather than between two requests.
/// * **5 s idle cap.** Bounds two things at once: the worst-case latency of the
///   first request after a quiet period (≤5 s, still clearly "live"), and the
///   steady-state cost of an idle panel — 12 polls/minute, and an idle poll is
///   two small requests (a `HEAD` and one 744-byte directory read), so an idle
///   session costs well under 1 KB/s. Leaving it uncapped would be the
///   defect in the other direction: a panel that stops noticing.
/// * **1 s error floor, 30 s error cap.** A failing server must be retried more
///   gently than a quiet one — the failure may *be* the load. 30 s bounds the
///   reconnect delay to something a user will sit through without reloading.
/// * **Errors are never fatal.** There is no give-up count, deliberately: the
///   container may be mid-upload, and abandoning the session would lose a
///   recording the user is watching. What is bounded is the *rate*, which is
///   the thing that can do harm. [`Self::consecutive_errors`] is exposed so a
///   UI can say "reconnecting" instead of pretending all is well.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RemotePollPolicy {
    /// Consecutive polls that returned no new spans.
    idle_polls: u32,
    /// Consecutive polls that failed.
    consecutive_errors: u32,
}

impl RemotePollPolicy {
    /// Fastest a remote container is ever polled.
    pub const MIN_INTERVAL: Duration = Duration::from_millis(250);
    /// Slowest an idle-but-healthy session is polled.
    pub const MAX_INTERVAL: Duration = Duration::from_secs(5);
    /// First retry delay after a failed poll.
    pub const ERROR_MIN_INTERVAL: Duration = Duration::from_secs(1);
    /// Slowest a failing session is retried.
    pub const ERROR_MAX_INTERVAL: Duration = Duration::from_secs(30);
    /// Multiplier applied per consecutive idle poll / per consecutive error.
    pub const BACKOFF_FACTOR: u32 = 2;

    pub fn new() -> RemotePollPolicy {
        RemotePollPolicy {
            idle_polls: 0,
            consecutive_errors: 0,
        }
    }

    /// Exponential backoff from `floor`, doubled `steps` times, clamped to
    /// `cap`. Saturating throughout, so a session left running for a week
    /// cannot overflow its way back to a tight loop.
    fn backoff(floor: Duration, cap: Duration, steps: u32) -> Duration {
        let factor = RemotePollPolicy::BACKOFF_FACTOR.saturating_pow(steps.min(24));
        floor.saturating_mul(factor).min(cap)
    }

    /// How long to wait before the next poll.
    ///
    /// The error schedule wins while errors are outstanding: a server that is
    /// failing must not be hammered just because the panel is also idle.
    pub fn next_delay(&self) -> Duration {
        if self.consecutive_errors > 0 {
            return RemotePollPolicy::backoff(
                RemotePollPolicy::ERROR_MIN_INTERVAL,
                RemotePollPolicy::ERROR_MAX_INTERVAL,
                self.consecutive_errors - 1,
            );
        }
        RemotePollPolicy::backoff(
            RemotePollPolicy::MIN_INTERVAL,
            RemotePollPolicy::MAX_INTERVAL,
            self.idle_polls,
        )
    }

    /// Record a successful poll. Any span at all resets the schedule to the
    /// floor: a session that just served a request is very likely about to
    /// serve another.
    pub fn record_delta(&mut self, span_count: usize) {
        self.consecutive_errors = 0;
        if span_count > 0 {
            self.idle_polls = 0;
        } else {
            self.idle_polls = self.idle_polls.saturating_add(1);
        }
    }

    /// Record a failed poll.
    pub fn record_error(&mut self) {
        self.consecutive_errors = self.consecutive_errors.saturating_add(1);
    }

    /// Consecutive failed polls — `0` when healthy. A UI surfaces this as
    /// "reconnecting"; nothing in the schedule ever gives up.
    pub fn consecutive_errors(&self) -> u32 {
        self.consecutive_errors
    }

    /// Consecutive polls that carried no new spans.
    pub fn idle_polls(&self) -> u32 {
        self.idle_polls
    }
}

impl Default for RemotePollPolicy {
    fn default() -> Self {
        RemotePollPolicy::new()
    }
}

// ── The remote tail ─────────────────────────────────────────────────────

/// What one poll observed about the remote container's span stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RemotePollStats {
    /// Chunks whose bytes were all present and which were decoded this poll.
    pub chunks_decoded: usize,
    /// `true` when the poll stopped early because a chunk the index announces
    /// has not (yet) fully landed. Ordinary while a container is being written
    /// or uploaded; the committed prefix is still served.
    pub stopped_at_uncommitted_chunk: bool,
    /// `spans.idx` bytes the directory declares.
    pub index_declared_bytes: u64,
    /// `spans.dat` bytes the directory declares.
    pub data_declared_bytes: u64,
    /// `spans.dat` bytes this poll actually asked the transport for.
    pub data_bytes_requested: u64,
}

/// A live tail over one recording's request spans, read over HTTP byte ranges.
///
/// Holds the container open for the whole session; see the module comment for
/// why re-opening per poll is the wrong shape remotely. The delta it produces
/// is the same [`RequestSpanDelta`] the local tail produces — that identity is
/// the milestone's central claim and is asserted directly in
/// `tests/remote_span_tail_http_test.rs`.
#[derive(Debug)]
pub struct RemoteRequestSpanTail {
    ctfs: CtfsReader,
    /// `meta.dat`'s UUIDv7 recording id, re-read whenever the directory moves.
    /// A container REPLACED at the same URL — the recorder re-published the
    /// session, or a rename swapped the file under us — is a different cursor
    /// space, so noticing it is what stops a stale cursor from being applied to
    /// unrelated chunks.
    recording_id: String,
    /// Fingerprint of the last Block 0 directory this tail parsed. Two polls
    /// with the same fingerprint cannot differ in any committed byte, so the
    /// second one does no further work.
    directory_stamp: Option<DirectoryStamp>,
    /// The next delta must be a full snapshot.
    reset_pending: bool,
    policy: RemotePollPolicy,
    last_stats: RemotePollStats,
}

/// The committed sizes of the three files a span tail depends on.
///
/// This is the remote equivalent of the local tail's `(len, mtime)` stamp, and
/// it is strictly better information: it is the writer's own published record
/// of what it has committed, rather than an inference from the file's physical
/// size. It cannot false-negative on a block-padded append, which is exactly
/// where `Content-Length` does.
///
/// `meta.dat` is in the stamp so that the recording id is re-read only when it
/// *could* have moved: a container replaced wholesale by a different recording
/// changes `meta.dat`'s size or one of the stream sizes in all but a
/// pathological coincidence. That is the same bet the local tail makes with
/// `(len, mtime)`, made against better evidence. Note the stamp does NOT decide
/// whether a span stream exists — that is answered structurally by the presence
/// of a `spans.dat` directory entry, never by `meta.dat`'s bit-13 hint.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct DirectoryStamp {
    meta_size: u64,
    index_size: u64,
    data_size: u64,
}

impl RemoteRequestSpanTail {
    /// Open a tail over a `.ct` served at `url` by any RFC 7233 range-capable
    /// server (S3, R2, nginx, a CI artifact host).
    ///
    /// Costs one `HEAD` plus one 16-byte header range request plus one
    /// directory read; nothing of `spans.dat` is fetched until the first poll
    /// that has new chunks to read.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn open(url: &str) -> Result<RemoteRequestSpanTail, String> {
        let source = HttpRangeSource::open(url).map_err(|e| format!("failed to open {url}: {e}"))?;
        RemoteRequestSpanTail::open_source(Box::new(source))
    }

    /// Open a tail over an arbitrary [`BlockSource`].
    ///
    /// The transport is a parameter rather than a hard-coded `ureq` call for
    /// the same reason the rest of the CTFS reader takes a `BlockSource`: the
    /// poll logic is about committed prefixes, not about sockets. The
    /// mutation control in `tests/remote_span_tail_http_test.rs` uses this seam
    /// to run the identical loop over a deliberately non-lazy source and show
    /// the range assertions fail for it.
    pub fn open_source(source: Box<dyn BlockSource>) -> Result<RemoteRequestSpanTail, String> {
        let ctfs = CtfsReader::from_source(source).map_err(|e| format!("failed to open remote container: {e}"))?;
        Ok(RemoteRequestSpanTail {
            ctfs,
            recording_id: String::new(),
            directory_stamp: None,
            // The first delta a client ever receives is by definition the whole
            // settled set, so it is flagged as a snapshot.
            reset_pending: true,
            policy: RemotePollPolicy::new(),
            last_stats: RemotePollStats::default(),
        })
    }

    /// The session's poll schedule. Drive the loop from
    /// [`RemotePollPolicy::next_delay`] after every poll.
    pub fn policy(&self) -> &RemotePollPolicy {
        &self.policy
    }

    /// What the most recent poll observed. Diagnostics and test seam; no
    /// production path branches on it.
    pub fn last_stats(&self) -> RemotePollStats {
        self.last_stats
    }

    /// Return everything appended since `client_cursor`, as the panel's rows.
    ///
    /// `client_cursor` is the `cursor` from the client's previous delta — a
    /// chunk count, opaque to the client. `0` (or a cursor past the head) asks
    /// for a full snapshot.
    ///
    /// On `Err` the client keeps its cursor and retries after
    /// [`RemotePollPolicy::next_delay`]; nothing has been consumed.
    pub fn poll(&mut self, client_cursor: u64) -> Result<RequestSpanDelta, String> {
        match self.poll_inner(client_cursor) {
            Ok(delta) => {
                self.policy.record_delta(delta.spans.len());
                Ok(delta)
            }
            Err(e) => {
                self.policy.record_error();
                Err(e)
            }
        }
    }

    fn poll_inner(&mut self, client_cursor: u64) -> Result<RequestSpanDelta, String> {
        // Re-observe the remote resource: re-probe its length and re-parse
        // Block 0. This is the whole "did anything change?" question, and it is
        // answered by the container's own published directory rather than by
        // any HTTP-level metadata — see the module comment.
        self.ctfs
            .refresh()
            .map_err(|e| format!("failed to refresh remote container: {e}"))?;

        let stamp = DirectoryStamp {
            meta_size: self.ctfs.file_size(META_DAT_FILE_NAME).unwrap_or(0),
            index_size: self.ctfs.file_size(SPANS_INDEX_FILE_NAME).unwrap_or(0),
            data_size: self.ctfs.file_size(SPANS_DATA_FILE_NAME).unwrap_or(0),
        };

        // Span-stream PRESENCE is STRUCTURAL: a container carries a span stream
        // iff its Block 0 directory has a `spans.dat` entry — NEVER because
        // `meta.dat` set feature bit 13. That bit is a HINT a writer may only
        // stamp at close, so gating on it would refuse a span stream that
        // structurally exists in a still-recording or still-uploading container
        // (trace-format spec amendment: "Stream-presence flags are a hint, not a
        // gate"; `internal-files.md` + `ctfs-container.md` §6). This mirrors the
        // local readers (`SpanStreamReader::open_from_ctfs`,
        // `follow_stream_source.rs`), which answer existence by the presence of
        // the stream's own files and gate reading on the companion index's
        // structural validity.
        let data_present = self.ctfs.file_size(SPANS_DATA_FILE_NAME).is_some();

        // A recording swapped in at the same URL does not share a cursor space
        // with the one we were reading. The recording id comes from `meta.dat`,
        // but it is read PURELY to detect that swap — never to decide whether
        // spans exist — and a `meta.dat` that is absent or torn (the terminal
        // file a truncated upload loses first) simply yields no id, disabling
        // swap detection without ever blocking a readable span stream. Checked
        // only when the directory actually moved; an idle poll fetches nothing
        // but the directory itself.
        if self.directory_stamp != Some(stamp) {
            let recording_id = self.read_recording_id();
            if !self.recording_id.is_empty() && !recording_id.is_empty() && recording_id != self.recording_id {
                self.reset_pending = true;
            }
            if !recording_id.is_empty() {
                self.recording_id = recording_id;
            }
        }
        self.directory_stamp = Some(stamp);

        if !data_present {
            // No `spans.dat` entry: this container has no span stream (yet). A
            // live recorder writes the stream's files the first time it registers
            // a span, so this is a state a poll loop must be able to leave, not a
            // terminal answer.
            let reset = self.reset_pending;
            self.reset_pending = false;
            self.last_stats = RemotePollStats {
                index_declared_bytes: stamp.index_size,
                data_declared_bytes: stamp.data_size,
                ..RemotePollStats::default()
            };
            return Ok(RequestSpanDelta {
                spans: Vec::new(),
                cursor: 0,
                reset,
                source: "none".to_string(),
            });
        }

        // `spans.dat` is present, so the container HAS a span stream. Reading it
        // REQUIRES an intact committed `spans.idx`: a `spans.dat` whose companion
        // index is absent, truncated, or has an unreadable header is a torn
        // prefix that lost the very thing that bounds its chunks, and we REFUSE
        // (below, via `read_committed_index`) rather than invent span records
        // from raw `spans.dat` bytes. This is the anti-guessing invariant, now
        // anchored on STRUCTURAL INDEX-VALIDITY instead of the `meta.dat` bit.
        let index = self.read_committed_index(stamp.index_size)?;
        let head = index.chunk_count() as u64;

        let force_reset = self.reset_pending;
        let effective = if force_reset || client_cursor > head {
            0
        } else {
            client_cursor
        };
        let from = usize::try_from(effective).map_err(|_| format!("request-span cursor {effective} does not fit"))?;

        let (records, consumed, stats) = self.read_delta(&index, from, stamp)?;
        self.reset_pending = false;
        self.last_stats = stats;

        Ok(RequestSpanDelta {
            spans: resolve_spans(records)
                .iter()
                .filter(|s| s.span_type == SPAN_TYPE_WEB_REQUEST)
                // A remote container's external bindings name paths relative to
                // a directory that is not on this machine, so no external trace
                // can be resolved; `to_request_record` reports `None` for a
                // target that is not present, which is exactly right here.
                .map(|s| to_request_record(s, Path::new("")))
                .collect(),
            cursor: consumed as u64,
            reset: effective == 0,
            source: RequestSpanSource::SpanStream.as_str().to_string(),
        })
    }

    /// `meta.dat`'s UUIDv7 recording id, or `""` when it cannot be read.
    ///
    /// The id is used ONLY to notice a different recording published at the same
    /// URL (a swap invalidates the cursor space). It deliberately never gates
    /// span reading and never fails the poll: `meta.dat` is the terminal file a
    /// truncated upload loses first, and under the "hint, not a gate" model a
    /// torn or absent `meta.dat` must not stop a structurally-present,
    /// index-intact span stream from being read. A missing id merely disables
    /// swap detection until a readable `meta.dat` reappears.
    fn read_recording_id(&mut self) -> String {
        match self.ctfs.read_file(META_DAT_FILE_NAME) {
            Ok(bytes) => crate::ctfs_trace_reader::meta_dat::parse_meta_dat(&bytes)
                .map(|m| m.recording_id)
                .unwrap_or_default(),
            Err(_) => String::new(),
        }
    }

    /// Fetch the WHOLE committed `spans.idx` and validate it is intact, or REFUSE.
    ///
    /// This is the structural index-validity gate that anchors "refuse rather
    /// than guess" now that the `meta.dat` bit no longer decides span presence.
    /// The read is STRICT — every byte the directory declares for `spans.idx`
    /// must be backed — so a `spans.dat` that is present but whose companion
    /// index is absent, truncated, or header-unreadable fails the poll instead
    /// of yielding a shorter, guessed prefix. That mirrors the local readers,
    /// which require a fully-readable `<stream>.idx`
    /// ([`SpanStreamReader::open_from_ctfs`] reads it strictly;
    /// `follow_stream_source.rs` reads `[0, idx_size)` and errors on any byte not
    /// committed).
    ///
    /// The index is 16 bytes per chunk, so fetching it whole is a few hundred
    /// bytes even for a long session — there is nothing to be gained by
    /// range-reading *it*, and having the entire cumulative column in hand is
    /// what makes the `spans.dat` delta addressable in one range.
    ///
    /// The writer commits whole index entries, so a valid `declared` size is
    /// `header + k*entry`; the whole-entry trim below is a belt-and-braces guard
    /// that a trailing partial entry (half an entry names a chunk offset nobody
    /// wrote) can never reach the parser.
    fn read_committed_index(&mut self, declared: u64) -> Result<SpanIndex, String> {
        if declared < SPANS_INDEX_HEADER_SIZE as u64 {
            return Err(format!(
                "{SPANS_INDEX_FILE_NAME}: the committed index is not intact — declared size {declared} \
                 is below the {SPANS_INDEX_HEADER_SIZE}-byte header (a torn or absent index for a \
                 present {SPANS_DATA_FILE_NAME} — refusing rather than guessing spans)"
            ));
        }
        // STRICT read: unlike the tolerant `_available` variant, `read_file_range`
        // errors when any declared byte has not landed — which is exactly the
        // "index not intact -> refuse" gate. A `FileNotFound` here (a present
        // `spans.dat` with no `spans.idx` at all) is likewise a refusal.
        let bytes = self
            .ctfs
            .read_file_range(SPANS_INDEX_FILE_NAME, 0, declared)
            .map_err(|e| {
                format!("{SPANS_INDEX_FILE_NAME}: committed index is not intact-readable (refusing rather than guessing spans): {e}")
            })?;
        let whole_entries = (bytes.len() - SPANS_INDEX_HEADER_SIZE) / SPANS_INDEX_ENTRY_SIZE;
        let usable = SPANS_INDEX_HEADER_SIZE + whole_entries * SPANS_INDEX_ENTRY_SIZE;
        Ok(SpanIndex {
            bytes: bytes[..usable].to_vec(),
        })
    }

    /// Range-read and decode the chunks in `[from, head)` that have landed.
    ///
    /// Returns the raw records, the new cursor (chunks fully consumed), and
    /// what the poll cost.
    fn read_delta(
        &mut self,
        index: &SpanIndex,
        from: usize,
        stamp: DirectoryStamp,
    ) -> Result<
        (
            Vec<crate::ctfs_trace_reader::span_stream::SpanRecord>,
            usize,
            RemotePollStats,
        ),
        String,
    > {
        let head = index.chunk_count();
        let mut stats = RemotePollStats {
            index_declared_bytes: stamp.index_size,
            data_declared_bytes: stamp.data_size,
            ..RemotePollStats::default()
        };
        if from >= head {
            return Ok((Vec::new(), head, stats));
        }

        // THE range read: the delta's first byte to the last byte the writer
        // says it has committed, and nothing before it. Everything the tail
        // already decoded stays on the server.
        let base = index.offset(from)?;
        if base > stamp.data_size {
            return Err(format!(
                "{SPANS_INDEX_FILE_NAME}: chunk {from} starts at {base}, past the {} bytes \
                 {SPANS_DATA_FILE_NAME} declares",
                stamp.data_size
            ));
        }
        let want = stamp.data_size - base;
        stats.data_bytes_requested = want;
        let bytes = self
            .ctfs
            .read_file_range_available(SPANS_DATA_FILE_NAME, base, want)
            .map_err(|e| format!("failed to range-read {SPANS_DATA_FILE_NAME}: {e}"))?;

        // Did every byte the directory declares actually arrive? This is the
        // difference between "the writer sealed an empty chunk" and "we hold
        // none of this chunk's bytes", which the byte ranges alone cannot tell
        // apart — the last indexed chunk's range collapses to empty in BOTH
        // cases. Getting that wrong would advance the cursor over records the
        // client then never receives, which is the one way a fail-closed reader
        // can still lose data.
        let complete = bytes.len() as u64 == want;

        let mut reader = SpanStreamReader::from_partial_files(bytes, base, index.as_bytes())?;
        let mut records = Vec::new();
        let mut consumed = from;
        for chunk in from..head {
            // Availability first, always: a chunk whose bytes have not all
            // arrived is not decoded, so no record can straddle the end of
            // what we received.
            if !reader.chunk_is_resident(chunk) {
                stats.stopped_at_uncommitted_chunk = true;
                break;
            }
            // Resident bytes that do not decode are damage, and damage is a
            // hard error — never a silently shorter list.
            let decoded = reader.read_spans_in_chunks(chunk, chunk + 1)?;
            // The index says how many records this chunk holds. Decoding fewer
            // means one of two things, and they are not the same thing:
            let declared = reader.records_in_chunk(chunk);
            if decoded.len() as u64 != declared {
                if complete {
                    // Every declared byte is here and it still does not hold
                    // the declared records: the container disagrees with
                    // itself. Fail the poll rather than serve a short list.
                    return Err(format!(
                        "{SPANS_DATA_FILE_NAME}: chunk {chunk} decoded {} records but \
                         {SPANS_INDEX_FILE_NAME} declares {declared}",
                        decoded.len()
                    ));
                }
                // Bytes are still landing. Stop at the previous chunk; the
                // cursor does not move past this one, so a later poll re-reads
                // it in full.
                stats.stopped_at_uncommitted_chunk = true;
                break;
            }
            records.extend(decoded);
            consumed = chunk + 1;
            stats.chunks_decoded += 1;
        }
        Ok((records, consumed, stats))
    }
}

/// The committed part of `spans.idx`, held as raw wire bytes.
///
/// Kept as bytes rather than parsed into vectors because
/// [`SpanStreamReader::from_partial_files`] wants exactly these bytes and
/// re-validates them itself; parsing here would mean two decoders of one
/// format, which is how they drift.
#[derive(Debug, Clone)]
struct SpanIndex {
    bytes: Vec<u8>,
}

impl SpanIndex {
    fn as_bytes(&self) -> &[u8] {
        &self.bytes
    }

    fn chunk_count(&self) -> usize {
        (self.bytes.len() - SPANS_INDEX_HEADER_SIZE) / SPANS_INDEX_ENTRY_SIZE
    }

    /// Byte offset of chunk `i` in `spans.dat`, straight off the wire.
    fn offset(&self, i: usize) -> Result<u64, String> {
        let at = SPANS_INDEX_HEADER_SIZE + i * SPANS_INDEX_ENTRY_SIZE;
        let slice = self
            .bytes
            .get(at..at + 8)
            .ok_or_else(|| format!("{SPANS_INDEX_FILE_NAME}: no entry for chunk {i}"))?;
        let mut buf = [0u8; 8];
        buf.copy_from_slice(slice);
        Ok(u64::from_le_bytes(buf))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_idle_schedule_starts_at_the_floor_and_stops_at_the_cap() {
        let mut policy = RemotePollPolicy::new();
        assert_eq!(policy.next_delay(), RemotePollPolicy::MIN_INTERVAL);

        let mut seen = Vec::new();
        for _ in 0..10 {
            policy.record_delta(0);
            seen.push(policy.next_delay());
        }
        assert_eq!(
            seen,
            vec![
                Duration::from_millis(500),
                Duration::from_secs(1),
                Duration::from_secs(2),
                Duration::from_secs(4),
                Duration::from_secs(5),
                Duration::from_secs(5),
                Duration::from_secs(5),
                Duration::from_secs(5),
                Duration::from_secs(5),
                Duration::from_secs(5),
            ]
        );
        // Every delay is inside the documented band.
        for d in seen {
            assert!(d >= RemotePollPolicy::MIN_INTERVAL);
            assert!(d <= RemotePollPolicy::MAX_INTERVAL);
        }
    }

    #[test]
    fn a_delta_with_spans_resets_the_schedule_to_the_floor() {
        let mut policy = RemotePollPolicy::new();
        for _ in 0..6 {
            policy.record_delta(0);
        }
        assert_eq!(policy.next_delay(), RemotePollPolicy::MAX_INTERVAL);
        policy.record_delta(1);
        assert_eq!(policy.next_delay(), RemotePollPolicy::MIN_INTERVAL);
        assert_eq!(policy.idle_polls(), 0);
    }

    #[test]
    fn the_error_schedule_is_bounded_and_outranks_the_idle_one() {
        let mut policy = RemotePollPolicy::new();
        // Idle for a while first, so the two schedules disagree.
        for _ in 0..3 {
            policy.record_delta(0);
        }
        policy.record_error();
        assert_eq!(policy.next_delay(), RemotePollPolicy::ERROR_MIN_INTERVAL);
        let mut seen = Vec::new();
        for _ in 0..8 {
            policy.record_error();
            seen.push(policy.next_delay());
        }
        assert_eq!(
            seen,
            vec![
                Duration::from_secs(2),
                Duration::from_secs(4),
                Duration::from_secs(8),
                Duration::from_secs(16),
                Duration::from_secs(30),
                Duration::from_secs(30),
                Duration::from_secs(30),
                Duration::from_secs(30),
            ]
        );
        assert_eq!(policy.consecutive_errors(), 9);
        // A success clears the error schedule outright.
        policy.record_delta(0);
        assert_eq!(policy.consecutive_errors(), 0);
        assert!(policy.next_delay() <= RemotePollPolicy::MAX_INTERVAL);
    }

    #[test]
    fn a_very_long_session_cannot_overflow_back_into_a_tight_loop() {
        let mut policy = RemotePollPolicy::new();
        for _ in 0..100_000 {
            policy.record_delta(0);
        }
        assert_eq!(policy.next_delay(), RemotePollPolicy::MAX_INTERVAL);
        for _ in 0..100_000 {
            policy.record_error();
        }
        assert_eq!(policy.next_delay(), RemotePollPolicy::ERROR_MAX_INTERVAL);
    }
}
