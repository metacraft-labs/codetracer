//! RS-M11 — the live HTTP Request panel over a container served remotely, and
//! read with real HTTP byte-range requests.
//!
//! Spec: `codetracer-specs/Trace-Files/CTFS-Request-Span-Streams.md`
//! §"Streaming and Remote Access"; milestone RS-M11 in
//! `codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org`.
//!
//! # What the milestone claims, and what these tests do about it
//!
//! The spec says a remote live request panel "needs no new protocol. It is the
//! existing `.ct` range reader pointed at a growing file." That is a claim with
//! two halves, and both are checkable:
//!
//! * **No new protocol** — [`remote_live_panel_over_http_range`] runs the local
//!   tail and the remote tail over the SAME four container stages in lockstep
//!   and asserts their serialised `RequestSpanDelta` payloads are BYTE-IDENTICAL
//!   at every step. The panel's ViewModel therefore cannot tell the two apart,
//!   which is what "no new protocol" has to mean if it means anything.
//! * **Range reader, not downloader** — the same test asserts, from the
//!   SERVER's own byte counter, that four live polls over a 155 648-byte
//!   container moved less than one copy of it, and that every single response
//!   was a `206 Partial Content`. A reader that quietly downloaded the file
//!   would still produce the right spans, so the budget is the only thing that
//!   can catch it — which is why
//!   [`the_range_budget_is_falsifiable_a_whole_file_reader_blows_it`] exists.
//!
//! # No mocks
//!
//! Nothing here is mocked, stubbed or faked.
//!
//! * The **containers** are the real Nim-writer fixtures committed under
//!   `tests/fixtures/span_stream/` (`web_session_tail_stage1..4.ct`), the same
//!   four growing snapshots RS-M3's `request_span_tail_test.rs` uses.
//! * The **server** is a real `std::net::TcpListener` speaking real HTTP/1.1
//!   with RFC 7233 range support over a real loopback socket. It is a fixture,
//!   not a mock: it has no knowledge of the reader, it answers bytes, and it is
//!   the thing whose counters the assertions are made against.
//! * The **reader** is production code end to end: `HttpRangeSource` →
//!   `CtfsReader` → `SpanStreamReader` → `RemoteRequestSpanTail`.
//! * The **ground truth** for every row is each stage's committed
//!   `.expected.jsonl`, written from the values fed to the writer rather than
//!   by re-reading the container, so a reader bug cannot make the expectations
//!   agree with themselves.
//!
//! # How a growing container is served
//!
//! `MultiStreamTraceWriter` cannot append in place — it builds in memory and
//! only `trace_writer_close()` writes bytes — so a live session is published as
//! successive WHOLE containers (RS-M4's `demo_request_session.nim` renames a
//! temp file over the session path). The fixtures are four such publications of
//! one session, each a strict chunk prefix of the next. The server here swaps
//! its served image the same way, which is also how it pins the behaviour a
//! rename demands of a range reader: the resource's bytes can be replaced
//! wholesale between two requests, and the reader must survive it.

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::thread;

use db_backend::ctfs_trace_reader::ctfs_container::{CtfsError, CtfsReader, InMemoryBlockSource, write_minimal_ctfs};
use db_backend::ctfs_trace_reader::http_range_source::{HttpRangeSource, RangeFetcher};
use db_backend::ctfs_trace_reader::span_stream::{SPAN_TYPE_WEB_REQUEST, SpanStreamReader};
use db_backend::remote_request_spans::{RemotePollPolicy, RemoteRequestSpanTail};
use db_backend::request_spans::{RequestRecord, RequestSpanTail, to_request_record};
use serde_json::Value;

// ── Fixtures ────────────────────────────────────────────────────────────

/// Chunk counts of the four tail stages, as the generator lays them out —
/// the same constant `request_span_tail_test.rs` documents and proves.
const STAGE_CHUNKS: [u64; 4] = [2, 3, 5, 8];

/// Every stage container is exactly this long: a `.ct` is block-padded, so the
/// file GAINS SPANS WITHOUT GAINING BYTES. Written down here because it is the
/// single most important fact about tailing a container over HTTP — it is why
/// `Content-Length` cannot be the growth signal and the Block 0 directory must
/// be.
const STAGE_IMAGE_BYTES: usize = 155_648;

/// Byte budget for a whole four-stage remote live session.
///
/// Deliberately expressed as a fraction of ONE container download rather than
/// as a tuned constant: the claim being defended is "a range reader moves less
/// than a downloader", and four polls of a growing file that a downloader would
/// pay 4 x 155 648 = 622 592 bytes for must cost less than a single copy. The
/// measured cost is far below this (see the assertion's message), so the
/// headroom absorbs block-size and fixture changes without the test becoming a
/// change detector.
const RANGE_BUDGET_BYTES: u64 = STAGE_IMAGE_BYTES as u64;

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/span_stream")
}

fn stage_image(stage: usize) -> Vec<u8> {
    let path = fixture_dir().join(format!("web_session_tail_stage{stage}.ct"));
    std::fs::read(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// One request row as the GENERATOR declared it.
#[derive(Debug, Clone, PartialEq, Eq)]
struct ExpectedRequest {
    url: String,
    status_code: i64,
    is_open: bool,
}

/// The `(span_id -> row)` the GENERATOR declared for a stage's web requests.
///
/// Ground truth that was written from the values fed to the writer, never by
/// re-reading the container, so a reader bug cannot make the expectations agree
/// with themselves.
fn expected_requests(stage: usize) -> BTreeMap<u64, ExpectedRequest> {
    let path = fixture_dir().join(format!("web_session_tail_stage{stage}.expected.jsonl"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    text.lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|line| {
            let v: Value = serde_json::from_str(line).expect("expected fixture line is JSON");
            if v["span_type"].as_str().unwrap_or("") != SPAN_TYPE_WEB_REQUEST {
                return None;
            }
            let meta = &v["metadata"];
            Some((
                v["span_id"].as_u64().expect("span_id"),
                ExpectedRequest {
                    url: meta["http.url"].as_str().unwrap_or("").to_string(),
                    // The format carries every metadata value as a string.
                    status_code: meta["http.status_code"].as_str().unwrap_or("0").parse().unwrap_or(0),
                    is_open: v["is_open"].as_bool().unwrap_or(false),
                },
            ))
        })
        .collect()
}

fn merge(into: &mut BTreeMap<u64, RequestRecord>, delta: &[RequestRecord]) {
    for r in delta {
        into.insert(r.id, r.clone());
    }
}

// ── A real range-serving HTTP/1.1 server whose image can be swapped ──────

/// What the server did, as the server saw it — the only accounting these tests
/// trust, because it cannot be satisfied by a client that merely *believes* it
/// issued ranges.
#[derive(Debug, Default)]
struct ServerLog {
    /// Total response-body bytes written.
    served_bytes: AtomicU64,
    /// `206 Partial Content` responses (i.e. genuine range responses).
    partial_responses: AtomicUsize,
    /// `200 OK` GET responses carrying a whole body — the failure mode.
    full_body_responses: AtomicUsize,
    /// `HEAD` responses.
    head_responses: AtomicUsize,
    /// Every request target the server was ever asked for, in order.
    paths: Mutex<Vec<String>>,
}

/// How the server should behave for the NEXT request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Fault {
    None,
    /// Answer a well-formed `206` header and then close the connection after
    /// writing only half of the promised body — a server that stops
    /// mid-request.
    TruncateBody,
}

struct RangeServer {
    addr: std::net::SocketAddr,
    image: Arc<RwLock<Vec<u8>>>,
    fault: Arc<Mutex<Fault>>,
    log: Arc<ServerLog>,
    shutdown: Arc<AtomicBool>,
    handle: Option<thread::JoinHandle<()>>,
}

impl RangeServer {
    fn start(image: Vec<u8>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let addr = listener.local_addr().unwrap();
        let image = Arc::new(RwLock::new(image));
        let fault = Arc::new(Mutex::new(Fault::None));
        let log = Arc::new(ServerLog::default());
        let shutdown = Arc::new(AtomicBool::new(false));

        let t_image = Arc::clone(&image);
        let t_fault = Arc::clone(&fault);
        let t_log = Arc::clone(&log);
        let stop = Arc::clone(&shutdown);
        let handle = thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        let snapshot = t_image.read().unwrap().clone();
                        let fault = *t_fault.lock().unwrap();
                        let _ = handle_conn(stream, &snapshot, &t_log, fault);
                    }
                    Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(std::time::Duration::from_millis(2));
                    }
                    Err(_) => break,
                }
            }
        });

        RangeServer {
            addr,
            image,
            fault,
            log,
            shutdown,
            handle: Some(handle),
        }
    }

    fn url(&self) -> String {
        format!("http://{}/trace.ct", self.addr)
    }

    /// Publish a new whole container over the same URL — what a rename does.
    fn publish(&self, image: Vec<u8>) {
        *self.image.write().unwrap() = image;
    }

    fn set_fault(&self, fault: Fault) {
        *self.fault.lock().unwrap() = fault;
    }

    fn served_bytes(&self) -> u64 {
        self.log.served_bytes.load(Ordering::Relaxed)
    }

    fn partial_responses(&self) -> usize {
        self.log.partial_responses.load(Ordering::Relaxed)
    }

    fn full_body_responses(&self) -> usize {
        self.log.full_body_responses.load(Ordering::Relaxed)
    }

    fn distinct_paths(&self) -> Vec<String> {
        let mut v = self.log.paths.lock().unwrap().clone();
        v.sort();
        v.dedup();
        v
    }
}

impl Drop for RangeServer {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

/// Serve exactly one request/response. `ureq` opens a fresh connection per call
/// by default, so one request per connection is both sufficient and simple.
fn handle_conn(mut stream: TcpStream, image: &[u8], log: &ServerLog, fault: Fault) -> std::io::Result<()> {
    stream.set_read_timeout(Some(std::time::Duration::from_secs(5)))?;
    let mut buf = Vec::new();
    let mut tmp = [0u8; 1024];
    loop {
        let n = stream.read(&mut tmp)?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&tmp[..n]);
        if buf.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
        if buf.len() > 64 * 1024 {
            break;
        }
    }
    let req = String::from_utf8_lossy(&buf);
    let request_line = req.lines().next().unwrap_or("");
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("");
    log.paths.lock().unwrap().push(path.to_string());
    let total = image.len() as u64;

    if method == "HEAD" {
        log.head_responses.fetch_add(1, Ordering::Relaxed);
        let resp =
            format!("HTTP/1.1 200 OK\r\nContent-Length: {total}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n");
        stream.write_all(resp.as_bytes())?;
        return Ok(());
    }

    let range = req
        .lines()
        .find(|l| l.to_ascii_lowercase().starts_with("range:"))
        .and_then(|l| l.split_once(':').map(|x| x.1))
        .map(|v| v.trim().to_string());

    if let Some(range) = range {
        let spec = range.strip_prefix("bytes=").unwrap_or("");
        let (s, e) = spec.split_once('-').unwrap_or(("", ""));
        let start: u64 = s.trim().parse().unwrap_or(0);
        let end_inclusive: u64 = if e.trim().is_empty() {
            total - 1
        } else {
            e.trim().parse().unwrap_or(total - 1)
        };
        let end_inclusive = end_inclusive.min(total.saturating_sub(1));
        if start > end_inclusive {
            // RFC 7233 §4.4 — the client asked for bytes past the end.
            let resp = format!(
                "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{total}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            );
            stream.write_all(resp.as_bytes())?;
            return Ok(());
        }
        let slice = &image[start as usize..=end_inclusive as usize];
        log.partial_responses.fetch_add(1, Ordering::Relaxed);
        let header = format!(
            "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nConnection: close\r\n\r\n",
            slice.len(),
            start,
            end_inclusive,
            total
        );
        stream.write_all(header.as_bytes())?;
        let body: &[u8] = match fault {
            // Promise the full slice, deliver half, hang up. This is what an
            // interrupted server actually looks like to a client: a valid
            // header and a short body.
            Fault::TruncateBody => &slice[..slice.len() / 2],
            Fault::None => slice,
        };
        log.served_bytes.fetch_add(body.len() as u64, Ordering::Relaxed);
        stream.write_all(body)?;
        return Ok(());
    }

    // No Range header: the whole body. Nothing in the range path should ever
    // land here — that is what `full_body_responses` is counted for.
    log.full_body_responses.fetch_add(1, Ordering::Relaxed);
    log.served_bytes.fetch_add(total, Ordering::Relaxed);
    let header = format!("HTTP/1.1 200 OK\r\nContent-Length: {total}\r\nConnection: close\r\n\r\n");
    stream.write_all(header.as_bytes())?;
    stream.write_all(image)?;
    Ok(())
}

// ── The required test: a remote live panel over HTTP range requests ─────

/// **`remote_live_panel_over_http_range`**
///
/// Serve a growing container over HTTP with range support, drive a real
/// server's requests, and assert the panel observes each request remotely with
/// no sidecar transferred.
///
/// The assertions, in the order they matter:
///
/// 1. Every stage's requests appear in the merged row set, matching the
///    generator's ground truth.
/// 2. The remote delta payload is BYTE-IDENTICAL to the local tail's at every
///    step — the "no new protocol" claim, stated as an equality.
/// 3. The server issued only `206` responses and never a whole body.
/// 4. The whole four-stage session moved fewer bytes than ONE copy of the
///    container.
/// 5. The only resource the wire ever carried was the `.ct` itself — no
///    sidecar, because there is no sidecar to carry.
#[test]
fn remote_live_panel_over_http_range() {
    // The local reference tail, over a real file on a real filesystem.
    let dir = tempfile::tempdir().unwrap();
    let local_path = dir.path().join("session.ct");
    let publish_local = |stage: usize| {
        // Write via a temp file + rename, exactly as `demo_request_session.nim`
        // publishes a stage, then stamp a strictly-increasing mtime: the
        // container is block-padded, so mtime is the only change signal the
        // LOCAL tail has (the remote one uses the Block 0 directory instead).
        let tmp = dir.path().join("session.ct.tmp");
        std::fs::write(&tmp, stage_image(stage)).unwrap();
        std::fs::rename(&tmp, &local_path).unwrap();
        let when = filetime::FileTime::from_unix_time(1_800_000_000 + stage as i64 * 10, 0);
        filetime::set_file_mtime(&local_path, when).unwrap();
    };
    publish_local(1);
    let mut local_tail = RequestSpanTail::new(&local_path);

    // The remote tail, over a real socket.
    let server = RangeServer::start(stage_image(1));
    let mut remote_tail = RemoteRequestSpanTail::open(&server.url()).expect("open the remote tail over HTTP");

    let mut merged: BTreeMap<u64, RequestRecord> = BTreeMap::new();
    let mut cursor = 0u64;
    let mut local_cursor = 0u64;
    let mut per_poll_data_bytes = Vec::new();
    let mut observed_deltas: Vec<Value> = Vec::new();

    for stage in 1..=4usize {
        if stage > 1 {
            publish_local(stage);
            server.publish(stage_image(stage));
        }

        let local = local_tail.poll(local_cursor).expect("local poll");
        let remote = remote_tail.poll(cursor).expect("remote poll");

        // (2) The claim: identical wire payloads. Compared as serialised JSON
        // because that — not the Rust struct — is what crosses to the panel.
        assert_eq!(
            serde_json::to_value(&remote).unwrap(),
            serde_json::to_value(&local).unwrap(),
            "stage {stage}: the remote delta must be byte-identical to the local one; \
             a difference here IS a new protocol"
        );

        assert_eq!(
            remote.cursor,
            STAGE_CHUNKS[stage - 1],
            "stage {stage}: the cursor is the container's chunk count"
        );
        assert_eq!(remote.source, "span-stream");
        assert_eq!(
            remote.reset,
            stage == 1,
            "stage {stage}: only the first delta is a snapshot; a growing container never re-snapshots"
        );

        merge(&mut merged, &remote.spans);
        cursor = remote.cursor;
        local_cursor = local.cursor;
        per_poll_data_bytes.push(remote_tail.last_stats().data_bytes_requested);
        observed_deltas.push(serde_json::to_value(&remote).unwrap());

        // (1) Every request the generator declared for this stage is visible.
        let expected = expected_requests(stage);
        assert_eq!(
            merged.keys().copied().collect::<Vec<_>>(),
            expected.keys().copied().collect::<Vec<_>>(),
            "stage {stage}: the remote panel must observe exactly the requests recorded so far"
        );
        for (id, want) in &expected {
            let got = &merged[id];
            assert_eq!(&got.url, &want.url, "stage {stage}: url of span {id}");
            assert_eq!(got.status_code, want.status_code, "stage {stage}: status of span {id}");
            assert_eq!(got.is_open, want.is_open, "stage {stage}: in-flight state of span {id}");
        }
    }

    // (3) Every byte came back through a range response.
    assert!(
        server.partial_responses() > 0,
        "the reader must actually issue range requests"
    );
    assert_eq!(
        server.full_body_responses(),
        0,
        "a whole-body response means the reader stopped using ranges"
    );

    // (4) The budget. This is the assertion the mutation control falsifies.
    let served = server.served_bytes();
    assert!(
        served < RANGE_BUDGET_BYTES,
        "a four-stage remote live session served {served} bytes; the budget is \
         {RANGE_BUDGET_BYTES} (ONE container), and a downloading reader would have \
         moved {} for the same result",
        4 * STAGE_IMAGE_BYTES
    );

    // Each poll's `spans.dat` read is bounded by the delta, not by the stream:
    // no poll asks for more than the container's whole span data, and the later
    // polls ask for strictly less than a naive re-read would.
    for (i, bytes) in per_poll_data_bytes.iter().enumerate() {
        assert!(
            *bytes < 4096,
            "poll {i} asked for {bytes} bytes of spans.dat — a delta read must stay small"
        );
    }

    // (5) No sidecar. The panel's entire input crossed the wire as ONE
    // artifact; nothing else was ever requested.
    assert_eq!(
        server.distinct_paths(),
        vec!["/trace.ct".to_string()],
        "the only resource transferred must be the container itself — no session_manifest.jsonl, \
         no codetracer_spans.jsonl, no second transport"
    );

    // (6) Hand the exact payloads to the panel's ViewModel test.
    check_or_regenerate_viewmodel_fixture(&observed_deltas);
}

/// Path of the delta capture the Nim ViewModel test replays.
fn viewmodel_fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../tests/gui/tests/request-panel/fixtures/remote_http_range/deltas.jsonl")
}

/// Keep the ViewModel fixture and the reader that produced it in lockstep.
///
/// The panel's ViewModel is Nim and the remote reader is Rust, so the wire
/// payload is the only place they meet. Capturing it here — and FAILING when the
/// capture drifts — means `remote_request_panel_vm_test.nim` is replaying what
/// the production remote tail actually emitted over a real socket, not a
/// hand-written approximation of it. Without this check the Nim fixture would
/// be a copy that silently rots; with it, any change to the remote payload
/// fails here first, with the regeneration command in the message.
fn check_or_regenerate_viewmodel_fixture(deltas: &[Value]) {
    let path = viewmodel_fixture_path();
    let mut text = String::new();
    for d in deltas {
        text.push_str(&serde_json::to_string(d).unwrap());
        text.push('\n');
    }

    if std::env::var("CT_REGENERATE_REMOTE_DELTA_FIXTURE").is_ok() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &text).unwrap();
        return;
    }

    let committed = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "missing ViewModel delta fixture {}: {e}\n\
             regenerate with: CT_REGENERATE_REMOTE_DELTA_FIXTURE=1 cargo test --test \
             remote_span_tail_http_test remote_live_panel_over_http_range",
            path.display()
        )
    });
    assert_eq!(
        text,
        committed,
        "the remote tail's wire payload no longer matches the capture \
         `remote_request_panel_vm_test.nim` replays ({}).\n\
         regenerate with: CT_REGENERATE_REMOTE_DELTA_FIXTURE=1 cargo test --test \
         remote_span_tail_http_test remote_live_panel_over_http_range",
        path.display()
    );
}

// ── The required test: a truncated container is a valid prefix ──────────

/// Repack a stage fixture's REAL stream bytes into a container that carries
/// `spans.dat` LAST.
///
/// # Why this exists, and why it is not a fake
///
/// The bytes are untouched: `meta.dat`, `spans.idx`, `spantype.ns` and
/// `spans.dat` are read out of the committed Nim-writer fixture with the
/// production reader and written back verbatim. Only the container's *block
/// layout* differs, and the reason it must is a finding rather than a
/// convenience — see
/// [`truncating_a_finalized_container_refuses_rather_than_guessing`], which
/// pins it: `trace_writer_close()` emits `meta.dat` LAST, so in a finalized
/// `.ct` the feature-bit word that gates the span stream sits in the container's
/// final data block. Truncate such a file anywhere and the first thing lost is
/// the declaration that there are spans at all, so no cut of it can ever
/// exercise the mid-chunk prefix rule.
///
/// The layout used here — declaration first, payload last — is the one a
/// streaming publisher wants for exactly this reason, and it is what makes the
/// "a truncated container is always a valid prefix" design goal reachable
/// instead of theoretical. Building it with the repo's own CTFS test writer is
/// the smallest change that lets the required assertion be made about real span
/// bytes.
fn repacked_stage(stage: usize) -> Vec<u8> {
    let mut src = CtfsReader::from_bytes(stage_image(stage)).unwrap();
    let meta = src.read_file("meta.dat").unwrap();
    let idx = src.read_file("spans.idx").unwrap();
    let ns = src.read_file("spantype.ns").unwrap();
    let dat = src.read_file("spans.dat").unwrap();

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("repacked.ct");
    write_minimal_ctfs(
        &path,
        &[
            ("meta.dat", &meta),
            ("spans.idx", &idx),
            ("spantype.ns", &ns),
            ("spans.dat", &dat),
        ],
    )
    .unwrap();
    std::fs::read(&path).unwrap()
}

/// Distinct span ids, ascending. The stream holds a record per *event* (an open
/// record and its completion are two), so the row count a panel shows is the
/// number of distinct ids, not the number of records.
fn distinct_ids(records: &[RequestRecord]) -> Vec<u64> {
    let mut ids: Vec<u64> = records.iter().map(|r| r.id).collect();
    ids.sort_unstable();
    ids.dedup();
    ids
}

/// For each chunk count `k`, the rows a correct reader must report after
/// consuming exactly `k` chunks of the intact container.
///
/// Computed from the WHOLE container with the ordinary reader, so it is
/// independent of everything the truncated path does. It turns "the prefix
/// looks plausible" into "the prefix is exactly the prefix the cursor claims",
/// which is the only form of the assertion that catches a reader that COUNTS a
/// chunk it did not actually deliver.
fn rows_after_each_chunk_count(image: &[u8]) -> Vec<Vec<RequestRecord>> {
    let mut ctfs = CtfsReader::from_bytes(image.to_vec()).unwrap();
    let mut reader = SpanStreamReader::open_from_ctfs(&mut ctfs).unwrap().unwrap();
    let chunks = reader.chunk_count();
    (0..=chunks)
        .map(|k| {
            let raw = reader.read_spans_in_chunks(0, k).unwrap();
            db_backend::ctfs_trace_reader::span_stream::resolve_spans(raw)
                .iter()
                .filter(|s| s.span_type == SPAN_TYPE_WEB_REQUEST)
                .map(|s| to_request_record(s, std::path::Path::new("")))
                .collect()
        })
        .collect()
}

/// Read every RAW span record of an intact container, projected to the panel's
/// row shape. Ground truth for "the reader never invented a span".
fn all_raw_records(image: &[u8]) -> Vec<RequestRecord> {
    let mut ctfs = CtfsReader::from_bytes(image.to_vec()).unwrap();
    let mut reader = SpanStreamReader::open_from_ctfs(&mut ctfs).unwrap().unwrap();
    reader
        .read_all_span_records()
        .unwrap()
        .iter()
        .filter(|s| s.span_type == SPAN_TYPE_WEB_REQUEST)
        .map(|s| to_request_record(s, std::path::Path::new("")))
        .collect()
}

/// **`truncated_container_opens_as_valid_prefix`**
///
/// Cut a container mid-chunk; assert the reader opens it, reports the spans in
/// the committed prefix, and fails closed on the partial chunk instead of
/// inventing a span.
///
/// # Why this is a sweep and not a single cut
///
/// A `.ct` interleaves its internal files across blocks, so "mid-chunk" is not
/// a byte offset the test can compute without duplicating the container's block
/// mapping — and a hand-picked offset would pin one layout rather than the
/// property. Sweeping every truncation length across the whole container asserts
/// the property that actually matters and that must hold at EVERY cut:
///
/// > A truncated container either fails to open / fails to read, or reports a
/// > PREFIX of the real span list in which every row is a record the real
/// > stream contains. It never yields a row the intact container does not have,
/// > and never a partial one.
///
/// The sweep then proves it is not vacuous: at least one cut yields a non-empty
/// PROPER prefix, i.e. the reader really does serve a partially-uploaded
/// container rather than merely refusing all of them.
#[test]
fn truncated_container_opens_as_valid_prefix() {
    let image = repacked_stage(4);
    let full = all_raw_records(&image);
    let full_ids = distinct_ids(&full);
    let rows_by_cursor = rows_after_each_chunk_count(&image);
    assert!(full_ids.len() >= 4, "the fixture must carry several requests");

    let mut proper_prefixes = Vec::new();
    let mut errors = 0usize;

    // Every byte offset in the container is a cut. `spans.dat` is a couple of
    // kilobytes inside a container of a few tens, so a coarse sweep would step
    // straight over the interesting region; at this size there is no reason not
    // to test all of them.
    let cuts: Vec<usize> = (16..image.len()).collect();

    for cut in cuts {
        let truncated = image[..cut].to_vec();
        let mut tail = match RemoteRequestSpanTail::open_source(Box::new(InMemoryBlockSource::new(truncated))) {
            Ok(t) => t,
            Err(_) => {
                // A cut that removes the header or the directory: refusing to
                // open is the correct, fail-closed answer.
                errors += 1;
                continue;
            }
        };
        let delta = match tail.poll(0) {
            Ok(d) => d,
            Err(_) => {
                errors += 1;
                continue;
            }
        };

        // The prefix property.
        let ids: Vec<u64> = delta.spans.iter().map(|r| r.id).collect();
        assert_eq!(
            ids,
            full_ids[..ids.len()].to_vec(),
            "cut at {cut}: a truncated container reported ids {ids:?}, which is not a prefix of {full_ids:?}"
        );
        // Nothing invented: every row is a record the intact stream carries.
        for row in &delta.spans {
            assert!(
                full.contains(row),
                "cut at {cut}: reported a row the intact container does not contain: {row:?}"
            );
        }
        // The cursor never claims more chunks than were decoded.
        assert!(
            delta.cursor <= STAGE_CHUNKS[3],
            "cut at {cut}: cursor {} exceeds the container's chunk count",
            delta.cursor
        );
        // THE cursor-integrity rule, and the reason a "valid prefix" is not
        // merely a shorter list: a chunk the reader COUNTS as consumed must be
        // a chunk whose records it actually delivered. A cursor that runs ahead
        // of the rows is data loss dressed up as a prefix — the client will
        // never ask for those chunks again.
        assert_eq!(
            delta.spans, rows_by_cursor[delta.cursor as usize],
            "cut at {cut}: the reader reported a cursor of {} chunks but rows that are not \
             exactly those {} chunks' rows",
            delta.cursor, delta.cursor
        );

        if !ids.is_empty() && ids.len() < full_ids.len() {
            proper_prefixes.push((cut, ids.len()));
        }
    }

    assert!(
        !proper_prefixes.is_empty(),
        "the sweep never produced a non-empty PROPER prefix, so the property above is vacuous: \
         either every cut failed closed, or every cut read the whole stream. \
         (cuts that errored: {errors})"
    );
    // The prefix lengths must actually vary with where the cut lands —
    // otherwise one accidental value would be satisfying the assertion above.
    let distinct: std::collections::BTreeSet<usize> = proper_prefixes.iter().map(|(_, n)| *n).collect();
    assert!(
        distinct.len() >= 2,
        "only one prefix length ({distinct:?}) ever appeared across {} partial cuts; \
         the reader is not tracking the committed boundary",
        proper_prefixes.len()
    );
}

/// The same property, over a real socket: a container whose UPLOAD was cut
/// short. Same reader, same fail-closed rule, but now the missing bytes are
/// missing from an HTTP resource rather than from a local buffer.
#[test]
fn a_truncated_upload_serves_its_committed_prefix_over_http() {
    let image = repacked_stage(4);
    let full = all_raw_records(&image);
    let full_rows = distinct_ids(&full).len();

    // Find a cut that lands mid-chunk — the reader's own answer is the oracle
    // for where that is, and the sweep above has already proved every such
    // answer is a valid prefix.
    let mut best: Option<(usize, usize)> = None;
    for cut in 16..image.len() {
        let mut tail =
            match RemoteRequestSpanTail::open_source(Box::new(InMemoryBlockSource::new(image[..cut].to_vec()))) {
                Ok(t) => t,
                Err(_) => continue,
            };
        if let Ok(d) = tail.poll(0)
            && !d.spans.is_empty()
            && d.spans.len() < full_rows
        {
            best = Some((cut, d.spans.len()));
            break;
        }
    }
    let (cut, expected_rows) = best.expect("the fixture must have a cut that yields a partial prefix");

    let server = RangeServer::start(image[..cut].to_vec());
    let mut tail = RemoteRequestSpanTail::open(&server.url()).expect("a valid prefix must OPEN cleanly");
    let delta = tail.poll(0).expect("a valid prefix must READ cleanly");

    assert_eq!(
        delta.spans.len(),
        expected_rows,
        "the truncated upload must serve exactly the rows its committed prefix carries"
    );
    assert!(
        delta.spans.len() < full_rows,
        "this cut is supposed to be partial: {} of {full_rows} rows",
        delta.spans.len()
    );
    for row in &delta.spans {
        assert!(
            full.contains(row),
            "a truncated upload produced a row the intact container does not contain: {row:?}"
        );
    }
    assert!(
        tail.last_stats().stopped_at_uncommitted_chunk,
        "the reader must report that it stopped at an uncommitted chunk rather than \
         silently presenting the prefix as the whole stream"
    );
    assert_eq!(server.full_body_responses(), 0);
}

/// **A finding, pinned.**
///
/// A container that `trace_writer_close()` finalized carries `meta.dat` in its
/// LAST data block, because that is the terminal metadata the writer emits
/// last. So the very first thing a truncated upload of a finalized `.ct` loses
/// is the feature-bit word that declares the span stream — long before it loses
/// any span bytes.
///
/// The append-only record format is still a valid prefix in the sense the spec
/// means; what is not recoverable is the *declaration* that the prefix is a
/// span stream at all. The reader must therefore refuse, and this test asserts
/// it refuses rather than guessing bit 13 from the presence of a `spans.dat`
/// entry — which would be the tempting and wrong repair, since a container may
/// carry a stream whose feature bits this build does not understand.
///
/// The consequence for anyone shipping this: to make a partially-uploaded
/// recording readable, publish the declaration BEFORE the payload (which is
/// what [`repacked_stage`] does and what a streaming publisher should do).
/// Until then, "a truncated upload is a valid prefix" holds for the span stream
/// and not for the container that wraps it.
#[test]
fn truncating_a_finalized_container_refuses_rather_than_guessing() {
    let image = stage_image(4);
    let full_rows = distinct_ids(&all_raw_records(&image)).len();

    let mut refused = 0usize;
    let mut complete = 0usize;
    let mut partial = 0usize;
    for cut in (16..image.len()).step_by(101) {
        let truncated = image[..cut].to_vec();
        match RemoteRequestSpanTail::open_source(Box::new(InMemoryBlockSource::new(truncated))) {
            Err(_) => refused += 1,
            Ok(mut tail) => match tail.poll(0) {
                Err(_) => refused += 1,
                Ok(d) if d.spans.is_empty() => {
                    // "This container declares no span stream" — also a refusal
                    // to invent, just a quieter one. This is the answer for
                    // every cut that lost `meta.dat`.
                    refused += 1;
                }
                Ok(d) if d.spans.len() == full_rows => complete += 1,
                Ok(_) => partial += 1,
            },
        }
    }

    assert!(refused > 0, "most cuts of a finalized container must be refused");
    assert!(
        complete > 0,
        "cuts that only remove the container's trailing block padding lose nothing and must \
         still read completely"
    );
    // THE finding: it is all or nothing. `meta.dat` sits in the last data block,
    // so by the time a cut reaches any span byte it has already taken the bit-13
    // declaration with it — there is no cut of a finalized container that yields
    // a partial span list.
    assert_eq!(
        partial, 0,
        "a truncated FINALIZED container yielded a PARTIAL span list. That is only possible \
         if the reader inferred bit 13 from the presence of a spans.dat entry instead of \
         reading meta.dat, which would also silently accept a container carrying feature \
         bits this build does not understand"
    );
}

// ── A server that stops mid-request ─────────────────────────────────────

/// A server that hangs up mid-body must cost a poll, never a row.
///
/// The recovery property is the point: because the CLIENT owns the cursor and
/// the tail only advances it over chunks that decoded cleanly, retrying the
/// failed poll with the same cursor yields exactly the delta the failed poll
/// would have.
#[test]
fn a_server_that_stops_mid_request_fails_closed_and_recovers() {
    let server = RangeServer::start(stage_image(1));
    let mut tail = RemoteRequestSpanTail::open(&server.url()).unwrap();

    let healthy = tail.poll(0).expect("baseline poll");
    assert!(!healthy.spans.is_empty());
    let cursor = healthy.cursor;

    // Grow the container AND break the server at the same moment.
    server.publish(stage_image(2));
    server.set_fault(Fault::TruncateBody);
    let err = tail.poll(cursor).expect_err("a short body must fail the poll");
    assert!(
        err.contains("body length") || err.contains("short") || err.contains("failed"),
        "the failure must name a transport problem, got: {err}"
    );
    assert_eq!(
        tail.policy().consecutive_errors(),
        1,
        "a failed poll must move the backoff schedule"
    );
    assert_eq!(
        tail.policy().next_delay(),
        RemotePollPolicy::ERROR_MIN_INTERVAL,
        "the first retry waits the error floor, not the idle floor"
    );

    // The server comes back. The SAME cursor must produce the delta the failed
    // poll would have: nothing was consumed, nothing was skipped.
    server.set_fault(Fault::None);
    let recovered = tail.poll(cursor).expect("the tail must recover");
    assert_eq!(recovered.cursor, STAGE_CHUNKS[1]);
    assert!(!recovered.reset, "recovery is a delta, not a re-snapshot");
    assert_eq!(
        tail.policy().consecutive_errors(),
        0,
        "a successful poll clears the error schedule"
    );

    // And the rows are exactly stage 2's, merged over stage 1's.
    let mut merged: BTreeMap<u64, RequestRecord> = BTreeMap::new();
    merge(&mut merged, &healthy.spans);
    merge(&mut merged, &recovered.spans);
    assert_eq!(
        merged.keys().copied().collect::<Vec<_>>(),
        expected_requests(2).keys().copied().collect::<Vec<_>>()
    );
}

/// An idle poll — the container did not change — must cost almost nothing and
/// must not re-fetch `spans.dat`.
#[test]
fn polling_an_unchanged_remote_container_reads_no_span_data() {
    let server = RangeServer::start(stage_image(3));
    let mut tail = RemoteRequestSpanTail::open(&server.url()).unwrap();

    let first = tail.poll(0).expect("first poll");
    assert!(first.reset);
    assert!(
        tail.last_stats().data_bytes_requested > 0,
        "the first poll reads spans.dat"
    );

    let before = server.served_bytes();
    let idle = tail.poll(first.cursor).expect("idle poll");
    assert!(idle.spans.is_empty(), "nothing changed, so nothing is new");
    assert_eq!(idle.cursor, first.cursor);
    assert_eq!(
        tail.last_stats().data_bytes_requested,
        0,
        "an idle poll must not fetch a single byte of spans.dat"
    );
    let idle_cost = server.served_bytes() - before;
    assert!(
        idle_cost < 2048,
        "an idle poll cost {idle_cost} bytes; it should be a directory read and nothing more"
    );
    assert_eq!(
        tail.policy().idle_polls(),
        1,
        "an empty delta must advance the idle backoff"
    );
}

// ── Mutation control: is the range claim falsifiable? ───────────────────

/// A [`RangeFetcher`] that IGNORES the requested range and downloads the whole
/// resource, then slices locally.
///
/// This is the mutation the range budget exists to catch, and it is deliberately
/// *correct*: it returns exactly the bytes asked for, so every functional
/// assertion in [`remote_live_panel_over_http_range`] still passes for it. Only
/// the server-side byte count can tell the difference — which is the whole
/// reason that assertion is in the test.
///
/// Written against a raw `TcpStream` rather than a client library because the
/// integration-test crate links only the db-backend's public API and its
/// dev-dependencies; the transport under test is HTTP/1.1 either way.
#[derive(Debug)]
struct WholeFileFetcher {
    host: String,
    path: String,
}

impl WholeFileFetcher {
    fn new(url: &str) -> Self {
        let rest = url.strip_prefix("http://").expect("http url");
        let (host, path) = rest.split_once('/').expect("url with a path");
        WholeFileFetcher {
            host: host.to_string(),
            path: format!("/{path}"),
        }
    }

    /// One plain `GET` with no `Range` header — the whole body, every time.
    fn get_whole(&self) -> Result<Vec<u8>, CtfsError> {
        let mut stream = TcpStream::connect(&self.host)
            .map_err(|e| CtfsError::Corrupt(format!("whole-file fetch: connect failed: {e}")))?;
        let req = format!(
            "GET {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n",
            self.path, self.host
        );
        stream
            .write_all(req.as_bytes())
            .map_err(|e| CtfsError::Corrupt(format!("whole-file fetch: write failed: {e}")))?;
        let mut raw = Vec::new();
        stream
            .read_to_end(&mut raw)
            .map_err(|e| CtfsError::Corrupt(format!("whole-file fetch: read failed: {e}")))?;
        let split = raw
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .ok_or_else(|| CtfsError::Corrupt("whole-file fetch: no header terminator".to_string()))?;
        Ok(raw[split + 4..].to_vec())
    }
}

impl RangeFetcher for WholeFileFetcher {
    fn fetch_range(&self, start: u64, end: u64) -> Result<Vec<u8>, CtfsError> {
        let body = self.get_whole()?;
        let (s, e) = (start as usize, end as usize);
        if e > body.len() {
            return Err(CtfsError::Corrupt(format!(
                "whole-file fetch: range [{start}, {end}) past the {} byte body",
                body.len()
            )));
        }
        Ok(body[s..e].to_vec())
    }

    fn total_size(&self) -> Result<u64, CtfsError> {
        Ok(self.get_whole()?.len() as u64)
    }
}

/// **Mutation control.**
///
/// Swap the transport for one that downloads the whole file on every fetch and
/// re-run the identical live session. Assert two things:
///
/// * the ROWS are identical — the mutation has no functional shadow, which is
///   exactly why it could ship unnoticed; and
/// * the byte budget [`remote_live_panel_over_http_range`] asserts is BLOWN —
///   so that assertion is doing real work rather than being satisfied by
///   anything that happens to return the right spans.
#[test]
fn the_range_budget_is_falsifiable_a_whole_file_reader_blows_it() {
    // Reference run: the real range reader.
    let range_server = RangeServer::start(stage_image(1));
    let mut range_tail = RemoteRequestSpanTail::open(&range_server.url()).unwrap();
    let mut range_rows: BTreeMap<u64, RequestRecord> = BTreeMap::new();
    let mut cursor = 0u64;
    for stage in 1..=4usize {
        if stage > 1 {
            range_server.publish(stage_image(stage));
        }
        let d = range_tail.poll(cursor).unwrap();
        cursor = d.cursor;
        merge(&mut range_rows, &d.spans);
    }
    let range_bytes = range_server.served_bytes();

    // Mutant run: identical loop, non-lazy transport.
    let full_server = RangeServer::start(stage_image(1));
    let fetcher = WholeFileFetcher::new(&full_server.url());
    let source = HttpRangeSource::new(Box::new(fetcher)).expect("the mutant transport still opens the container");
    let mut full_tail = RemoteRequestSpanTail::open_source(Box::new(source)).unwrap();
    let mut full_rows: BTreeMap<u64, RequestRecord> = BTreeMap::new();
    let mut cursor = 0u64;
    for stage in 1..=4usize {
        if stage > 1 {
            full_server.publish(stage_image(stage));
        }
        let d = full_tail.poll(cursor).unwrap();
        cursor = d.cursor;
        merge(&mut full_rows, &d.spans);
    }
    let full_bytes = full_server.served_bytes();

    // 1. No functional shadow: the mutation is invisible in the output.
    assert_eq!(
        range_rows, full_rows,
        "the whole-file reader must produce the SAME rows — that is precisely why the \
         byte budget is the only assertion that can catch it"
    );

    // 2. The budget the required test asserts is blown by the mutant.
    assert!(
        range_bytes < RANGE_BUDGET_BYTES,
        "control precondition: the range reader must be inside the budget ({range_bytes} bytes)"
    );
    assert!(
        full_bytes > RANGE_BUDGET_BYTES,
        "MUTATION CONTROL FAILED: a reader that downloads the whole file on every fetch \
         moved only {full_bytes} bytes, which is inside the {RANGE_BUDGET_BYTES}-byte budget. \
         The budget assertion in remote_live_panel_over_http_range would not catch a \
         non-lazy reader, so it proves nothing about ranges."
    );
    assert!(
        full_bytes > range_bytes * 10,
        "the mutant moved {full_bytes} bytes against the range reader's {range_bytes}; \
         the gap should be orders of magnitude"
    );
}
