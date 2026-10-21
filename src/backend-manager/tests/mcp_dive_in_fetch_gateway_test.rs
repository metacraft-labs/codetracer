//! The MCP server's dive-in fetch sends its gateway token only to the
//! configured gateway.
//!
//! A trace tool's `trace_path` may be a dive-in URL, and the server fetches
//! the recording it names from the codetracer-ci gateway with a bearer token
//! (`CODETRACER_GATEWAY_TOKEN`).  Dive-in URLs come from span data, which
//! whoever can send spans writes, so the URL must not choose where the token
//! goes.  Before this test the server connected to whatever host the URL
//! named, or its `gatewayBaseUrl` parameter named, and sent the token there.
//! Now the gateway is the origin `CODETRACER_CI_BASE_URL` configures, and any
//! other origin is refused before a connection is opened.
//!
//! The test drives the real server (`trace mcp`) over stdio with the
//! `trace_info` tool and these dive-in URLs:
//!
//! * one whose host is a second listener (the attacker's host);
//! * one on the gateway whose `gatewayBaseUrl` names that listener;
//! * one whose authority puts the gateway in user information in front of
//!   that listener (`http://<gateway>@<listener>/...`).
//!
//! Each must come back as a tool error refusing the URL, and the listener
//! must receive no connection.  As the negative control, a dive-in URL on the
//! gateway is fetched with the token: the gateway answers it as an
//! authenticated caller (404 `trace_not_found` for the trace id the test
//! makes up), and a second server without the token gets 401 for the same
//! URL, so the 404 is the token at work.  That 404 comes chunked on the wire
//! (the test checks), and the error must quote it decoded: the gateway's
//! problem document, parsed as JSON.
//!
//! The positive arm fetches a real recording.  The test writes one with the
//! production CTFS writer, uploads it through codetracer-ci's managed-upload
//! routes with the CI token (upload session, presigned slice URL, PUT,
//! finalize), signs in as the stack's seeded user and creates a Trace share
//! link with download permission for it.  The gateway reads a recording only
//! for a caller that may read it; the CI token authenticates but is no
//! member of the tenant, and the share token (`X-Share-Token`) is what
//! authorizes the read.  So a dive-in URL naming the recording by its
//! `recording_id` is refused 403 `cannot_read_trace` without the share token
//! (and nothing is cached), and with it, given as the URL's `shareToken` or
//! as `CODETRACER_GATEWAY_SHARE_TOKEN`, the server caches the recording
//! under its recording id byte for byte and the real daemon opens it: its
//! source list is the recorded file.
//!
//! ## What is real, and what stands in for what
//!
//! * The gateway is a running codetracer-ci, named by
//!   `CODETRACER_TEST_GATEWAY_URL`, with a token it accepts in the file
//!   `CODETRACER_TEST_GATEWAY_TOKEN_FILE`.  The recipe
//!   `just t_mcp_dive_in_fetch_sends_token_only_to_gateway` in the sibling
//!   codetracer-observability-e2e checkout brings up its local stack (the
//!   codetracer-ci Monolith on Postgres and MinIO), runs this test against it
//!   with the stack's seeded CI API token and its seed file
//!   (`CODETRACER_TEST_GATEWAY_SEED_FILE`: the tenant and the user who shares
//!   the recording), and stops it.  Missing any of the three variables fails
//!   the test; it never skips.  The test is `#[ignore]`d so a
//!   plain `cargo nextest run` without a gateway does not run it.
//! * The attacker's host is a plain TCP capture socket in this process.  It
//!   is the one stand-in: an attacker's server is whatever accepts the
//!   connection, and what matters is whether a connection, and the token,
//!   arrive at all.  It records every connection's request bytes and answers
//!   404.
//! * The server is the production `session-manager` binary.  The refusal
//!   arms end in the URL resolution that precedes the daemon; the positive
//!   arm runs the real daemon, which starts the real `replay-server`
//!   (missing is a failure).  The recording comes from the production CTFS
//!   writer instead of a language recorder, so no interpreter is needed; the
//!   upload, share link and gateway are codetracer-ci's production routes.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::time::timeout;

/// The `session-manager` (formerly `backend-manager`) binary next to this
/// test binary, the binary `ct trace mcp` runs.
fn server_binary() -> PathBuf {
    let mut dir = std::env::current_exe().expect("test binary path");
    dir.pop();
    if dir.ends_with("deps") {
        dir.pop();
    }
    for name in ["session-manager", "backend-manager"] {
        let candidate = dir.join(format!("{name}{}", std::env::consts::EXE_SUFFIX));
        if candidate.is_file() {
            return candidate;
        }
    }
    panic!("no session-manager binary next to {}", dir.display());
}

fn required_env(name: &str) -> String {
    match std::env::var(name) {
        Ok(v) if !v.trim().is_empty() => v.trim().to_string(),
        _ => panic!(
            "{name} is not set: this test needs a running codetracer-ci (see the file header; \
             `just t_mcp_dive_in_fetch_sends_token_only_to_gateway` in \
             codetracer-observability-e2e provides one)"
        ),
    }
}

/// The capture socket standing in for an attacker-controlled host.
struct CaptureListener {
    port: u16,
    requests: Arc<Mutex<Vec<Vec<u8>>>>,
}

impl CaptureListener {
    fn start() -> CaptureListener {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind the capture listener");
        let port = listener.local_addr().unwrap().port();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&requests);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                // Read until the end of the request head, EOF or the timeout.
                let mut seen = Vec::new();
                let mut buf = [0u8; 4096];
                while !seen.windows(4).any(|w| w == b"\r\n\r\n") && seen.len() < 64 * 1024 {
                    match stream.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => seen.extend_from_slice(&buf[..n]),
                    }
                }
                sink.lock().unwrap().push(seen);
                let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            }
        });
        CaptureListener { port, requests }
    }

    fn count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }

    fn requests(&self) -> Vec<Vec<u8>> {
        self.requests.lock().unwrap().clone()
    }
}

/// A plain GET from the test itself, for the gateway checks that do not go
/// through the MCP server: `(status, header block, raw body)`.  The body is
/// as it came off the wire, framing included.
fn direct_get(authority: &str, path: &str, token: Option<&str>) -> (u16, String, String) {
    let mut stream = TcpStream::connect(authority).expect("connect to the gateway");
    stream
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    let auth = token
        .map(|t| format!("Authorization: Bearer {t}\r\n"))
        .unwrap_or_default();
    write!(
        stream,
        "GET {path} HTTP/1.1\r\nHost: {authority}\r\n{auth}Accept: application/json\r\nConnection: close\r\n\r\n"
    )
    .unwrap();
    let mut response = Vec::new();
    stream
        .read_to_end(&mut response)
        .expect("read the gateway's answer");
    let text = String::from_utf8_lossy(&response).into_owned();
    let status = text
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(|| panic!("no HTTP status in the gateway's answer: {text}"));
    let (head, body) = text
        .split_once("\r\n\r\n")
        .map(|(h, b)| (h.to_string(), b.to_string()))
        .unwrap_or_default();
    (status, head, body)
}

struct Mcp {
    _child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_id: i64,
}

impl Mcp {
    async fn start(server: &Path, scratch: &Path, gateway: &str, token: Option<&str>) -> Mcp {
        Mcp::start_with(
            server,
            scratch,
            &scratch.join("cache"),
            gateway,
            token,
            None,
        )
        .await
    }

    /// `trace mcp` with its own trace cache, gateway token and share-token
    /// environment, pointed at the daemon socket under `scratch` (started
    /// by [`Daemon::start`] for the arms that open a recording).
    async fn start_with(
        server: &Path,
        scratch: &Path,
        cache: &Path,
        gateway: &str,
        token: Option<&str>,
        share_token_env: Option<&str>,
    ) -> Mcp {
        let mut command = Command::new(server);
        command
            .args(["trace", "mcp"])
            .env("CODETRACER_HOME", scratch.join("home"))
            .env("TMPDIR", scratch)
            .env("CODETRACER_TRACE_CACHE_DIR", cache)
            .env("CODETRACER_DAEMON_SOCK", daemon_socket(scratch))
            .env("CODETRACER_CI_BASE_URL", gateway)
            .env_remove("CODETRACER_GATEWAY_TOKEN")
            .env_remove("CODETRACER_GATEWAY_SHARE_TOKEN")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        if let Some(token) = token {
            command.env("CODETRACER_GATEWAY_TOKEN", token);
        }
        if let Some(share) = share_token_env {
            command.env("CODETRACER_GATEWAY_SHARE_TOKEN", share);
        }
        let mut child = command.spawn().expect("start trace mcp");
        let stdin = child.stdin.take().unwrap();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        let mut mcp = Mcp {
            _child: child,
            stdin,
            stdout,
            next_id: 0,
        };
        mcp.request(
            "initialize",
            json!({"protocolVersion": "2024-11-05", "clientInfo": {"name": "gateway-origin-test", "version": "1"}}),
        )
        .await;
        mcp
    }

    async fn request(&mut self, method: &str, params: Value) -> Value {
        self.next_id += 1;
        let id = self.next_id;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.stdin
            .write_all(format!("{line}\n").as_bytes())
            .await
            .expect("write to the MCP server");
        self.stdin.flush().await.expect("flush the MCP server");
        loop {
            let mut buf = String::new();
            let n = timeout(Duration::from_secs(90), self.stdout.read_line(&mut buf))
                .await
                .expect("the MCP server answered in time")
                .expect("read from the MCP server");
            assert!(n > 0, "the MCP server closed stdout");
            let msg: Value = serde_json::from_str(buf.trim()).expect("a JSON-RPC line");
            if msg.get("id") == Some(&json!(id)) {
                return msg;
            }
        }
    }

    /// A trace tool on `trace_path`: `Ok(text)` for a result, `Err(text)`
    /// for a tool error.
    async fn tool(&mut self, name: &str, trace_path: &str) -> Result<String, String> {
        let resp = self
            .request(
                "tools/call",
                json!({"name": name, "arguments": {"trace_path": trace_path}}),
            )
            .await;
        let result = resp
            .get("result")
            .unwrap_or_else(|| panic!("{name} gave no result: {resp}"));
        let text = result["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("{name} result has no text: {resp}"))
            .to_owned();
        if result.get("isError") == Some(&Value::Bool(true)) {
            Err(text)
        } else {
            Ok(text)
        }
    }

    /// `trace_info` on a dive-in URL; the tool error's text.  A result that
    /// is not an error fails the test: no arm here names a fetchable
    /// recording.
    async fn trace_info_error(&mut self, url: &str) -> String {
        let resp = self
            .request(
                "tools/call",
                json!({"name": "trace_info", "arguments": {"trace_path": url}}),
            )
            .await;
        let result = resp
            .get("result")
            .unwrap_or_else(|| panic!("trace_info({url}) gave no result: {resp}"));
        let text = result["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("trace_info({url}) result has no text: {resp}"))
            .to_owned();
        assert_eq!(
            result.get("isError"),
            Some(&Value::Bool(true)),
            "trace_info({url}) succeeded: {text}"
        );
        text
    }
}

fn daemon_socket(scratch: &Path) -> PathBuf {
    scratch.join("codetracer").join("daemon.sock")
}

/// The real backend daemon on its own socket, starting the real
/// `replay-server`; stopped with `daemon stop` (and killed) on drop.
struct Daemon {
    server: PathBuf,
    socket: PathBuf,
    scratch: PathBuf,
    child: Child,
}

impl Daemon {
    async fn start(server: &Path, scratch: &Path) -> Daemon {
        let socket = daemon_socket(scratch);
        std::fs::create_dir_all(socket.parent().unwrap()).unwrap();
        let child = Command::new(server)
            .args(["daemon", "start"])
            .env("TMPDIR", scratch)
            .env("CODETRACER_HOME", scratch.join("home"))
            .env("CODETRACER_DAEMON_SOCKET", &socket)
            .env("CODETRACER_REPLAY_SERVER_CMD", replay_server(server))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .expect("start the daemon");
        let started = std::time::Instant::now();
        while !socket.exists() {
            assert!(
                started.elapsed() < Duration::from_secs(15),
                "the daemon socket never appeared"
            );
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        Daemon {
            server: server.to_path_buf(),
            socket,
            scratch: scratch.to_path_buf(),
            child,
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // Ask it to stop (it stops the replay-servers it started), then
        // make sure.
        let _ = std::process::Command::new(&self.server)
            .args(["daemon", "stop"])
            .env("TMPDIR", &self.scratch)
            .env("CODETRACER_HOME", self.scratch.join("home"))
            .env("CODETRACER_DAEMON_SOCKET", &self.socket)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let _ = self.child.start_kill();
    }
}

/// The `replay-server` the daemon starts: `CODETRACER_REPLAY_SERVER_CMD`,
/// else the one beside the server binary, else the sibling db-backend
/// crate's build.  Missing is a failure.
fn replay_server(server: &Path) -> PathBuf {
    if let Ok(cmd) = std::env::var("CODETRACER_REPLAY_SERVER_CMD") {
        let path = PathBuf::from(cmd);
        assert!(
            path.is_file(),
            "CODETRACER_REPLAY_SERVER_CMD={} is not a file",
            path.display()
        );
        return path;
    }
    let exe = std::env::consts::EXE_SUFFIX;
    let beside = server.with_file_name(format!("replay-server{exe}"));
    if beside.is_file() {
        return beside;
    }
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for profile in ["release", "debug"] {
        let candidate =
            manifest_dir.join(format!("../db-backend/target/{profile}/replay-server{exe}"));
        if candidate.is_file() {
            return candidate.canonicalize().unwrap_or(candidate);
        }
    }
    panic!(
        "replay-server was not found (CODETRACER_REPLAY_SERVER_CMD, beside the server \
         binary, or src/db-backend/target/{{release,debug}}); build it first"
    );
}

/// A recording of `source` written by the production CTFS writer into
/// `trace_dir/trace.ct`; its bytes.
fn write_recording(trace_dir: &Path, source: &Path) -> Vec<u8> {
    use codetracer_trace_types::{Line, NONE_TYPE_ID, TypeKind, ValueRecord};
    use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
    use codetracer_trace_writer::trace_writer::TraceWriter;

    let mut writer = CtfsTraceWriter::new("app.py", &[]);
    TraceWriter::set_workdir(&mut writer, source.parent().unwrap());
    TraceWriter::begin_writing_trace_events(&mut writer, &trace_dir.join("trace"))
        .expect("begin writing the recording");
    TraceWriter::start(&mut writer, source, Line(1));
    let int_type = TraceWriter::ensure_type_id(&mut writer, TypeKind::Int, "int");
    let main_fn = TraceWriter::ensure_function_id(&mut writer, "main", source, Line(1));
    TraceWriter::register_call(&mut writer, main_fn, vec![]);
    for (line, total) in [(2, 0), (3, 1)] {
        TraceWriter::register_step(&mut writer, source, Line(line));
        TraceWriter::register_variable_with_full_value(
            &mut writer,
            "total",
            ValueRecord::Int {
                i: total,
                type_id: int_type,
            },
        );
    }
    TraceWriter::register_return(
        &mut writer,
        ValueRecord::None {
            type_id: NONE_TYPE_ID,
        },
    );
    TraceWriter::finish_writing_trace_events(&mut writer).expect("finish the recording");
    TraceWriter::close(&mut writer).expect("close the recording");
    std::fs::read(trace_dir.join("trace.ct")).expect("the writer produced trace.ct")
}

/// The seeded tenant, user and CI token the gateway stack provides.
struct Seed {
    tenant: String,
    email: String,
    password: String,
}

fn read_seed() -> Seed {
    let file = required_env("CODETRACER_TEST_GATEWAY_SEED_FILE");
    let seed: Value = serde_json::from_str(
        &std::fs::read_to_string(&file).unwrap_or_else(|e| panic!("read {file}: {e}")),
    )
    .unwrap_or_else(|e| panic!("{file} is not JSON: {e}"));
    let field = |name: &str| {
        seed[name]
            .as_str()
            .unwrap_or_else(|| panic!("{file} has no {name}"))
            .to_string()
    };
    Seed {
        tenant: field("tenantId"),
        email: field("email"),
        password: field("password"),
    }
}

/// Upload `bytes` as a one-slice recording through codetracer-ci's managed
/// upload routes (upload session, presigned slice URL, PUT, finalize) with
/// the CI token, the way a recorder's managed upload does; the recording
/// (upload session) id, which is codetracer-ci's recording id.
fn upload_recording(gateway: &str, token: &str, tenant: &str, bytes: &[u8]) -> String {
    let agent = ureq::AgentBuilder::new().redirects(0).build();
    let bearer = format!("Bearer {token}");
    let session: Value = agent
        .post(&format!(
            "{gateway}/api/v1/tenants/{tenant}/traces/upload-session"
        ))
        .set("Authorization", &bearer)
        .send_json(json!({"platform": "linux-x86_64"}))
        .expect("an upload session")
        .into_json()
        .unwrap();
    let sid = session["sessionId"]
        .as_str()
        .expect("a session id")
        .to_string();
    let slice: Value = agent
        .post(&format!("{gateway}/api/v1/traces/{sid}/slice-upload-url"))
        .set("Authorization", &bearer)
        .send_json(json!({"sliceIndex": 0, "fileName": "trace.ct", "contentLength": bytes.len()}))
        .expect("a slice upload URL")
        .into_json()
        .unwrap();
    let put = agent
        .put(slice["uploadUrl"].as_str().expect("an upload URL"))
        .set("Content-Type", "application/octet-stream")
        .send_bytes(bytes)
        .expect("the slice PUT");
    assert!(
        put.status() == 200 || put.status() == 204,
        "slice PUT: {}",
        put.status()
    );
    let now = "2026-10-19T00:00:00Z";
    let finalize = agent
        .post(&format!("{gateway}/api/v1/traces/{sid}/finalize"))
        .set("Authorization", &bearer)
        .send_json(json!({
            "totalSlices": 1,
            "totalEvents": 1,
            "recordingManifest": {
                "kind": "mcr_slices",
                "uploadCompletionState": "complete",
                "serviceIdentity": {"serviceName": "dive-in-gateway-test"},
                "instanceIdentity": {"instanceId": "test-1"},
                "timeRange": {"startedAt": now, "endedAt": now},
                "retentionStatus": "available",
                "missingSliceKeys": [],
                "materializedTraceArtifacts": [],
                "totalSlices": 1,
                "totalEvents": 1,
                "createdAt": now,
                "recordingId": sid,
                "mcrSlices": [{
                    "sliceIndex": 0,
                    "sliceKey": slice["s3Key"].as_str().expect("a slice key"),
                    "uploadCompletionState": "complete",
                    "retentionStatus": "available",
                    "contentLength": bytes.len(),
                }],
            },
        }))
        .expect("the finalize");
    assert_eq!(finalize.status(), 204, "finalize");
    sid
}

/// Sign in as the seeded user and create a Trace share link with download
/// permission for `recording`; the share token.
fn share_recording(gateway: &str, seed: &Seed, recording: &str) -> String {
    let agent = ureq::AgentBuilder::new().redirects(0).build();
    let login = agent
        .post(&format!("{gateway}/api/v1/auth/login"))
        .send_json(json!({"email": seed.email, "password": seed.password}))
        .expect("sign in");
    let cookies: Vec<String> = login
        .all("Set-Cookie")
        .iter()
        .filter_map(|c| c.split(';').next().map(str::to_string))
        .collect();
    assert!(!cookies.is_empty(), "the sign-in set no cookie");
    let created: Value = agent
        .post(&format!(
            "{gateway}/api/v1/tenants/{}/share-links",
            seed.tenant
        ))
        .set("Cookie", &cookies.join("; "))
        .send_json(json!({
            "resourceType": "Trace",
            "resourceId": recording,
            "expiresInSeconds": 600,
            "canReplay": false,
            "canDownload": true,
        }))
        .expect("a share link")
        .into_json()
        .unwrap();
    let url = created["shareUrl"].as_str().expect("a share URL");
    let encoded = url.rsplit_once("/share/").expect("a /share/ URL").1;
    percent_decode(encoded)
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap();
            out.push(u8::from_str_radix(hex, 16).expect("percent-encoding"));
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).expect("UTF-8")
}

/// A trace id of the contract's form (32 lowercase hex characters) that no
/// recording carries.
fn made_up_trace_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    format!("{:032x}", nanos ^ (u128::from(std::process::id()) << 64))
}

fn percent_encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

#[tokio::test]
#[ignore = "needs a running codetracer-ci; run via `just t_mcp_dive_in_fetch_sends_token_only_to_gateway` in codetracer-observability-e2e"]
async fn t_mcp_dive_in_fetch_sends_token_only_to_gateway() {
    let gateway = required_env("CODETRACER_TEST_GATEWAY_URL");
    let gateway = gateway.trim_end_matches('/').to_string();
    let token_file = required_env("CODETRACER_TEST_GATEWAY_TOKEN_FILE");
    let token = std::fs::read_to_string(&token_file)
        .unwrap_or_else(|e| panic!("read {token_file}: {e}"))
        .trim()
        .to_string();
    assert!(!token.is_empty(), "{token_file} is empty");
    let gateway_authority = gateway
        .strip_prefix("http://")
        .unwrap_or_else(|| panic!("the gateway must be an http:// origin, got {gateway}"))
        .to_string();
    let server = server_binary();
    let scratch = tempfile::tempdir().expect("scratch directory");

    let trace_id = made_up_trace_id();
    let span_id = "00f067aa0ba902b7";
    let query = format!("trace_id={trace_id}&span_id={span_id}");
    let manifest_path = format!("/api/v1/observability/gateway/manifests/{trace_id}");

    // The gateway is codetracer-ci, it accepts the token, and the trace id
    // names nothing: without the token the manifest route answers 401, with
    // it 404 `trace_not_found`.
    let (status, _, body) = direct_get(&gateway_authority, &manifest_path, None);
    assert_eq!(status, 401, "the gateway without a token: {body}");
    let (status, head, body) = direct_get(&gateway_authority, &manifest_path, Some(&token));
    assert!(
        status == 404 && body.contains("trace_not_found"),
        "the gateway with the token: HTTP {status} {body}"
    );
    // That answer is chunked on the wire (RFC 9112 §7.1), so the decoding
    // arm below exercises the fetcher's chunked decoding, not a body that
    // happened to carry a Content-Length.
    assert!(
        head.lines().any(|l| {
            l.split_once(':').is_some_and(|(k, v)| {
                k.trim().eq_ignore_ascii_case("transfer-encoding")
                    && v.trim().eq_ignore_ascii_case("chunked")
            })
        }) && serde_json::from_str::<Value>(body.trim()).is_err(),
        "the gateway's 404 is not chunked, so it cannot test the decoding: {head}"
    );

    // Vacuity guard: the capture listener accepts a connection from this
    // process and records what it is sent, so a count of zero below is the
    // server not connecting, not a listener that cannot be reached.
    let attacker = CaptureListener::start();
    let attacker_authority = format!("127.0.0.1:{}", attacker.port);
    {
        let mut probe = TcpStream::connect(&attacker_authority).expect("reach the listener");
        probe.write_all(b"GET /probe HTTP/1.1\r\n\r\n").unwrap();
        let mut sink = Vec::new();
        let _ = probe.read_to_end(&mut sink);
    }
    let started = std::time::Instant::now();
    while attacker.count() < 1 {
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "the capture listener never recorded the probe"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        attacker.requests()[0].starts_with(b"GET /probe"),
        "the capture listener recorded something other than the probe"
    );
    let baseline = attacker.count();

    let mut mcp = Mcp::start(&server, scratch.path(), &gateway, Some(&token)).await;

    let attacker_base = format!("http://{attacker_authority}");
    // (arm, URL, what the refusal says)
    let refused = [
        (
            "the URL's host",
            format!("{attacker_base}/observability/v0/debug-session?{query}"),
            format!("its origin {attacker_base} is not the configured gateway {gateway}"),
        ),
        (
            "gatewayBaseUrl",
            format!(
                "{gateway}/observability/v0/debug-session?{query}&gatewayBaseUrl={}",
                percent_encode(&attacker_base)
            ),
            format!("its gatewayBaseUrl {attacker_base} is not the configured gateway {gateway}"),
        ),
        (
            "user information before the host",
            format!(
                "http://{gateway_authority}@{attacker_authority}/observability/v0/debug-session?{query}"
            ),
            "user information in the authority is refused".to_string(),
        ),
    ];
    let mut answers = Vec::new();
    for (arm, url, refusal) in &refused {
        answers.push((arm, refusal, mcp.trace_info_error(url).await));
    }

    // Give a connection the server might have opened time to be recorded,
    // then check the listener first: what reached it is the finding.
    std::thread::sleep(Duration::from_millis(500));
    let captured: Vec<String> = attacker.requests()[baseline..]
        .iter()
        .map(|r| {
            let text = String::from_utf8_lossy(r).into_owned();
            let carried = text.contains(&format!("Authorization: Bearer {token}"));
            format!(
                "carried the gateway token: {carried}; request: {:?}",
                text.replace(&token, "<the gateway token>")
            )
        })
        .collect();
    assert!(
        captured.is_empty(),
        "the attacker's host received {} connection(s) from the MCP server: {captured:#?}",
        captured.len()
    );
    for (arm, refusal, text) in &answers {
        assert!(
            text.contains(refusal.as_str()),
            "{arm}: the URL was not refused as expected ({refusal}): {text}"
        );
        assert!(!text.contains(&token), "{arm}: the error quotes the token");
    }

    // Negative control: a dive-in URL on the gateway is fetched with the
    // token.  The gateway's answer is the authenticated one (404
    // trace_not_found), here and with a gatewayBaseUrl naming the gateway.
    for url in [
        format!("{gateway}/observability/v0/debug-session?{query}"),
        format!(
            "{gateway}/observability/v0/debug-session?{query}&gatewayBaseUrl={}",
            percent_encode(&gateway)
        ),
    ] {
        let text = mcp.trace_info_error(&url).await;
        assert!(
            text.contains("HTTP 404") && text.contains("trace_not_found"),
            "the gateway's URL was not fetched with the token: {text}"
        );
        // Decoding arm: the error quotes the gateway's body, which came
        // chunked; decoded, it is the gateway's problem document as JSON.
        let quoted = text
            .split_once("HTTP 404 ")
            .map(|(_, b)| b.trim())
            .unwrap_or_else(|| panic!("no quoted body in: {text}"));
        let problem: Value = serde_json::from_str(quoted).unwrap_or_else(|e| {
            panic!("the gateway's chunked 404 body did not decode to JSON ({e}): {quoted:?}")
        });
        assert_eq!(
            (problem["status"].as_u64(), problem["code"].as_str()),
            (Some(404), Some("trace_not_found")),
            "the decoded problem document: {problem}"
        );
    }
    // The same URL from a server without the token: 401, so the 404 above
    // is the token reaching the gateway.
    let mut tokenless = Mcp::start(&server, scratch.path(), &gateway, None).await;
    let text = tokenless
        .trace_info_error(&format!("{gateway}/observability/v0/debug-session?{query}"))
        .await;
    assert!(
        text.contains("HTTP 401"),
        "the gateway answered a server without the token: {text}"
    );

    // Positive arm: a recording uploaded to the gateway and shared by link
    // is fetched through MCP, byte-exact, and opens in the real daemon.
    // The CI token authenticates; the share token authorizes the read.
    let seed = read_seed();
    let project = scratch.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    let source = project.join("app.py");
    std::fs::write(&source, "def main():\n    total = 0\n    total += 1\n").unwrap();
    let recorded_dir = scratch.path().join("recorded");
    std::fs::create_dir_all(&recorded_dir).unwrap();
    let recorded = write_recording(&recorded_dir, &source);
    let recording = upload_recording(&gateway, &token, &seed.tenant, &recorded);
    let share_token = share_recording(&gateway, &seed, &recording);
    let _daemon = Daemon::start(&server, scratch.path()).await;
    let dive_in =
        format!("{gateway}/observability/v0/debug-session?recording_id={recording}&{query}");

    // Without the share token the gateway refuses the CI token
    // (403 cannot_read_trace) and nothing is cached: the read below is the
    // share token at work.
    let unshared_cache = scratch.path().join("cache-unshared");
    let mut unshared = Mcp::start_with(
        &server,
        scratch.path(),
        &unshared_cache,
        &gateway,
        Some(&token),
        None,
    )
    .await;
    let refused = unshared
        .tool("trace_info", &dive_in)
        .await
        .expect_err("the recording was read without its share token");
    assert!(
        refused.contains("HTTP 403") && refused.contains("cannot_read_trace"),
        "without the share token: {refused}"
    );
    assert!(
        !unshared_cache.join(&recording).exists(),
        "a refused fetch left a cache entry"
    );

    // With it, from the URL (`shareToken`) and from the environment.
    for (index, (arm, url, share_env)) in [
        (
            "shareToken in the URL",
            format!("{dive_in}&shareToken={}", percent_encode(&share_token)),
            None,
        ),
        (
            "CODETRACER_GATEWAY_SHARE_TOKEN",
            dive_in.clone(),
            Some(share_token.as_str()),
        ),
    ]
    .into_iter()
    .enumerate()
    {
        let cache = scratch.path().join(format!("cache-shared-{index}"));
        let mut shared = Mcp::start_with(
            &server,
            scratch.path(),
            &cache,
            &gateway,
            Some(&token),
            share_env,
        )
        .await;
        let info = shared.tool("trace_info", &url).await;
        let fetched = cache.join(&recording).join("trace.ct");
        let fetched_bytes = std::fs::read(&fetched).unwrap_or_else(|e| {
            panic!(
                "{arm}: no recording at {} ({e}); the tool said: {info:?}",
                fetched.display()
            )
        });
        assert!(
            fetched_bytes == recorded,
            "{arm}: the fetched recording is not the uploaded one ({} of {} bytes)",
            fetched_bytes.len(),
            recorded.len()
        );
        let info = info.unwrap_or_else(|e| panic!("{arm}: trace_info failed: {e}"));
        assert!(
            !info.contains(&share_token) && !info.contains(&token),
            "{arm}: a token in the answer"
        );
        // The daemon opened the fetched recording: its source list is the
        // recorded one.
        let listed = shared
            .tool("list_source_files", &url)
            .await
            .unwrap_or_else(|e| panic!("{arm}: list_source_files failed: {e}"));
        assert!(
            listed.lines().any(|l| Path::new(l.trim()) == source),
            "{arm}: list_source_files should list {}, got: {listed}",
            source.display()
        );
    }

    assert_eq!(
        attacker.count(),
        baseline,
        "the attacker's host was connected to during the controls"
    );
}
