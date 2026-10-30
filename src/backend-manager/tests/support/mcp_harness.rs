//! The parts of the MCP source-reading tests that drive the real binaries:
//! the `session-manager` (`ct trace mcp` and the daemon), the
//! `replay-server` the daemon starts, recordings written by the production
//! CTFS writer, and DAP framing.  Shared by
//! `mcp_read_source_file_confinement_test.rs` and
//! `mcp_host_source_reads_test.rs`; nothing here stands in for a component.

#![allow(dead_code, clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use codetracer_trace_types::{Line, NONE_TYPE_ID, TypeKind, ValueRecord};
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::time::{sleep, timeout};

/// The `session-manager` (formerly `backend-manager`) binary next to this
/// test binary, the binary `ct trace mcp` runs.
pub fn server_binary() -> PathBuf {
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

/// The `replay-server` the daemon starts for the recording: the one named
/// by `CODETRACER_REPLAY_SERVER_CMD`, else the one built beside this test,
/// else the sibling db-backend crate's build.  Missing is a failure, and so
/// is one older than its source ([`locate_replay_server`]).
pub fn replay_server() -> PathBuf {
    replay_server_for(&server_binary())
}

/// [`replay_server`] for the `session-manager` at `server`: the candidate
/// beside it is the one beside `server`.  Panics with
/// [`locate_replay_server`]'s refusal.
pub fn replay_server_for(server: &Path) -> PathBuf {
    let explicit = std::env::var_os("CODETRACER_REPLAY_SERVER_CMD").map(PathBuf::from);
    locate_replay_server(explicit, server, &db_backend_dir())
        .unwrap_or_else(|refusal| panic!("{refusal}"))
}

/// The db-backend crate, which builds `replay-server`: the sibling of this
/// crate in the checkout.
pub fn db_backend_dir() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../db-backend");
    dir.canonicalize().unwrap_or(dir)
}

/// Why [`locate_replay_server`] has no `replay-server` to give.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReplayServerRefusal {
    /// None is built at any candidate location (a test that may skip when
    /// the backend is not built skips on this one alone).
    NotBuilt(String),
    /// `CODETRACER_REPLAY_SERVER_CMD` names something that is not a file.
    NotAFile(String),
    /// The one found is older than an input it is built from.
    Stale(String),
}

impl std::fmt::Display for ReplayServerRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotBuilt(m) | Self::NotAFile(m) | Self::Stale(m) => f.write_str(m),
        }
    }
}

/// Choose the `replay-server` a test runs, and refuse a stale one.
///
/// The candidates, in order: `explicit` (`CODETRACER_REPLAY_SERVER_CMD`),
/// which must be a file; the one beside `server`; `db_backend`'s
/// `target/{release,debug}` build; `src/build-debug/bin`.  The first that
/// exists is the one, and none of the files it is built from may be newer
/// than it ([`check_replay_server_fresh`]), or this says why, naming the
/// binary, the newer file and the command that rebuilds it.  A binary that
/// predates its source answers the protocol of an older revision: one built
/// before the daemon learned a launch argument does not answer a launch that
/// carries it, and the test times out on a symptom instead of failing on the
/// cause.
pub fn locate_replay_server(
    explicit: Option<PathBuf>,
    server: &Path,
    db_backend: &Path,
) -> Result<PathBuf, ReplayServerRefusal> {
    let exe = std::env::consts::EXE_SUFFIX;
    let chosen = if let Some(path) = explicit {
        if !path.is_file() {
            return Err(ReplayServerRefusal::NotAFile(format!(
                "CODETRACER_REPLAY_SERVER_CMD={} is not a file",
                path.display()
            )));
        }
        path
    } else {
        let mut candidates = vec![server.with_file_name(format!("replay-server{exe}"))];
        for profile in ["release", "debug"] {
            candidates.push(db_backend.join(format!("target/{profile}/replay-server{exe}")));
        }
        candidates.push(db_backend.join(format!("../build-debug/bin/replay-server{exe}")));
        match candidates.into_iter().find(|candidate| candidate.is_file()) {
            Some(candidate) => candidate.canonicalize().unwrap_or(candidate),
            None => {
                return Err(ReplayServerRefusal::NotBuilt(format!(
                    "replay-server was not found (CODETRACER_REPLAY_SERVER_CMD, beside {}, \
                     {}/target/{{release,debug}} or src/build-debug/bin); build it first: \
                     cd {} && cargo build --bin replay-server",
                    server.display(),
                    db_backend.display(),
                    db_backend.display()
                )));
            }
        }
    };
    check_replay_server_fresh(&chosen, db_backend).map_err(ReplayServerRefusal::Stale)?;
    Ok(chosen)
}

/// Where the list of a binary's build inputs came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputSource {
    /// Cargo's dep-info file beside the binary (`replay-server.d`): every
    /// file the compiler and the build scripts reported reading, grammar C
    /// sources and `include_*!` files included.  Authoritative.
    DepInfo,
    /// No dep-info file: the manifest scan of [`replay_server_inputs`].
    ManifestScan,
}

/// `Ok` when no file `binary` is built from is newer than it; otherwise why
/// not.  The inputs are those of [`replay_server_inputs`]; an input cargo
/// listed that no longer exists counts as changed, as it does for cargo.
///
/// What this does not establish: it compares modification times, never
/// content, so a binary newer than every input but built from different
/// source (built in another checkout and named by
/// `CODETRACER_REPLAY_SERVER_CMD`, or inputs copied with their times kept)
/// is accepted.  A checkout that rewrites files gives them the current time,
/// so the check then asks for a rebuild cargo would do anyway.  When there is
/// no dep-info file and the db-backend source is not in this tree (the Nix
/// package build), there is nothing to compare and the binary is used as
/// found.
pub fn check_replay_server_fresh(binary: &Path, db_backend: &Path) -> Result<(), String> {
    let Some((source, inputs)) = replay_server_inputs(binary, db_backend) else {
        return Ok(());
    };
    let built = modified(binary).map_err(|e| {
        format!(
            "cannot read the modification time of {}: {e}",
            binary.display()
        )
    })?;
    let how = match source {
        InputSource::DepInfo => "cargo's dep-info",
        InputSource::ManifestScan => "the manifest scan",
    };
    let rebuild = format!(
        "rebuild it (cd {} && cargo build --bin replay-server) or name a current build in \
         CODETRACER_REPLAY_SERVER_CMD",
        db_backend.display()
    );
    for input in &inputs {
        match modified(input) {
            Ok(changed) if changed > built => {
                return Err(format!(
                    "{} is older than its source: {} changed after it was built ({} \
                     inputs from {how}); {rebuild}",
                    binary.display(),
                    input.display(),
                    inputs.len()
                ));
            }
            Ok(_) => {}
            Err(_) if source == InputSource::DepInfo => {
                return Err(format!(
                    "{} was built from {}, which no longer exists ({how}); {rebuild}",
                    binary.display(),
                    input.display()
                ));
            }
            Err(_) => {}
        }
    }
    Ok(())
}

/// The files `binary` is built from, and where the list came from; `None`
/// when there is neither a dep-info file nor a db-backend source to scan.
///
/// With cargo's dep-info file beside the binary (`<stem>.d`), that list.
/// Without one, a scan of `db_backend`'s manifest: the crate and, walking
/// transitively, every path dependency outside `[dev-dependencies]` that is
/// either not `optional` or enabled by the default features (followed
/// through features that enable features, `dep:` names and `name/feature`
/// entries); of each crate its `Cargo.toml`, `Cargo.lock`, `build.rs` and
/// `src/`, and for a crate under a `bindings/` directory (a tree-sitter
/// grammar's Rust binding) the grammar's own `src/`, where its C sources
/// are.  The scan is a lower bound (a build script may read anything); the
/// dep-info file is what cargo itself rebuilds from.
pub fn replay_server_inputs(
    binary: &Path,
    db_backend: &Path,
) -> Option<(InputSource, Vec<PathBuf>)> {
    let stem = binary.file_stem()?.to_string_lossy().into_owned();
    let dep_info = binary.with_file_name(format!("{stem}.d"));
    if let Ok(text) = std::fs::read_to_string(&dep_info)
        && let Some(files) = parse_dep_info(&text, binary)
    {
        return Some((InputSource::DepInfo, files));
    }
    if !db_backend.join("src").is_dir() {
        return None;
    }
    let mut files = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut pending = vec![canonical(db_backend)];
    while let Some(krate) = pending.pop() {
        if !seen.insert(krate.clone()) {
            continue;
        }
        for file in ["Cargo.toml", "Cargo.lock", "build.rs"] {
            let path = krate.join(file);
            if path.is_file() {
                files.push(path);
            }
        }
        walk_files(&krate.join("src"), &mut |path| files.push(path));
        if let Some(grammar) = grammar_root(&krate) {
            // The binding crate itself (its `lib.rs` sits beside its
            // manifest) and the grammar's C sources.
            walk_files(&krate, &mut |path| files.push(path));
            walk_files(&grammar.join("src"), &mut |path| files.push(path));
        }
        if let Ok(manifest) = std::fs::read_to_string(krate.join("Cargo.toml")) {
            // A `[lib]` or `[[bin]]` source outside `src/` (a grammar crate
            // whose library is `bindings/rust/lib.rs`): its directory.
            for target in target_paths(&manifest) {
                if let Some(dir) = krate.join(target).parent()
                    && dir != krate
                    && !dir.starts_with(krate.join("src"))
                {
                    walk_files(dir, &mut |path| files.push(path));
                }
            }
            for dep in built_path_dependencies(&manifest) {
                pending.push(canonical(&krate.join(dep)));
            }
        }
    }
    Some((InputSource::ManifestScan, files))
}

/// The prerequisites of the rule for `binary` in a Makefile-syntax dep-info
/// file (cargo writes one rule per output, `target: dep dep ...`, a space in
/// a path escaped as `\ `).  `None` when no rule names `binary`.
pub fn parse_dep_info(text: &str, binary: &Path) -> Option<Vec<PathBuf>> {
    let binary = canonical(binary);
    for line in text.lines() {
        let words = split_escaped(line);
        let Some(first) = words.first() else { continue };
        let Some(target) = first.strip_suffix(':') else {
            continue;
        };
        if canonical(Path::new(target)) == binary {
            return Some(words[1..].iter().map(PathBuf::from).collect());
        }
    }
    None
}

fn split_escaped(line: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        match c {
            // Cargo escapes only a space (`\ `); any other backslash is a
            // path character (a Windows separator).
            '\\' if chars.clone().next() == Some(' ') => {
                chars.next();
                word.push(' ');
            }
            ' ' | '\t' => {
                if !word.is_empty() {
                    words.push(std::mem::take(&mut word));
                }
            }
            _ => word.push(c),
        }
    }
    if !word.is_empty() {
        words.push(word);
    }
    words
}

/// The `path` of each `[lib]` and `[[bin]]` target `manifest` declares.
fn target_paths(manifest: &str) -> Vec<String> {
    let mut table = String::new();
    let mut found = Vec::new();
    for line in manifest.lines().map(str::trim) {
        if line.starts_with('[') {
            table = line.to_owned();
        } else if (table == "[lib]" || table == "[[bin]]")
            && let Some(rest) = line.strip_prefix("path")
            && let Some(path) = rest.split('"').nth(1)
        {
            found.push(path.to_owned());
        }
    }
    found
}

/// The grammar directory of a tree-sitter binding crate at
/// `<grammar>/bindings/<language>`.
fn grammar_root(krate: &Path) -> Option<PathBuf> {
    let parent = krate.parent()?;
    (parent.file_name()? == "bindings").then(|| parent.parent().map(Path::to_path_buf))?
}

fn canonical(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}

/// The `path` of every dependency declared inline in a dependency table of
/// `manifest` other than `[dev-dependencies]`, that is not `optional` or
/// that the default features enable.  A line-level reading, enough for the
/// manifests db-backend reaches, whose path dependencies are inline tables on
/// one line and whose feature lists may span lines.
pub fn built_path_dependencies(manifest: &str) -> Vec<String> {
    let mut table = String::new();
    let mut deps: Vec<(String, String, bool)> = Vec::new();
    let mut features: std::collections::HashMap<String, Vec<String>> = Default::default();
    let mut open_feature: Option<(String, String)> = None;
    for raw in manifest.lines() {
        let line = raw.split(" #").next().unwrap_or(raw).trim();
        if let Some((name, mut body)) = open_feature.take() {
            body.push_str(line);
            if line.contains(']') {
                features.insert(name, quoted(&body));
            } else {
                open_feature = Some((name, body));
            }
            continue;
        }
        if line.starts_with('[') {
            table = line.to_owned();
            continue;
        }
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        let Some((name, value)) = line.split_once('=') else {
            continue;
        };
        let (name, value) = (name.trim().trim_matches('"').to_owned(), value.trim());
        if table == "[features]" {
            if value.starts_with('[') && !value.contains(']') {
                open_feature = Some((name, value.to_owned()));
            } else {
                features.insert(name, quoted(value));
            }
            continue;
        }
        let in_dependencies =
            table.ends_with("dependencies]") && !table.ends_with("dev-dependencies]");
        if in_dependencies
            && let Some(rest) = value.split("path = \"").nth(1)
            && let Some(path) = rest.split('"').next()
        {
            deps.push((name, path.to_owned(), value.contains("optional = true")));
        }
    }
    // The dependencies the default features enable, through features that
    // enable features.
    let mut enabled = std::collections::HashSet::new();
    let mut visited = std::collections::HashSet::new();
    let mut queue = vec!["default".to_owned()];
    while let Some(feature) = queue.pop() {
        if !visited.insert(feature.clone()) {
            continue;
        }
        for entry in features.get(&feature).cloned().unwrap_or_default() {
            if let Some(dep) = entry.strip_prefix("dep:") {
                enabled.insert(dep.to_owned());
            } else if let Some((dep, _)) = entry.split_once('/') {
                if !dep.ends_with('?') {
                    enabled.insert(dep.to_owned());
                }
            } else if features.contains_key(&entry) {
                queue.push(entry);
            } else {
                enabled.insert(entry);
            }
        }
    }
    deps.into_iter()
        .filter(|(name, _, optional)| !optional || enabled.contains(name))
        .map(|(_, path, _)| path)
        .collect()
}

fn quoted(text: &str) -> Vec<String> {
    text.split('"')
        .enumerate()
        .filter(|(i, _)| i % 2 == 1)
        .map(|(_, word)| word.to_owned())
        .collect()
}

fn walk_files(dir: &Path, visit: &mut impl FnMut(PathBuf)) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if kind.is_dir() {
            // Build output and VCS metadata are not sources.
            let name = entry.file_name();
            if name == "target" || name.to_string_lossy().starts_with('.') {
                continue;
            }
            walk_files(&path, visit);
        } else if kind.is_file() {
            visit(path);
        }
    }
}

fn modified(path: &Path) -> std::io::Result<std::time::SystemTime> {
    std::fs::metadata(path)?.modified()
}

/// Write a recording of `source` into `trace_dir/trace.ct` with the
/// production CTFS writer, `workdir` as its recorded working directory.
/// `also_listed` are added to its source list, as a recorder adds every
/// file the program touched as source.
pub fn write_recording(trace_dir: &Path, workdir: &Path, source: &Path, also_listed: &[&Path]) {
    let mut writer = CtfsTraceWriter::new("app.py", &[]);
    TraceWriter::set_workdir(&mut writer, workdir);
    TraceWriter::begin_writing_trace_events(&mut writer, &trace_dir.join("trace"))
        .expect("begin writing the recording");
    TraceWriter::start(&mut writer, source, Line(1));
    for path in also_listed {
        TraceWriter::ensure_path_id(&mut writer, path);
    }
    let int_type = TraceWriter::ensure_type_id(&mut writer, TypeKind::Int, "int");
    let main_fn = TraceWriter::ensure_function_id(&mut writer, "main", source, Line(1));
    TraceWriter::register_call(&mut writer, main_fn, vec![]);
    for (line, total) in [(2, 0), (4, 0), (4, 1), (4, 3), (5, 3)] {
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
    assert!(
        trace_dir.join("trace.ct").is_file(),
        "the writer produced no trace.ct"
    );
}

/// Strip the root of an absolute path, the layout `files/` mirrors.
pub fn without_root(path: &Path) -> PathBuf {
    use std::path::Component;
    path.components()
        .filter(|c| !matches!(c, Component::Prefix(_) | Component::RootDir))
        .collect()
}

pub struct Mcp {
    pub child: Child,
    pub stdin: ChildStdin,
    pub stdout: BufReader<ChildStdout>,
    pub next_id: i64,
}

impl Mcp {
    pub async fn request(&mut self, method: &str, params: Value) -> Value {
        self.next_id += 1;
        let id = self.next_id;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.stdin
            .write_all(format!("{line}\n").as_bytes())
            .await
            .expect("write to the MCP server");
        self.stdin
            .flush()
            .await
            .expect("flush the MCP server's stdin");
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

    /// Close the server's stdin and wait for it to exit.
    pub async fn stop(mut self) {
        drop(self.stdin);
        let _ = timeout(Duration::from_secs(5), self.child.wait()).await;
        let _ = self.child.kill().await;
    }

    /// The `trace:///<trace>/source/<file_path>` resource, after loading the
    /// trace with `trace_info` (the resource serves loaded traces only):
    /// `Ok(text)` for its content, `Err(message)` for a JSON-RPC error.
    pub async fn read_source_resource(
        &mut self,
        trace_dir: &Path,
        file_path: &str,
    ) -> Result<String, String> {
        let info = self
            .request(
                "tools/call",
                json!({"name": "trace_info", "arguments": {"trace_path": trace_dir}}),
            )
            .await;
        assert!(
            info["result"].get("isError") != Some(&Value::Bool(true)),
            "trace_info failed: {info}"
        );
        let uri = format!("trace://{}/source/{file_path}", trace_dir.display());
        let resp = self.request("resources/read", json!({"uri": uri})).await;
        if let Some(error) = resp.get("error") {
            return Err(error["message"].as_str().unwrap_or_default().to_owned());
        }
        Ok(resp["result"]["contents"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("resources/read {uri} has no text: {resp}"))
            .to_owned())
    }

    /// `tools/call` of `name` with `arguments`: `Ok(text)` for a result,
    /// `Err(text)` for a tool error (`isError`), the text of its first
    /// content item either way.
    pub async fn call_tool(&mut self, name: &str, arguments: Value) -> Result<String, String> {
        let resp = self
            .request("tools/call", json!({"name": name, "arguments": arguments}))
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

    /// `read_source_file` for `file_path`: `Ok(text)` for a result,
    /// `Err(text)` for a tool error.
    pub async fn read_source(
        &mut self,
        trace_dir: &Path,
        file_path: &str,
    ) -> Result<String, String> {
        let resp = self
            .request(
                "tools/call",
                json!({
                    "name": "read_source_file",
                    "arguments": {"trace_path": trace_dir, "file_path": file_path},
                }),
            )
            .await;
        let result = resp
            .get("result")
            .unwrap_or_else(|| panic!("read_source_file({file_path}) gave no result: {resp}"));
        let text = result["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("read_source_file({file_path}) result has no text: {resp}"))
            .to_owned();
        if result.get("isError") == Some(&Value::Bool(true)) {
            Err(text)
        } else {
            Ok(text)
        }
    }
}

/// A fresh test directory with a short canonical path, so the daemon's
/// socket path fits in `sun_path`.
pub fn short_root(prefix: &str) -> (tempfile::TempDir, PathBuf) {
    let root = tempfile::Builder::new()
        .prefix(prefix)
        .tempdir_in(if cfg!(unix) {
            PathBuf::from("/tmp")
        } else {
            std::env::temp_dir()
        })
        .expect("test directory");
    let path = root
        .path()
        .canonicalize()
        .expect("canonical test directory");
    (root, path)
}

/// The private `CODETRACER_HOME` the harness gives the daemon and `trace mcp`
/// it starts under `root`.
///
/// Every per-user location the daemon resolves (its tmp dir, which holds the
/// script scratch parent and the replay sockets; the trace index; logs)
/// follows `CODETRACER_HOME`, and `CODETRACER_HOME` outranks `TMPDIR`
/// (`libs/ct-home`).  Setting only `TMPDIR`, as the harness used to, left the
/// daemon in whatever `CODETRACER_HOME` the test run inherited: `just
/// test-rust` exports a scratch one for the whole run, so the daemon's tmp
/// dir was not under `root` at all, and a test that arranged a directory there
/// (the script scratch parent) arranged one the daemon never looked at.
pub fn daemon_home(root: &Path) -> PathBuf {
    root.join("home")
}

/// The daemon's tmp dir (`$CODETRACER_HOME/tmp`, `ct_home::tmp_dir`) under
/// the home [`daemon_home`] gives it.
pub fn daemon_tmp_dir(root: &Path) -> PathBuf {
    daemon_home(root).join("tmp")
}

/// The real daemon, with its own socket under `root`, starting the real
/// `replay-server`.  Returns it and its socket once the socket exists.
pub async fn start_daemon(server: &Path, root: &Path, replay_server: &Path) -> (Child, PathBuf) {
    start_daemon_with_env(server, root, replay_server, &[]).await
}

/// [`start_daemon`] with extra environment for the daemon and the processes
/// it starts.
pub async fn start_daemon_with_env(
    server: &Path,
    root: &Path,
    replay_server: &Path,
    env: &[(&str, &OsStr)],
) -> (Child, PathBuf) {
    let daemon_dir = root.join("codetracer");
    std::fs::create_dir_all(&daemon_dir).unwrap();
    let socket = daemon_dir.join(if cfg!(windows) {
        "daemon.port"
    } else {
        "daemon.sock"
    });
    let stderr_log = root.join("daemon.stderr");
    let mut daemon = Command::new(server)
        .args(["daemon", "start"])
        .env("TMPDIR", root)
        .env("CODETRACER_HOME", daemon_home(root))
        // It outranks CODETRACER_HOME; an inherited one would move the tmp dir.
        .env_remove("CODETRACER_TMP_PATH")
        .env("CODETRACER_DAEMON_SOCKET", &socket)
        .env("CODETRACER_REPLAY_SERVER_CMD", replay_server)
        .envs(env.iter().map(|(k, v)| (*k, *v)))
        .stdout(Stdio::null())
        .stderr(std::fs::File::create(&stderr_log).expect("the daemon's stderr log"))
        .kill_on_drop(true)
        .spawn()
        .expect("start the daemon");
    wait_for_daemon_socket(&mut daemon, &socket, &stderr_log).await;
    (daemon, socket)
}

/// Wait until `daemon` has bound `socket`.  Fails at once, naming the
/// cause, when the daemon exits first (with what it wrote to `stderr_log`,
/// which names a socket path too long for `sun_path`), and on a timeout
/// names the socket path and its length against that limit.
pub async fn wait_for_daemon_socket(daemon: &mut Child, socket: &Path, stderr_log: &Path) {
    let started = tokio::time::Instant::now();
    while !socket.exists() {
        if let Ok(Some(status)) = daemon.try_wait() {
            let stderr = std::fs::read_to_string(stderr_log).unwrap_or_default();
            panic!(
                "the daemon exited ({status}) before its socket {} appeared; its stderr: {}",
                socket.display(),
                stderr.trim()
            );
        }
        if started.elapsed() >= Duration::from_secs(15) {
            panic!(
                "the daemon socket never appeared: {}",
                socket_path_note(socket)
            );
        }
        sleep(Duration::from_millis(50)).await;
    }
}

/// The longest path, in bytes, a Unix socket address holds: the size of
/// `sockaddr_un.sun_path` less its terminating NUL (unix(7)).  The same
/// expression as the session manager's `MAX_UNIX_SOCKET_PATH`
/// (`src/backend_manager.rs`), which this crate's binary does not export;
/// `the_daemon_names_a_socket_path_longer_than_sun_path` checks the two agree
/// on the daemon's own message.
#[cfg(unix)]
pub const MAX_UNIX_SOCKET_PATH: usize = std::mem::size_of::<libc::sockaddr_un>()
    - std::mem::offset_of!(libc::sockaddr_un, sun_path)
    - 1;

/// `socket` and its length in bytes, with the `sun_path` limit when it
/// exceeds it ([`MAX_UNIX_SOCKET_PATH`]).
#[cfg(unix)]
pub fn socket_path_note(socket: &Path) -> String {
    let len = socket.as_os_str().len();
    let max = MAX_UNIX_SOCKET_PATH;
    if len > max {
        format!(
            "{} is {len} bytes, longer than the {max} a Unix socket address holds (sun_path); \
             use a shorter TMPDIR",
            socket.display()
        )
    } else {
        format!("{} ({len} bytes)", socket.display())
    }
}

/// `socket` and its length in bytes.
#[cfg(not(unix))]
pub fn socket_path_note(socket: &Path) -> String {
    format!("{} ({} bytes)", socket.display(), socket.as_os_str().len())
}

/// `ct trace mcp <extra_args>` on stdio, pointed at the daemon socket
/// `socket`, initialized.
pub async fn start_mcp(server: &Path, root: &Path, socket: &Path, extra_args: &[&str]) -> Mcp {
    let mut child = Command::new(server)
        .args(["trace", "mcp"])
        .args(extra_args)
        .env("TMPDIR", root)
        .env("CODETRACER_HOME", daemon_home(root))
        // It outranks CODETRACER_HOME; an inherited one would move the tmp dir.
        .env_remove("CODETRACER_TMP_PATH")
        .env("CODETRACER_DAEMON_SOCK", socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("start trace mcp");
    let stdin = child.stdin.take().unwrap();
    let stdout = BufReader::new(child.stdout.take().unwrap());
    let mut mcp = Mcp {
        child,
        stdin,
        stdout,
        next_id: 0,
    };
    mcp.request(
        "initialize",
        json!({"protocolVersion": "2024-11-05", "clientInfo": {"name": "confinement-test", "version": "1"}}),
    )
    .await;
    mcp
}

/// Ask the daemon to shut down (it stops the replay-server it started), and
/// kill it if it does not exit in time.
pub async fn shutdown_daemon(socket: &Path, daemon: &mut Child) {
    let body = json!({"type": "request", "command": "ct/daemon-shutdown", "seq": 1}).to_string();
    let frame = format!("Content-Length: {}\r\n\r\n{body}", body.len());
    #[cfg(unix)]
    let stream = tokio::net::UnixStream::connect(socket).await;
    #[cfg(windows)]
    let stream = match std::fs::read_to_string(socket).map(|p| p.trim().parse::<u16>()) {
        Ok(Ok(port)) => tokio::net::TcpStream::connect(("127.0.0.1", port)).await,
        _ => Err(std::io::Error::other("no daemon port file")),
    };
    if let Ok(mut stream) = stream {
        let _ = stream.write_all(frame.as_bytes()).await;
    }
    if timeout(Duration::from_secs(5), daemon.wait())
        .await
        .is_err()
    {
        let _ = daemon.kill().await;
    }
}

/// The DAP messages in `bytes`, a stream of `Content-Length: N\r\n\r\n`
/// frames, in order.
pub fn dap_messages(bytes: &[u8]) -> Vec<Value> {
    let mut messages = Vec::new();
    let mut rest = bytes;
    while let Some(header_end) = rest.windows(4).position(|w| w == b"\r\n\r\n") {
        let header = std::str::from_utf8(&rest[..header_end]).expect("a DAP header");
        let length: usize = header
            .lines()
            .find_map(|l| l.strip_prefix("Content-Length:"))
            .expect("a Content-Length header")
            .trim()
            .parse()
            .expect("a Content-Length value");
        if rest.len() < header_end + 4 + length {
            break;
        }
        let body = &rest[header_end + 4..header_end + 4 + length];
        rest = &rest[header_end + 4 + length..];
        messages.push(serde_json::from_slice(body).expect("a DAP message"));
    }
    messages
}

/// Whether `server` can run `exec_script` scripts confined on this host
/// (`trace check-confinement`), asked once per test binary.
pub fn scripts_can_be_confined(server: &Path) -> bool {
    static ANSWER: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ANSWER.get_or_init(|| {
        std::process::Command::new(server)
            .args(["trace", "check-confinement"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .expect("run trace check-confinement")
            .success()
    })
}

/// `args` for a `trace mcp` server whose test is not about script
/// confinement but runs `exec_script`: where the host cannot confine a
/// script (macOS, a Linux kernel without Landlock ABI 3), the server refuses
/// `exec_script` unless it opts out, so these tests opt out explicitly
/// there.  Wherever confinement exists they run the confined path an agent
/// gets.  The tests about confinement itself never call this.
pub fn with_script_opt_in<'a>(server: &Path, args: &[&'a str]) -> Vec<&'a str> {
    let mut out = args.to_vec();
    if !scripts_can_be_confined(server) {
        out.push("--allow-unconfined-scripts");
    }
    out
}
