//! `HttpRangeSource` — a [`BlockSource`] that fetches CTFS blocks lazily over
//! HTTP byte-range requests (M7 of the CTFS Lazy/Seekable Coverage initiative).
//!
//! This is the third interchangeable implementation of the shared
//! [`BlockSource`] trait (alongside [`InMemoryBlockSource`] / [`LocalFileSource`]
//! and [`FollowFileSource`]), per
//! `codetracer-specs/Trace-Files/Seek-Based-CTFS-Reader.md` §5.6 and
//! `codetracer-specs/Planned-Work/Browser-Based-Replaying.md` §5 ("HTTP Range
//! Request Details"). Plugging it into the SAME `CtfsReader` / `BlockSource`
//! read path means a reader can replay a `.ct` over the network **without**
//! downloading the whole file: a block-aligned fetch maps 1:1 onto a single
//! `Range: bytes=<start>-<end>` request, returning exactly those bytes
//! (CTFS-Binary-Format.md §7 "Chunk-Level Fetching for Network Access").
//!
//! # Native vs. wasm scope
//!
//! This module implements the **native** Rust source, built on the blocking
//! `ureq` client (already a direct dependency of the db-backend — see
//! `Cargo.toml`'s `ureq` entry). It is fully testable here against a local
//! range-serving HTTP fixture (see the unit/integration tests). The native
//! transport is gated `#[cfg(not(target_arch = "wasm32"))]` because `ureq`
//! performs blocking socket I/O that does not compile to
//! `wasm32-unknown-unknown`.
//!
//! The browser/WASM path is real but explicitly async:
//! [`BrowserRangeFetcher`] issues `web_sys::fetch` requests with `Range` headers
//! and [`BrowserHttpRangeSource`] mirrors the block-mapping/cache rules through
//! async `read_at` / `read_block` methods. It does **not** implement
//! [`BlockSource`] yet. The current `BlockSource` / [`RangeFetcher`] traits are
//! synchronous; blocking a browser worker while waiting for the same worker's
//! fetch promise would deadlock or require SharedArrayBuffer/Atomics plumbing
//! outside this crate. Keeping the browser adapter async is the honest
//! future-compatible seam until the reader grows an async `BlockSource` path.

use std::collections::HashMap;
use std::sync::Mutex;

use super::ctfs_container::{BlockSource, CtfsError};

const FIXED_AND_EXTENDED_HEADER_SIZE: u64 = 16; // HEADER_SIZE + EXTENDED_HEADER_SIZE
const CTFS_MAGIC: [u8; 5] = [0xC0, 0xDE, 0x72, 0xAC, 0xE2];

fn validate_half_open_range(start: u64, end: u64, context: &str) -> Result<usize, CtfsError> {
    if end <= start {
        return Err(CtfsError::Corrupt(format!(
            "{context}: empty/inverted range [{start}, {end})"
        )));
    }
    usize::try_from(end - start)
        .map_err(|_| CtfsError::Corrupt(format!("{context}: range [{start}, {end}) is too large")))
}

fn parse_ctfs_block_size(header: &[u8], context: &str) -> Result<usize, CtfsError> {
    if header.len() != FIXED_AND_EXTENDED_HEADER_SIZE as usize {
        return Err(CtfsError::Corrupt(format!(
            "{context}: short header fetch ({} of {FIXED_AND_EXTENDED_HEADER_SIZE} bytes)",
            header.len()
        )));
    }
    if header[..5] != CTFS_MAGIC {
        return Err(CtfsError::InvalidMagic);
    }
    let version = header[5];
    // Mirror the container reader's accepted version range (v2..=v4).
    if !(2..=4).contains(&version) {
        return Err(CtfsError::UnsupportedVersion(version));
    }
    let block_size = u32::from_le_bytes([header[8], header[9], header[10], header[11]]) as usize;
    if !matches!(block_size, 1024 | 2048 | 4096) {
        return Err(CtfsError::Corrupt(format!(
            "{context}: invalid block size: {block_size}"
        )));
    }
    Ok(block_size)
}

fn parse_content_range_total(content_range: &str, context: &str) -> Result<u64, CtfsError> {
    content_range
        .rsplit('/')
        .next()
        .and_then(|t| t.trim().parse::<u64>().ok())
        .ok_or_else(|| CtfsError::Corrupt(format!("{context}: unparseable Content-Range '{content_range}'")))
}

/// The transport seam: how an [`HttpRangeSource`] turns a byte range into bytes.
///
/// The block-mapping, caching, and size logic in [`HttpRangeSource`] is
/// transport-agnostic; this trait is the ONE place the actual network call
/// lives. The native implementation ([`UreqRangeFetcher`]) issues a blocking
/// `ureq` `Range:` GET. The browser implementation is deliberately separate and
/// async (`BrowserRangeFetcher`) because `web_sys::fetch` cannot honestly satisfy
/// this synchronous trait without an async reader path or a separate safe worker
/// bridge.
pub trait RangeFetcher: std::fmt::Debug + Send + Sync {
    /// Fetch the half-open byte range `[start, end)` from the resource,
    /// returning exactly `end - start` bytes.
    ///
    /// Implementations MUST issue a single bounded HTTP `Range:` request and
    /// MUST return a [`CtfsError::Corrupt`] (not a panic) on any transport
    /// error, a non-`206`/`200` status, or a short/over-long body. `end` is
    /// exclusive; the HTTP `Range` header it maps to is inclusive
    /// (`bytes=start-(end-1)`).
    fn fetch_range(&self, start: u64, end: u64) -> Result<Vec<u8>, CtfsError>;

    /// The total length of the resource in bytes.
    ///
    /// Native: a `HEAD` request's `Content-Length` (with a `Content-Range`
    /// total fallback). This is read once at construction to seed
    /// [`BlockSource::current_size`].
    fn total_size(&self) -> Result<u64, CtfsError>;
}

/// A [`BlockSource`] that serves CTFS blocks from bounded HTTP range requests.
///
/// Each [`read_block`](BlockSource::read_block) maps the block number to its
/// `[block_num * block_size, (block_num + 1) * block_size)` byte range and
/// issues exactly one `Range:` request (subject to the block cache); a
/// positional [`read_at`](BlockSource::read_at) issues one `Range:` request for
/// the exact `[offset, offset + len)` span. Because the read path above
/// (`CtfsReader`) only ever fetches the header, the Block 0 directory, and the
/// blocks of the specific internal files it needs, a replay touches a small
/// fraction of the file — the laziness M7 proves.
#[derive(Debug)]
pub struct HttpRangeSource {
    /// The byte transport (native `ureq` or, later, browser `fetch`).
    fetcher: Box<dyn RangeFetcher>,
    /// Resource length, observed once at construction (HEAD / first
    /// `Content-Range` total). For a finalized trace — the common browser case —
    /// this never changes; `refresh()` re-probes it for growing resources.
    size: u64,
    /// Container block size (1024/2048/4096), parsed from the extended header
    /// fetched at construction.
    block_size: usize,
    /// Small block cache so re-reading a hot block (notably Block 0, which holds
    /// the file directory and is consulted on every internal-file open) does not
    /// refetch over the network. Keyed by block number → block bytes.
    ///
    /// `Mutex` (not `RwLock`) keeps the cache mutable behind the `&self` read
    /// path while preserving the `Send + Sync` the `BlockSource` trait requires.
    /// The cache is an optimisation only: a miss simply refetches, so a poisoned
    /// lock is recovered from rather than propagated.
    block_cache: Mutex<HashMap<u64, Vec<u8>>>,
    /// Count of HTTP range requests actually issued (cache misses + positional
    /// reads). Exposed via [`HttpRangeSource::requests_made`] so tests can assert
    /// laziness (strictly fewer bytes/requests than a whole-file download) and
    /// that a block read is a SINGLE bounded request.
    requests_made: Mutex<u64>,
    /// Total bytes actually fetched over the wire (sum of every range response
    /// body). Exposed via [`HttpRangeSource::bytes_fetched`] for the laziness
    /// assertion (`bytes_fetched < size`).
    bytes_fetched: Mutex<u64>,
}

impl HttpRangeSource {
    /// Construct a source over an arbitrary [`RangeFetcher`].
    ///
    /// Probes the resource length via [`RangeFetcher::total_size`] and fetches
    /// the 16-byte CTFS header (one bounded range request) to learn the block
    /// size, failing fast with [`CtfsError`] on a non-CTFS or malformed
    /// resource. The header read is counted and cached like any other fetch.
    pub fn new(fetcher: Box<dyn RangeFetcher>) -> Result<Self, CtfsError> {
        let size = fetcher.total_size()?;
        if size < FIXED_AND_EXTENDED_HEADER_SIZE {
            return Err(CtfsError::Corrupt(format!(
                "http source: resource too small ({size} bytes, need at least {FIXED_AND_EXTENDED_HEADER_SIZE})"
            )));
        }

        // Fetch the fixed + extended header in one bounded range request.
        let header = fetcher.fetch_range(0, FIXED_AND_EXTENDED_HEADER_SIZE)?;
        let block_size = parse_ctfs_block_size(&header, "http source")?;

        let source = HttpRangeSource {
            fetcher,
            size,
            block_size,
            block_cache: Mutex::new(HashMap::new()),
            requests_made: Mutex::new(1), // the header fetch above
            bytes_fetched: Mutex::new(FIXED_AND_EXTENDED_HEADER_SIZE),
        };
        Ok(source)
    }

    /// Construct a source over the native blocking `ureq` transport (the
    /// production native path).
    ///
    /// `url` is the absolute URL of the `.ct` resource on a static file server
    /// that supports RFC 7233 range requests (S3, R2, nginx, …).
    #[cfg(not(target_arch = "wasm32"))]
    pub fn open(url: &str) -> Result<Self, CtfsError> {
        Self::new(Box::new(UreqRangeFetcher::new(url)))
    }

    /// Number of HTTP range requests issued so far (header fetch included).
    pub fn requests_made(&self) -> u64 {
        *self.requests_made.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Total bytes fetched over the wire so far (sum of every range body).
    pub fn bytes_fetched(&self) -> u64 {
        *self.bytes_fetched.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Issue one counted, accounted range fetch (cache-miss path).
    fn fetch_counted(&self, start: u64, end: u64) -> Result<Vec<u8>, CtfsError> {
        let bytes = self.fetcher.fetch_range(start, end)?;
        // Best-effort accounting: a poisoned counter lock means a panicking
        // test; recover the inner value rather than poisoning the read path.
        *self.requests_made.lock().unwrap_or_else(|e| e.into_inner()) += 1;
        *self.bytes_fetched.lock().unwrap_or_else(|e| e.into_inner()) += bytes.len() as u64;
        Ok(bytes)
    }
}

impl BlockSource for HttpRangeSource {
    fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, CtfsError> {
        if buf.is_empty() {
            return Ok(0);
        }
        let end = offset
            .checked_add(buf.len() as u64)
            .ok_or_else(|| CtfsError::Corrupt("http source: read offset overflow".to_string()))?;
        if end > self.size {
            return Err(CtfsError::Corrupt(
                "http source: read extends beyond end of container".to_string(),
            ));
        }
        let bytes = self.fetch_counted(offset, end)?;
        if bytes.len() != buf.len() {
            return Err(CtfsError::Corrupt(format!(
                "http source: range response wrong length ({} of {} bytes)",
                bytes.len(),
                buf.len()
            )));
        }
        buf.copy_from_slice(&bytes);
        Ok(buf.len())
    }

    fn current_size(&self) -> u64 {
        self.size
    }

    fn refresh(&mut self) -> Result<(), CtfsError> {
        // Re-probe the resource length so a growing remote trace (a live
        // recording served over HTTP) can surface appended blocks. For a
        // finalized trace this is unchanged; the cached blocks stay valid
        // because CTFS data blocks are immutable once written (append-only).
        self.size = self.fetcher.total_size()?;
        Ok(())
    }

    /// Block-aligned fetch: map block `block_num` to its byte range and issue a
    /// SINGLE bounded `Range:` request (subject to the block cache). This is the
    /// override the `BlockSource` trait invites for a source with a cheaper
    /// per-block fetch — the 1:1 block-to-range mapping at the heart of M7.
    fn read_block(&self, block_num: u64, block_size: usize) -> Result<Vec<u8>, CtfsError> {
        // Serve from the block cache when present (notably Block 0, re-read on
        // every internal-file open). A cache hit issues NO network request.
        if let Some(cached) = self
            .block_cache
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&block_num)
        {
            return Ok(cached.clone());
        }

        let offset = block_num
            .checked_mul(block_size as u64)
            .ok_or_else(|| CtfsError::Corrupt(format!("http source: block {block_num} offset overflow")))?;
        let end = offset
            .checked_add(block_size as u64)
            .ok_or_else(|| CtfsError::Corrupt(format!("http source: block {block_num} end overflow")))?;
        if end > self.size {
            return Err(CtfsError::Corrupt(format!(
                "http source: block {block_num} extends beyond end of container"
            )));
        }

        let bytes = self.fetch_counted(offset, end)?;
        if bytes.len() != block_size {
            return Err(CtfsError::Corrupt(format!(
                "http source: block {block_num} short fetch ({} of {block_size} bytes)",
                bytes.len()
            )));
        }
        self.block_cache
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(block_num, bytes.clone());
        Ok(bytes)
    }
}

/// Native `ureq`-backed [`RangeFetcher`]: a blocking `Range:` GET per fetch.
///
/// Built on the `ureq` 2.x agent already used by the db-backend's
/// `lazy_omniscient_prep_trigger` (so no new dependency is introduced). The
/// agent carries a read timeout so a stalled server fails rather than hangs.
#[cfg(not(target_arch = "wasm32"))]
#[derive(Debug)]
pub struct UreqRangeFetcher {
    url: String,
    agent: ureq::Agent,
}

#[cfg(not(target_arch = "wasm32"))]
impl UreqRangeFetcher {
    /// Build a fetcher for `url` with a default 30s read timeout.
    pub fn new(url: impl Into<String>) -> Self {
        let agent = ureq::AgentBuilder::new()
            .timeout(std::time::Duration::from_secs(30))
            .build();
        UreqRangeFetcher { url: url.into(), agent }
    }
}

#[cfg(not(target_arch = "wasm32"))]
impl RangeFetcher for UreqRangeFetcher {
    fn fetch_range(&self, start: u64, end: u64) -> Result<Vec<u8>, CtfsError> {
        let want = validate_half_open_range(start, end, "http fetch")?;
        // RFC 7233 ranges are inclusive on both ends; our `end` is exclusive.
        let last = end - 1;
        let resp = self
            .agent
            .get(&self.url)
            .set("Range", &format!("bytes={start}-{last}"))
            .call()
            .map_err(|e| CtfsError::Corrupt(format!("http fetch [{start}, {end}) failed: {e}")))?;
        // A range request to a compliant server yields 206 Partial Content. A
        // server that ignores the Range header answers 200 with the WHOLE body,
        // which would silently break the bounded-fetch contract — reject it so
        // laziness can never regress into a full download unnoticed.
        let status = resp.status();
        if status != 206 {
            return Err(CtfsError::Corrupt(format!(
                "http fetch [{start}, {end}): expected 206 Partial Content, got {status}"
            )));
        }
        let mut body = Vec::with_capacity(want);
        use std::io::Read;
        resp.into_reader()
            .take(want as u64 + 1)
            .read_to_end(&mut body)
            .map_err(|e| CtfsError::Corrupt(format!("http fetch [{start}, {end}) body read failed: {e}")))?;
        if body.len() != want {
            return Err(CtfsError::Corrupt(format!(
                "http fetch [{start}, {end}): body length {} != requested {want}",
                body.len()
            )));
        }
        Ok(body)
    }

    fn total_size(&self) -> Result<u64, CtfsError> {
        // Prefer a HEAD request's Content-Length.
        match self.agent.head(&self.url).call() {
            Ok(resp) => {
                if let Some(len) = resp.header("Content-Length").and_then(|v| v.parse::<u64>().ok()) {
                    return Ok(len);
                }
            }
            Err(e) => {
                // Some servers reject HEAD; fall through to the Content-Range
                // total of a one-byte range request below.
                log::debug!("http source: HEAD failed ({e}); falling back to Content-Range total");
            }
        }
        // Fallback: a `bytes=0-0` range whose `Content-Range: bytes 0-0/<total>`
        // header carries the resource length.
        let resp = self
            .agent
            .get(&self.url)
            .set("Range", "bytes=0-0")
            .call()
            .map_err(|e| CtfsError::Corrupt(format!("http source: size probe failed: {e}")))?;
        let content_range = resp.header("Content-Range").ok_or_else(|| {
            CtfsError::Corrupt("http source: no Content-Length or Content-Range for size".to_string())
        })?;
        parse_content_range_total(content_range, "http source")
    }
}

#[cfg(all(target_arch = "wasm32", feature = "browser-transport"))]
fn js_error(context: &str, value: wasm_bindgen::JsValue) -> CtfsError {
    let detail = value
        .as_string()
        .or_else(|| js_sys::JSON::stringify(&value).ok().and_then(|s| s.as_string()))
        .unwrap_or_else(|| "<non-string JS error>".to_string());
    CtfsError::Corrupt(format!("{context}: {detail}"))
}

#[cfg(all(target_arch = "wasm32", feature = "browser-transport"))]
async fn fetch_request(request: &web_sys::Request, context: &str) -> Result<web_sys::Response, CtfsError> {
    use wasm_bindgen::JsCast;
    use wasm_bindgen_futures::JsFuture;

    let global = js_sys::global();
    let promise = if let Ok(window) = global.clone().dyn_into::<web_sys::Window>() {
        window.fetch_with_request(request)
    } else if let Ok(scope) = global.dyn_into::<web_sys::WorkerGlobalScope>() {
        scope.fetch_with_request(request)
    } else {
        return Err(CtfsError::Corrupt(format!(
            "{context}: no Window or WorkerGlobalScope fetch runtime is available"
        )));
    };

    let value = JsFuture::from(promise).await.map_err(|e| js_error(context, e))?;
    value.dyn_into::<web_sys::Response>().map_err(|e| js_error(context, e))
}

/// Browser `fetch` byte transport for CTFS HTTP range requests.
///
/// This adapter performs real bounded browser requests and enforces the same
/// no-silent-full-download contract as [`UreqRangeFetcher`]: range reads must
/// return `206 Partial Content` and exactly the requested number of bytes.
/// It is async because browser `fetch` is promise-based; see the module-level
/// note for why this cannot honestly implement the synchronous [`RangeFetcher`]
/// trait yet.
#[cfg(all(target_arch = "wasm32", feature = "browser-transport"))]
#[derive(Debug, Clone)]
pub struct BrowserRangeFetcher {
    url: String,
}

#[cfg(all(target_arch = "wasm32", feature = "browser-transport"))]
impl BrowserRangeFetcher {
    pub fn new(url: impl Into<String>) -> Self {
        BrowserRangeFetcher { url: url.into() }
    }

    pub async fn fetch_range(&self, start: u64, end: u64) -> Result<Vec<u8>, CtfsError> {
        use wasm_bindgen::JsCast;
        use wasm_bindgen_futures::JsFuture;

        let want = validate_half_open_range(start, end, "browser fetch")?;
        let last = end - 1;
        let headers = web_sys::Headers::new().map_err(|e| js_error("browser fetch: create headers", e))?;
        headers
            .set("Range", &format!("bytes={start}-{last}"))
            .map_err(|e| js_error("browser fetch: set Range header", e))?;

        let init = web_sys::RequestInit::new();
        init.set_method("GET");
        init.set_headers(&headers);
        let request = web_sys::Request::new_with_str_and_init(&self.url, &init)
            .map_err(|e| js_error("browser fetch: create request", e))?;
        let resp = fetch_request(&request, "browser fetch").await?;
        let status = resp.status();
        if status != 206 {
            return Err(CtfsError::Corrupt(format!(
                "browser fetch [{start}, {end}): expected 206 Partial Content, got {status}"
            )));
        }
        let array_buffer = JsFuture::from(
            resp.array_buffer()
                .map_err(|e| js_error("browser fetch: response.arrayBuffer", e))?,
        )
        .await
        .map_err(|e| js_error("browser fetch: await response body", e))?;
        let bytes = js_sys::Uint8Array::new(&array_buffer).to_vec();
        if bytes.len() != want {
            return Err(CtfsError::Corrupt(format!(
                "browser fetch [{start}, {end}): body length {} != requested {want}",
                bytes.len()
            )));
        }
        Ok(bytes)
    }

    pub async fn total_size(&self) -> Result<u64, CtfsError> {
        let init = web_sys::RequestInit::new();
        init.set_method("HEAD");
        let request = web_sys::Request::new_with_str_and_init(&self.url, &init)
            .map_err(|e| js_error("browser source: create HEAD request", e))?;
        match fetch_request(&request, "browser source: HEAD").await {
            Ok(resp) if resp.status() < 400 => {
                if let Ok(Some(len)) = resp.headers().get("Content-Length") {
                    if let Ok(len) = len.parse::<u64>() {
                        return Ok(len);
                    }
                }
            }
            Ok(_) | Err(_) => {
                // Fall through to a one-byte range probe, matching the native
                // source's HEAD-refusing server behavior.
            }
        }

        let headers = web_sys::Headers::new().map_err(|e| js_error("browser source: create headers", e))?;
        headers
            .set("Range", "bytes=0-0")
            .map_err(|e| js_error("browser source: set size-probe Range header", e))?;
        let init = web_sys::RequestInit::new();
        init.set_method("GET");
        init.set_headers(&headers);
        let request = web_sys::Request::new_with_str_and_init(&self.url, &init)
            .map_err(|e| js_error("browser source: create size-probe request", e))?;
        let resp = fetch_request(&request, "browser source: size probe").await?;
        if resp.status() != 206 {
            return Err(CtfsError::Corrupt(format!(
                "browser source: size probe expected 206 Partial Content, got {}",
                resp.status()
            )));
        }
        let content_range = resp
            .headers()
            .get("Content-Range")
            .map_err(|e| js_error("browser source: read Content-Range", e))?
            .ok_or_else(|| {
                CtfsError::Corrupt("browser source: no Content-Length or Content-Range for size".to_string())
            })?;
        parse_content_range_total(&content_range, "browser source")
    }
}

/// Async browser counterpart to [`HttpRangeSource`].
///
/// This mirrors the same range accounting and block cache as the synchronous
/// `BlockSource` implementation, but exposes async methods because browser
/// `fetch` cannot be made synchronously blocking inside the current reader
/// without deadlocking the worker event loop.
#[cfg(all(target_arch = "wasm32", feature = "browser-transport"))]
#[derive(Debug)]
pub struct BrowserHttpRangeSource {
    fetcher: BrowserRangeFetcher,
    size: u64,
    block_size: usize,
    block_cache: std::cell::RefCell<HashMap<u64, Vec<u8>>>,
    requests_made: std::cell::Cell<u64>,
    bytes_fetched: std::cell::Cell<u64>,
}

#[cfg(all(target_arch = "wasm32", feature = "browser-transport"))]
impl BrowserHttpRangeSource {
    pub async fn open(url: &str) -> Result<Self, CtfsError> {
        Self::new(BrowserRangeFetcher::new(url)).await
    }

    pub async fn new(fetcher: BrowserRangeFetcher) -> Result<Self, CtfsError> {
        let size = fetcher.total_size().await?;
        if size < FIXED_AND_EXTENDED_HEADER_SIZE {
            return Err(CtfsError::Corrupt(format!(
                "browser http source: resource too small ({size} bytes, need at least {FIXED_AND_EXTENDED_HEADER_SIZE})"
            )));
        }
        let header = fetcher.fetch_range(0, FIXED_AND_EXTENDED_HEADER_SIZE).await?;
        let block_size = parse_ctfs_block_size(&header, "browser http source")?;
        Ok(BrowserHttpRangeSource {
            fetcher,
            size,
            block_size,
            block_cache: std::cell::RefCell::new(HashMap::new()),
            requests_made: std::cell::Cell::new(1),
            bytes_fetched: std::cell::Cell::new(FIXED_AND_EXTENDED_HEADER_SIZE),
        })
    }

    pub fn current_size(&self) -> u64 {
        self.size
    }

    pub fn block_size(&self) -> usize {
        self.block_size
    }

    pub fn requests_made(&self) -> u64 {
        self.requests_made.get()
    }

    pub fn bytes_fetched(&self) -> u64 {
        self.bytes_fetched.get()
    }

    pub async fn refresh(&mut self) -> Result<(), CtfsError> {
        self.size = self.fetcher.total_size().await?;
        Ok(())
    }

    pub async fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, CtfsError> {
        if buf.is_empty() {
            return Ok(0);
        }
        let end = offset
            .checked_add(buf.len() as u64)
            .ok_or_else(|| CtfsError::Corrupt("browser http source: read offset overflow".to_string()))?;
        if end > self.size {
            return Err(CtfsError::Corrupt(
                "browser http source: read extends beyond end of container".to_string(),
            ));
        }
        let bytes = self.fetch_counted(offset, end).await?;
        if bytes.len() != buf.len() {
            return Err(CtfsError::Corrupt(format!(
                "browser http source: range response wrong length ({} of {} bytes)",
                bytes.len(),
                buf.len()
            )));
        }
        buf.copy_from_slice(&bytes);
        Ok(buf.len())
    }

    pub async fn read_block(&self, block_num: u64) -> Result<Vec<u8>, CtfsError> {
        if let Some(cached) = self.block_cache.borrow().get(&block_num) {
            return Ok(cached.clone());
        }

        let offset = block_num
            .checked_mul(self.block_size as u64)
            .ok_or_else(|| CtfsError::Corrupt(format!("browser http source: block {block_num} offset overflow")))?;
        let end = offset
            .checked_add(self.block_size as u64)
            .ok_or_else(|| CtfsError::Corrupt(format!("browser http source: block {block_num} end overflow")))?;
        if end > self.size {
            return Err(CtfsError::Corrupt(format!(
                "browser http source: block {block_num} extends beyond end of container"
            )));
        }

        let bytes = self.fetch_counted(offset, end).await?;
        if bytes.len() != self.block_size {
            return Err(CtfsError::Corrupt(format!(
                "browser http source: block {block_num} short fetch ({} of {} bytes)",
                bytes.len(),
                self.block_size
            )));
        }
        self.block_cache.borrow_mut().insert(block_num, bytes.clone());
        Ok(bytes)
    }

    async fn fetch_counted(&self, start: u64, end: u64) -> Result<Vec<u8>, CtfsError> {
        let bytes = self.fetcher.fetch_range(start, end).await?;
        self.requests_made.set(self.requests_made.get() + 1);
        self.bytes_fetched.set(self.bytes_fetched.get() + bytes.len() as u64);
        Ok(bytes)
    }
}

#[cfg(all(test, not(target_arch = "wasm32")))]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    use std::sync::Arc;

    /// Shared fetch log so a test can inspect every range fetched even after the
    /// fetcher is moved into the source (which is moved into the `CtfsReader`).
    #[derive(Debug, Default)]
    struct FetchLog {
        ranges: Mutex<Vec<(u64, u64)>>,
        bytes: Mutex<u64>,
    }

    impl FetchLog {
        fn record(&self, start: u64, end: u64) {
            self.ranges.lock().unwrap().push((start, end));
            *self.bytes.lock().unwrap() += end - start;
        }
        fn total_bytes(&self) -> u64 {
            *self.bytes.lock().unwrap()
        }
    }

    /// An in-memory [`RangeFetcher`] over a fixed byte image — no sockets.
    ///
    /// Serves the exact `[start, end)` slice and records each fetched range into
    /// a SHARED [`FetchLog`], so a test can assert both byte-identity against the
    /// local image and total bytes fetched even after the fetcher is owned by the
    /// reader. This keeps the block-mapping/caching/size logic tests
    /// deterministic and fast; the real `ureq` transport over a socket is
    /// exercised by the integration test (`http_range_source_test.rs`).
    #[derive(Debug)]
    struct MemoryRangeFetcher {
        image: Vec<u8>,
        log: Arc<FetchLog>,
    }

    impl MemoryRangeFetcher {
        fn new(image: Vec<u8>) -> Self {
            MemoryRangeFetcher {
                image,
                log: Arc::new(FetchLog::default()),
            }
        }
        fn with_log(image: Vec<u8>, log: Arc<FetchLog>) -> Self {
            MemoryRangeFetcher { image, log }
        }
    }

    impl RangeFetcher for MemoryRangeFetcher {
        fn fetch_range(&self, start: u64, end: u64) -> Result<Vec<u8>, CtfsError> {
            if end <= start || end > self.image.len() as u64 {
                return Err(CtfsError::Corrupt(format!("mem fetch out of range [{start}, {end})")));
            }
            self.log.record(start, end);
            Ok(self.image[start as usize..end as usize].to_vec())
        }

        fn total_size(&self) -> Result<u64, CtfsError> {
            Ok(self.image.len() as u64)
        }
    }

    /// Build a fixture `.ct` image in memory via the test container writer.
    fn build_ct_image(files: &[(&str, &[u8])]) -> Vec<u8> {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("fixture.ct");
        super::super::ctfs_container::write_minimal_ctfs(&path, files).unwrap();
        std::fs::read(&path).unwrap()
    }

    /// `read_block(n)` issues a SINGLE bounded Range request and returns the
    /// correct block bytes — the M7 core block-fetch deliverable, proven against
    /// the in-memory transport with exact range accounting.
    #[test]
    fn test_http_range_source_block_fetch() {
        // A multi-block file so Block 0 and several data blocks exist.
        let payload: Vec<u8> = (0..(4096 * 3 + 17)).map(|i| (i % 256) as u8).collect();
        let image = build_ct_image(&[("data.bin", &payload)]);
        let block_size = 4096u64;

        let fetcher = MemoryRangeFetcher::new(image.clone());
        let source = HttpRangeSource::new(Box::new(fetcher)).unwrap();
        assert_eq!(source.block_size, 4096);

        // Requests issued by construction so far (header fetch only).
        let before = source.requests_made();

        // Fetch block 2 and assert it equals the local image's block 2 exactly,
        // and that exactly ONE additional range request was made for it.
        let block_num = 2u64;
        let got = source.read_block(block_num, block_size as usize).unwrap();
        let off = (block_num * block_size) as usize;
        let expected = &image[off..off + block_size as usize];
        assert_eq!(got, expected, "block {block_num} bytes must match the local image");
        assert_eq!(
            source.requests_made(),
            before + 1,
            "read_block must issue exactly one Range request"
        );

        // A second read of the same block is served from the cache — no new
        // request (Block 0 in particular must not refetch).
        let got2 = source.read_block(block_num, block_size as usize).unwrap();
        assert_eq!(got2, got);
        assert_eq!(
            source.requests_made(),
            before + 1,
            "a cached block read must issue no further request"
        );
    }

    /// A `CtfsReader` over an `HttpRangeSource` reads internal files
    /// byte-identically to the same image opened in memory, while fetching
    /// strictly fewer bytes than the whole file (laziness).
    #[test]
    fn e2e_http_range_source_reads_ct_over_range_requests() {
        use super::super::ctfs_container::CtfsReader;

        // Two files: a small target file we read, plus a large "bulk" file we do
        // NOT read, so the whole image is much bigger than what a single
        // internal-file read needs to fetch.
        let target: Vec<u8> = b"the quick brown fox jumps over the lazy dog".repeat(20);
        let bulk: Vec<u8> = (0..(4096 * 200)).map(|i| ((i * 7 + 3) % 251) as u8).collect();
        let image = build_ct_image(&[("target.bin", &target), ("bulk.bin", &bulk)]);
        let total_len = image.len() as u64;

        // Reference: in-memory open + read of the target file.
        let mut in_mem = CtfsReader::from_bytes(image.clone()).unwrap();
        let reference = in_mem.read_file("target.bin").unwrap();
        assert_eq!(reference, target);

        // Under test: open the SAME image through an HttpRangeSource and read
        // the same file through the shared CtfsReader/BlockSource path. A SHARED
        // FetchLog lets us read byte accounting after the fetcher is owned by the
        // reader.
        let log = Arc::new(FetchLog::default());
        let fetcher = MemoryRangeFetcher::with_log(image.clone(), Arc::clone(&log));
        let source = Box::new(HttpRangeSource::new(Box::new(fetcher)).unwrap());
        let mut reader = CtfsReader::from_source(source).unwrap();
        let via_http = reader.read_file("target.bin").unwrap();
        assert_eq!(via_http, reference, "HTTP read must equal the in-memory read");

        // Laziness: the target read fetched strictly fewer bytes than the whole
        // file — the large bulk file's blocks were never fetched.
        let fetched = log.total_bytes();
        assert!(fetched > 0, "the target read must fetch something");
        assert!(
            fetched < total_len,
            "laziness: fetched {fetched} of {total_len} bytes must be a strict subset (bulk file never read)"
        );
    }

    /// An `HttpRangeSource` composes under the M2 `CtfsBlockOverlay` in
    /// `InMemory` mode: an InMemory overlay over a remote read-only source stages
    /// an in-place mutation in RAM and reads it back, while the underlying source
    /// is never written (read-only-media / non-expanding browser session).
    #[test]
    fn test_overlay_over_http_source_in_memory() {
        use super::super::block_overlay::{CtfsBlockOverlay, OverlayMode};

        let payload: Vec<u8> = (0..(4096 * 2)).map(|i| (i % 256) as u8).collect();
        let image = build_ct_image(&[("data.bin", &payload)]);

        let log = Arc::new(FetchLog::default());
        let fetcher = MemoryRangeFetcher::with_log(image.clone(), Arc::clone(&log));
        let source = Box::new(HttpRangeSource::new(Box::new(fetcher)).unwrap());

        let mut overlay = CtfsBlockOverlay::new(source, OverlayMode::InMemory).unwrap();
        assert_eq!(overlay.mode(), OverlayMode::InMemory);

        // Mutate a data block through the overlay (copy-on-write into RAM).
        let block_num = 2u64;
        let original = overlay.read_block(block_num).unwrap();
        overlay
            .mutate_block(block_num, |b| {
                b[0] ^= 0xFF;
            })
            .unwrap();
        let mutated = overlay.read_block(block_num).unwrap();
        assert_ne!(mutated[0], original[0], "overlay mutation must be visible");
        assert_eq!(&mutated[1..], &original[1..], "only byte 0 changed");

        // Allocate a brand-new block in the overlay (born in RAM, never fetched).
        let new_block = overlay.alloc_block();
        overlay
            .write_block(new_block, vec![0xAB; overlay.block_size()])
            .unwrap();
        assert_eq!(overlay.read_block(new_block).unwrap(), vec![0xAB; overlay.block_size()]);

        // The remote source is read-only: the overlay never wrote through it.
        // (There is no write transport on a RangeFetcher; the InMemory overlay
        // discards staged blocks on drop.) A fresh fetch of block 2 still serves
        // the ORIGINAL bytes from the image.
        let fresh = HttpRangeSource::new(Box::new(MemoryRangeFetcher::new(image.clone()))).unwrap();
        let fresh_block = fresh.read_block(block_num, fresh.block_size).unwrap();
        assert_eq!(fresh_block, original, "the remote source must be unmodified");
    }
}
