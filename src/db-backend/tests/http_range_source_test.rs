//! M7 integration tests for `HttpRangeSource` over a REAL HTTP transport.
//!
//! These stand up a tiny local range-serving HTTP/1.1 server (a `std::net`
//! `TcpListener` thread that honours `Range: bytes=` and `HEAD` over a real
//! `.ct` byte image) so the `ureq`-backed `HttpRangeSource` is exercised over a
//! socket end-to-end, deterministically and without network access. They prove:
//!
//! - `e2e_http_range_source_reads_ct_over_range_requests` — a `CtfsReader` over
//!   `HttpRangeSource` reads a known internal file identically to the same image
//!   opened locally, AND fetches strictly fewer bytes than the whole file
//!   (laziness, byte-counted by the server).
//! - `e2e_browser_replay_lazy_no_full_download` — the browser/WASM `fetch`-based
//!   source cannot be built or driven in this environment (no browser runtime),
//!   so the browser end-to-end remains an Outstanding Task. The NATIVE laziness
//!   it would assert (replay over range requests touches a subset of bytes
//!   before any whole-file download) is already proven by the test above and is
//!   re-asserted here over the real socket transport. The wasm gate is honoured:
//!   the browser-specific assertion is `#[ignore]`d with a clear reason rather
//!   than faked green.
//!
//! See `codetracer-specs/Planned-Work/Browser-Based-Replaying.md` §5 and
//! `codetracer-specs/Trace-Files/CTFS-Lazy-Seekable-Coverage.milestones.org` M7.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::thread;

use db_backend::ctfs_trace_reader::ctfs_container::{CtfsReader, write_minimal_ctfs};
use db_backend::ctfs_trace_reader::http_range_source::HttpRangeSource;

/// A minimal range-serving HTTP/1.1 server over a fixed byte image.
///
/// Honours exactly what `HttpRangeSource`'s `ureq` transport needs:
/// - `HEAD` → `200` with `Content-Length: <total>` and `Accept-Ranges: bytes`.
/// - `GET` with `Range: bytes=<start>-<end>` → `206 Partial Content` with the
///   exact slice, `Content-Range: bytes <start>-<end>/<total>`, and a matching
///   `Content-Length`.
/// - `GET` with `Range: bytes=0-0` (the size-probe fallback) → the one-byte
///   `206` whose `Content-Range` total carries the resource length.
///
/// It counts the total response-body bytes it has served so a test can assert
/// the client fetched strictly fewer bytes than the whole image.
struct RangeServer {
    addr: std::net::SocketAddr,
    served_bytes: Arc<AtomicU64>,
    shutdown: Arc<AtomicBool>,
    handle: Option<thread::JoinHandle<()>>,
}

impl RangeServer {
    fn start(image: Vec<u8>) -> Self {
        Self::start_inner(image, false)
    }

    /// Start a NON-compliant server that ignores the `Range` header and always
    /// answers `200 OK` with the WHOLE body — the silent-full-download failure
    /// mode `HttpRangeSource` must reject.
    fn start_range_ignoring(image: Vec<u8>) -> Self {
        Self::start_inner(image, true)
    }

    fn start_inner(image: Vec<u8>, ignore_range: bool) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let addr = listener.local_addr().unwrap();
        let served_bytes = Arc::new(AtomicU64::new(0));
        let shutdown = Arc::new(AtomicBool::new(false));

        let image = Arc::new(image);
        let served = Arc::clone(&served_bytes);
        let stop = Arc::clone(&shutdown);
        let handle = thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        let _ = handle_conn(stream, &image, &served, ignore_range);
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
            served_bytes,
            shutdown,
            handle: Some(handle),
        }
    }

    fn url(&self) -> String {
        format!("http://{}/trace.ct", self.addr)
    }

    fn served_bytes(&self) -> u64 {
        self.served_bytes.load(Ordering::Relaxed)
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

/// Read one HTTP request and write the appropriate response. Returns once the
/// single request/response is handled (ureq opens a fresh connection per call by
/// default, so one request per connection is sufficient and keeps this simple).
fn handle_conn(
    mut stream: TcpStream,
    image: &[u8],
    served: &AtomicU64,
    ignore_range: bool,
) -> std::io::Result<()> {
    stream.set_read_timeout(Some(std::time::Duration::from_secs(5)))?;
    // Read until end of headers (\r\n\r\n).
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
    let mut lines = req.lines();
    let request_line = lines.next().unwrap_or("");
    let method = request_line.split_whitespace().next().unwrap_or("");
    let total = image.len() as u64;

    if method == "HEAD" {
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {total}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        );
        stream.write_all(resp.as_bytes())?;
        return Ok(());
    }

    // Find the Range header (case-insensitive).
    let range = req
        .lines()
        .find(|l| l.to_ascii_lowercase().starts_with("range:"))
        .and_then(|l| l.split_once(':').map(|x| x.1))
        .map(|v| v.trim().to_string());

    // A non-compliant server ignores the Range header entirely and answers the
    // WHOLE body with 200 OK. `HttpRangeSource` must reject this (a 206 is
    // required) so a silent full download can never masquerade as a range fetch.
    if ignore_range {
        served.fetch_add(total, Ordering::Relaxed);
        let header = format!("HTTP/1.1 200 OK\r\nContent-Length: {total}\r\nConnection: close\r\n\r\n");
        stream.write_all(header.as_bytes())?;
        stream.write_all(image)?;
        return Ok(());
    }

    if let Some(range) = range {
        // Parse "bytes=<start>-<end>".
        let spec = range.strip_prefix("bytes=").unwrap_or("");
        let (s, e) = spec.split_once('-').unwrap_or(("", ""));
        let start: u64 = s.trim().parse().unwrap_or(0);
        // Inclusive end per RFC 7233.
        let end_inclusive: u64 = if e.trim().is_empty() {
            total - 1
        } else {
            e.trim().parse().unwrap_or(total - 1)
        };
        let end_inclusive = end_inclusive.min(total - 1);
        let slice = &image[start as usize..=end_inclusive as usize];
        served.fetch_add(slice.len() as u64, Ordering::Relaxed);
        let header = format!(
            "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nConnection: close\r\n\r\n",
            slice.len(),
            start,
            end_inclusive,
            total
        );
        stream.write_all(header.as_bytes())?;
        stream.write_all(slice)?;
        return Ok(());
    }

    // No Range header: whole body (should not happen in these tests, but be
    // correct).
    served.fetch_add(total, Ordering::Relaxed);
    let header = format!("HTTP/1.1 200 OK\r\nContent-Length: {total}\r\nConnection: close\r\n\r\n");
    stream.write_all(header.as_bytes())?;
    stream.write_all(image)?;
    Ok(())
}

/// Build a `.ct` image in memory via the test container writer.
fn build_ct_image(files: &[(&str, &[u8])]) -> Vec<u8> {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("fixture.ct");
    write_minimal_ctfs(&path, files).unwrap();
    std::fs::read(&path).unwrap()
}

/// A `CtfsReader` over a real-socket `HttpRangeSource` reads an internal file
/// identically to the local open, while the server serves strictly fewer bytes
/// than the whole file (laziness over actual HTTP range requests).
#[test]
fn e2e_http_range_source_reads_ct_over_range_requests() {
    // Small target file + large bulk file we never read.
    let target: Vec<u8> = b"M7 http range source proves lazy replay! ".repeat(30);
    let bulk: Vec<u8> = (0..(4096 * 150)).map(|i| ((i * 13 + 5) % 251) as u8).collect();
    let image = build_ct_image(&[("target.bin", &target), ("bulk.bin", &bulk)]);
    let total_len = image.len() as u64;

    // Reference: local in-memory open.
    let mut local = CtfsReader::from_bytes(image.clone()).unwrap();
    let reference = local.read_file("target.bin").unwrap();
    assert_eq!(reference, target);

    // Under test: open over the real range server.
    let server = RangeServer::start(image);
    let source = Box::new(HttpRangeSource::open(&server.url()).expect("open HttpRangeSource over the local server"));
    let mut reader = CtfsReader::from_source(source).unwrap();
    let via_http = reader.read_file("target.bin").unwrap();
    assert_eq!(via_http, reference, "HTTP read must equal the local read");

    // Laziness: the server served strictly fewer bytes than the whole file.
    let served = server.served_bytes();
    assert!(served > 0, "the read must fetch something");
    assert!(
        served < total_len,
        "laziness: server served {served} of {total_len} bytes — must be a strict subset (bulk file never fetched)"
    );
}

/// The browser/WASM `fetch`-based source end-to-end is gated: it needs a browser
/// `fetch` runtime not available in this environment. The NATIVE laziness it
/// would assert — replay begins reading over bounded range requests before the
/// whole `.ct` is fetched — is proven by the test above and re-asserted here
/// over the real socket transport (the browser path would be byte-identical, it
/// only swaps `ureq` for `web_sys::fetch`). Kept `#[ignore]`d with a reason
/// rather than faked, per the milestone's honesty-over-green brief.
#[test]
#[ignore = "browser/WASM fetch runtime unavailable here; native laziness is proven by \
            e2e_http_range_source_reads_ct_over_range_requests. The wasm fetch adapter is an Outstanding Task."]
fn e2e_browser_replay_lazy_no_full_download() {
    // If/when a wasm-bindgen-test browser runner is wired up, this asserts the
    // same laziness invariant over the `web_sys::fetch` RangeFetcher.
    let target: Vec<u8> = b"browser lazy replay ".repeat(10);
    let bulk: Vec<u8> = (0..(4096 * 100)).map(|i| (i % 256) as u8).collect();
    let image = build_ct_image(&[("target.bin", &target), ("bulk.bin", &bulk)]);
    let total_len = image.len() as u64;

    let server = RangeServer::start(image);
    let source = Box::new(HttpRangeSource::open(&server.url()).unwrap());
    let mut reader = CtfsReader::from_source(source).unwrap();
    let got = reader.read_file("target.bin").unwrap();
    assert_eq!(got, target);
    assert!(server.served_bytes() < total_len, "replay must not download the whole file");
}

/// A server that IGNORES the `Range` header and returns `200 OK` with the whole
/// body must be rejected: `HttpRangeSource` requires `206 Partial Content`, so a
/// range-ignoring origin can never silently degrade laziness into a full
/// download. The construction-time header fetch is the first bounded range
/// request, so `open` fails right there.
#[test]
fn http_range_source_rejects_range_ignoring_server() {
    let image = build_ct_image(&[("data.bin", &b"x".repeat(4096))]);
    let server = RangeServer::start_range_ignoring(image);
    let result = HttpRangeSource::open(&server.url());
    let err = match result {
        Ok(_) => panic!("a 200-only (Range-ignoring) server must be rejected, not silently accepted"),
        Err(e) => e,
    };
    let msg = format!("{err:?}");
    assert!(
        msg.contains("206"),
        "rejection must cite the missing 206 Partial Content; got: {msg}"
    );
}
