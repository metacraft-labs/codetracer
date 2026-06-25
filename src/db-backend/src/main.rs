#![allow(clippy::enum_variant_names)]
#![allow(clippy::new_without_default)]
#![deny(clippy::panic)]
#![deny(clippy::unwrap_used)]
#![deny(clippy::expect_used)]
#![deny(clippy::exit)]
#![allow(clippy::uninlined_format_args)]
#![allow(dead_code)]

// TODO: deny when we cleanup
// dead code usage/add only
// specific allows
// #![deny(dead_code)]
use chrono::Local;
use clap::{Parser, Subcommand};
use log::LevelFilter;
use log::{error, info};
use std::fs::{File, create_dir_all, remove_file};
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::symlink as symlink_path;
#[cfg(windows)]
use std::os::windows::fs::symlink_dir as symlink_path;
use std::panic::PanicHookInfo;
use std::path::PathBuf;
use std::thread;
use std::{error::Error, panic};

mod calltrace;
mod core;
// M25 — Correlation markers. Both modules belong to the bin's tree
// because `main.rs::run_correlations_subcommand` reaches in directly.
mod correlation_index;
mod correlation_markers;
// M29 — Cross-process origin chain extender. Mirror of the lib.rs
// declaration above so the bin's `dap_handler` can reach the
// extender via the `crate::cross_process_origin` path.
mod cross_process_origin;
mod ctfs_trace_reader;
mod dap;
mod dap_error;
mod dap_handler;
mod dap_server;
mod dap_types;
mod db;
mod diff;
mod distinct_vec;
// M17 — the lib already exports these via `lib.rs`; the bin needs its
// own copies because dap_handler.rs is `mod dap_handler` here rather
// than a re-export from the lib. The lib's `#![allow(clippy::expect_used)]`
// does not flow into the bin compilation unit, so we suppress
// `expect_used` / `unwrap_used` / `panic` locally on the affected
// modules — they were not authored under the bin's stricter rules and
// the bin only depends on them transitively through dap_handler's
// M17 dispatch.
#[allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]
mod dwarf_index;
mod emulator_ffi;
#[allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]
mod emulator_origin;
#[allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]
mod emulator_session;
// M22 — WASM emulator data-watch primitive (browser-replay parity).
// Mirrors the lib.rs declaration above; the bin needs its own copy so
// `emulator_origin` and the `ReplaySession` trait impl on
// `EmulatorReplaySession` can reach the wrapper via the
// `crate::data_watch` path. See spec §6.6 / M22 milestone.
#[allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]
mod data_watch;
mod event_db;
mod expr_loader;
mod flow_preloader;
mod in_memory_trace_reader;
mod lang;
mod macro_sourcemap;
mod nim_mangling;
// M18 — Omniscient DB trait + FFI-backed default impl. Mirrors the
// lib.rs declaration above; the bin needs its own copy because
// `dap_handler` (and the M20 successor) reach for the trait via
// the `crate::omniscient_db` path.
#[allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]
mod omniscient_db;
// M20 — MCR omniscient origin tier. Mirrors the lib.rs declaration
// above; the bin needs its own copy so the dispatcher in
// `dap_handler::Handler::emulator_origin_chain` can route to the M20
// driver.
#[allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]
mod omniscient_origin;
mod origin_metadata_indexer;
// M21 — Per-trace eager-mode classification (spec §6.8.6 + §3.2.3).
// Mirrors the lib.rs declaration above; the bin needs its own copy
// because `dap_handler` reaches for the module via the
// `crate::eager_origin_mode` path.
mod eager_origin_mode;
mod origin_query;
mod paths;
mod program_search_tool;
// Column-Aware-Tracing-And-Deminification §P3 — per-trace Source Map
// V3 cache. Mirrors the lib.rs declaration above; the bin needs its
// own copy so `dap_handler` reaches for the cache via the
// `crate::sourcemap_cache` path.
mod query;
mod recreator_origin;
mod recreator_session;
mod replay;
mod sourcemap_cache;
// Column-Aware-Tracing-And-Deminification §P6.2 — `srcviews.dat`
// reader.  Mirror of the lib.rs declaration; the bin needs its own
// copy because `dap_handler::Handler::load_source_views` reaches for
// the module via the `crate::source_views` path.
mod source_views;
// Column-Aware-Tracing-And-Deminification §P4 — auto-format fallback.
// Mirrors the lib.rs declaration; the bin needs its own copy because
// the sourcemap_cache integration reaches for the module via
// `crate::autoformat`.
mod autoformat;
// Column-Aware-Tracing-And-Deminification §P5 — user-provided variable
// rename list.  Mirrors the lib.rs declaration; the bin needs its own
// copy because `sourcemap_cache` reaches for the module via the
// `crate::rename_list` path.
mod rename_list;
// Column-Aware-Tracing-And-Deminification §P8 — opt-in catalog
// autoload.  Mirrors the lib.rs declaration; the bin needs its own
// copy because `dap_handler::Handler::load_catalog_autoload` reaches
// for the module via the `crate::catalog_autoload` path.
mod catalog_autoload;
// M24 — Multi-trace session loading; mirror of the lib.rs declarations.
// The bin needs its own copies because `dap_server` reaches for the
// SessionHandler via the `crate::session_handler` path.
mod session_handler;
mod session_manifest;
#[allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]
mod stack_unwinder;
mod step_lines_loader;
mod task;
mod trace_processor;
mod trace_reader;
mod tracepoint_interpreter;
mod transport;
mod transport_endpoint;
mod value;

use crate::paths::{CODETRACER_PATHS, gc_stale_run_dirs, run_dir_for};

/// The replay server: a DAP-based replay backend for materialized-trace languages
/// (Ruby, Python, JS, shell, Wasm, etc.) as opposed to rr/gdb-based replay
#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    #[command(subcommand)]
    cmd: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    DapServer {
        /// Path to the Unix domain socket for DAP communication.
        /// If omitted, a path based on the process id will be used.
        socket_path: Option<std::path::PathBuf>,
        /// Use stdio transport for DAP communication instead of a Unix socket.
        #[arg(long)]
        stdio: bool,
        /// Column-Aware-Tracing-And-Deminification §P5.4 — path to a
        /// user-provided variable rename list (TOML).  When set,
        /// overrides the default `<recording-dir>/renames.toml` sibling
        /// lookup for every trace this server serves.  Per-launch
        /// `LaunchRequestArguments.renameList` still takes precedence
        /// when supplied.
        #[arg(long = "rename-list")]
        rename_list: Option<std::path::PathBuf>,
    },
    IndexDiff {
        structured_diff_path: std::path::PathBuf,
        trace_folder: std::path::PathBuf,
        // TODO: multitrace_folder: std::path::PathBuf,
    },
    /// M19 — `ct trace ...` subcommands for the origin-metadata streams.
    Trace {
        #[command(subcommand)]
        op: TraceOp,
    },
    /// M24 — `ct session <session.toml>` alias for the existing
    /// launch command. Validates the manifest and prints the
    /// resolved trace list (recording ids + paths + roles) so
    /// users can sanity-check a manifest before handing it to the
    /// DAP launch flow. The actual launch happens through
    /// `DapServer` once the frontend sends a `launch` request
    /// pointing at the manifest path.
    Session {
        /// Path to a `session.toml` manifest. The file is parsed
        /// through the same `SessionManifest::load` entry point the
        /// DAP launch flow uses, so any error surfaced here is
        /// identical to the one the frontend would see.
        manifest_path: std::path::PathBuf,
    },
}

/// `ct trace` subcommand surface — `probe` reports the capability
/// matrix, `origin-index` flips the mode (post-record CLI per
/// spec §6.8.6).
#[derive(Subcommand, Debug)]
enum TraceOp {
    /// Print the per-`VariableId` Path A / Path B / mixed capability
    /// matrix recorded in `meta_dat/origin-config.toml` plus the
    /// recorder name and version that produced the trace.
    Probe {
        /// Trace folder containing `meta_dat/origin-config.toml`.
        trace_folder: std::path::PathBuf,
    },
    /// Flip a trace's `origin-metadata` mode after the fact. The CLI
    /// dispatches to the materialized or native indexer based on the
    /// trace's existing CTFS streams; for M19 the dispatch is a
    /// metadata-only update (re-running the full indexer is a
    /// follow-on that requires the recorder pipeline to be available
    /// at re-index time).
    OriginIndex {
        trace_folder: std::path::PathBuf,
        #[arg(long, value_parser = ["off", "on", "lazy"])]
        mode: String,
    },
    /// M25 — Print the cross-trace correlation graph for a session.
    /// Reports which Send markers pair with which Recv markers, plus
    /// per-marker match/no-match/ambiguous counts. The session
    /// manifest is the entry point so multi-trace correlations
    /// surface immediately; for a single trace the manifest carries
    /// one entry. Reads marker source comments + TOML authoring path
    /// at command time so the output reflects the latest source
    /// state, mirroring the session-load scanner's behaviour
    /// (spec §3.1).
    Correlations {
        /// Path to a `session.toml` manifest, or a folder containing
        /// source files with `# codetracer:` comments / a
        /// `.codetracer/correlation-markers.toml`. When pointed at a
        /// folder, the loader skips the manifest step and just runs
        /// the marker scanner; useful for the diagnostic-only flow
        /// recommended in spec §10.
        session_or_source: std::path::PathBuf,
    },
    /// M29 — `ct trace origin <session.toml> --variable <name>` prints
    /// the value-origin chain for a queried variable, with each hop
    /// labelled by the owning process so multi-trace sessions surface
    /// the cross-process boundary. The session manifest is the entry
    /// point so the command works the same on single-trace and multi-
    /// trace sessions. Per the M29 ship-core directive the command
    /// currently emits the chain shape derived from the session's
    /// markers + the synthetic chain placeholders the M29 milestone
    /// uses for verification; full per-backend chain compute lands
    /// once each backend's recorder fixture is plumbed through to the
    /// CLI (deferred per M29 PROPERTIES).
    Origin {
        /// Path to a `session.toml` manifest. A single `.ct` is
        /// equivalent to a single-trace manifest.
        session: std::path::PathBuf,
        /// Variable / expression to query.
        #[arg(long)]
        variable: String,
        /// Optional thread tag (e.g. `fe:thread-1`). Defaults to the
        /// first thread of the first trace.
        #[arg(long)]
        thread: Option<String>,
        /// Optional step id; negative means "session current step".
        #[arg(long, default_value_t = -1i64)]
        step: i64,
        /// Output format. Defaults to `text` (human-readable). `json`
        /// emits the canonical `OriginChain` JSON; `markdown` emits
        /// the renderer-side markdown shape.
        #[arg(long, value_parser = ["text", "json", "markdown"], default_value = "text")]
        format: String,
    },
}

// Already panicking so the unwraps won't change anything
#[allow(clippy::unwrap_used)]
fn panic_handler(info: &PanicHookInfo) {
    error!("PANIC!!! {}", info);
}

#[cfg(all(feature = "browser-transport", not(feature = "io-transport")))]
fn main() {}

// #[cfg(not(any(feature = "io-transport", feature = "browser-transport")))]

#[cfg(feature = "io-transport")]
fn main() -> Result<(), Box<dyn Error>> {
    panic::set_hook(Box::new(panic_handler));

    // env_logger setup based and adapted from
    //   https://github.com/rust-cli/env_logger/issues/125#issuecomment-1406333500
    //   and https://github.com/rust-cli/env_logger/issues/125#issuecomment-1582209797 (imports)

    let tmp_path: PathBuf = { CODETRACER_PATHS.lock()?.tmp_path.clone() };
    // M-REC-11: db-backend is the spawner; it doesn't yet know any
    // recording_id at this very early bootstrap point (cli is parsed
    // below), so its own log/run directory still uses its pid.  This
    // is fine — its child replay-workers will be steered to their
    // own recording-id-derived directories via $CODETRACER_RUN_ID.
    let pid = std::process::id();
    let run_id = pid.to_string();
    // GUI-Test-Stabilization M12: before creating our own run dir,
    // reclaim any leftover `run-<pid>/` dirs whose owning PID is no
    // longer alive.  This is fast (a directory listing + one
    // `kill(pid, 0)` syscall per candidate) and synchronous so that
    // a freshly-spawned replay-server never piles on top of stale
    // 18 MB per-run blobs.  Best-effort: errors are swallowed
    // internally and never abort startup.
    let _gc_removed = gc_stale_run_dirs(&tmp_path, pid);
    let run_dir = run_dir_for(&tmp_path, &run_id)?;
    create_dir_all(&run_dir)?;

    let log_path = run_dir.join("replay-server.log");

    let target = Box::new(File::create(&log_path)?);

    env_logger::Builder::new()
        .format(|buf, record| {
            let thread = thread::current();
            let thread_id_as_string = &format!("{:?}", thread.id());
            let thread_name_or_id = thread.name().unwrap_or(thread_id_as_string);
            // format explanation: `:<char><alignment-where><width>`
            //   based on https://stackoverflow.com/a/41496138/438099
            let thread_column = format!("[{: <18}]", format!("{} thread", thread_name_or_id));
            writeln!(
                buf,
                "{} {}:{} {} [{}] - {}",
                thread_column,
                record.file().unwrap_or("unknown"),
                record.line().unwrap_or(0),
                Local::now().format("%H:%M:%S%.3f"),
                // too long? Local::now().format("%Y-%m-%dT%H:%M:%S%.3f"),
                record.level(),
                record.args()
            )
        })
        .target(env_logger::Target::Pipe(target))
        .filter(None, LevelFilter::Info)
        .init();

    let cli = Args::parse();
    info!("logging from replay-server");

    info!("pid {:?}", std::process::id());

    let run_id = std::process::id().to_string();

    let tmp_path: PathBuf = { CODETRACER_PATHS.lock()?.tmp_path.clone() };
    let run_dir = run_dir_for(&tmp_path, &run_id)?;
    // remove_dir_all(&run_dir)?;
    create_dir_all(&run_dir)?;
    let last_link = tmp_path.join("last");
    eprintln!("last {:?}", last_link.display());
    if last_link.exists() {
        // On Windows this is a directory symlink (`symlink_dir`), so remove_dir is required.
        let _ = std::fs::remove_dir(&last_link);
        let _ = remove_file(&last_link);
    }
    if let Err(e) = symlink_path(run_dir, &last_link) {
        // ignore if it can't happen: it's just a help for debugging
        eprintln!("error symlink {e:?}");
    }

    match cli.cmd {
        Commands::DapServer {
            socket_path,
            stdio,
            rename_list,
        } => {
            if stdio {
                // thread::spawn(move || {
                let res = db_backend::dap_server::run_stdio_with_options(rename_list);
                if let Err(e) = res {
                    error!("dap server run error: {e:?}");
                }
                // })
            } else {
                let socket_path = if let Some(p) = socket_path {
                    p
                } else {
                    let pid = std::process::id() as usize;
                    db_backend::dap_server::socket_path_for(pid)
                };
                // thread::spawn(move || {
                let res = db_backend::dap_server::run_with_options(&socket_path, rename_list);
                if let Err(e) = res {
                    error!("dap server run error: {e:?}");
                }
                // })
            };
        }
        Commands::IndexDiff {
            structured_diff_path,
            trace_folder,
            // multitrace_folder,
        } => {
            let raw = std::fs::read_to_string(structured_diff_path)?;
            let structured_diff = serde_json::from_str::<diff::Diff>(&raw)?;
            diff::index_diff(structured_diff, &trace_folder)?;
        }
        Commands::Trace { op } => {
            run_trace_subcommand(op)?;
        }
        Commands::Session { manifest_path } => {
            run_session_subcommand(&manifest_path)?;
        }
    }

    Ok(())
}

/// M24 `ct session <session.toml>` alias — parses the manifest and
/// prints a one-line summary per trace plus the correlation mode. The
/// command is intentionally read-only so users can verify their
/// manifest before launching the full DAP session through the
/// frontend.
fn run_session_subcommand(manifest_path: &std::path::Path) -> Result<(), Box<dyn Error>> {
    use crate::session_manifest::SessionManifest;
    let manifest = SessionManifest::load(manifest_path)
        .map_err(|e| -> Box<dyn Error> { format!("failed to load session manifest: {e}").into() })?;
    println!(
        "session manifest {} — version {} ({} trace(s), correlation_index_mode={})",
        manifest_path.display(),
        manifest.version,
        manifest.traces.len(),
        manifest.correlation.index_mode.as_str(),
    );
    for (idx, trace) in manifest.traces.iter().enumerate() {
        let resolved = manifest.resolved_trace_path(trace);
        println!(
            "  [{idx}] recording_id={} role={} prefix={} path={}",
            trace.recording_id,
            trace.role,
            trace.default_thread_prefix,
            resolved.display(),
        );
    }
    Ok(())
}

/// Dispatcher for the `ct trace ...` family.  Reads
/// `meta_dat/origin-config.toml` (or creates an empty one when the
/// trace lacks it) and applies the requested operation.
fn run_trace_subcommand(op: TraceOp) -> Result<(), Box<dyn Error>> {
    use crate::origin_metadata_indexer::{ORIGIN_CONFIG_FILE, OriginConfig, OriginMode, ProbeReport};
    match op {
        TraceOp::Probe { trace_folder } => {
            let config_path = trace_folder.join("meta_dat").join(ORIGIN_CONFIG_FILE);
            let config = if config_path.exists() {
                OriginConfig::read_from_path(&config_path)?
            } else {
                OriginConfig::new(OriginMode::Off)
            };
            let report = ProbeReport::from_config(&config);
            print!("{}", report.render());
        }
        TraceOp::OriginIndex { trace_folder, mode } => {
            let new_mode =
                OriginMode::parse(&mode).ok_or_else(|| -> Box<dyn Error> { "invalid --mode value".into() })?;
            let meta_dat = trace_folder.join("meta_dat");
            std::fs::create_dir_all(&meta_dat)?;
            let config_path = meta_dat.join(ORIGIN_CONFIG_FILE);
            let mut config = if config_path.exists() {
                OriginConfig::read_from_path(&config_path)?
            } else {
                OriginConfig::new(OriginMode::Off)
            };
            config.set_mode(new_mode);
            config.write_to_path(&config_path)?;
            println!("origin-metadata mode set to {}", new_mode.as_str());
        }
        TraceOp::Correlations { session_or_source } => {
            run_correlations_subcommand(&session_or_source)?;
        }
        TraceOp::Origin {
            session,
            variable,
            thread,
            step,
            format,
        } => {
            run_origin_subcommand(&session, &variable, thread.as_deref(), step, &format)?;
        }
    }
    Ok(())
}

/// M25 — `ct trace correlations <session.toml | source-dir>` prints
/// the cross-trace correlation graph. We pre-walk the marker scanner
/// inputs in the same priority order the session-load layer uses
/// (spec §3.1) and surface a `CorrelationReport` rendered through
/// [`crate::correlation_index::CorrelationReport::render`].
///
/// The diagnostic flow per spec §10 makes this command **read-only**:
/// no tracepoint cache is mutated, no trace files are rewritten.
fn run_correlations_subcommand(path: &std::path::Path) -> Result<(), Box<dyn Error>> {
    use crate::correlation_index::{CorrelationReport, MarkerEventView, PairIndex};
    use crate::correlation_markers::{MarkerPayload, MarkerScanner};

    // Resolve the source root. When the caller passes a session.toml
    // we use its parent directory; when they pass a folder we treat
    // it directly as the source root. Both modes go through the
    // same scanner.
    let source_root = if path.is_file() {
        path.parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| path.to_path_buf())
    } else {
        path.to_path_buf()
    };

    let result = MarkerScanner::scan_roots(&[source_root.as_path()]);

    // Also pull in any `.codetracer/correlation-markers.toml`.
    let toml_path = source_root.join(".codetracer").join("correlation-markers.toml");
    let toml_markers = if toml_path.is_file() {
        MarkerScanner::load_toml(&toml_path).unwrap_or_default()
    } else {
        Vec::new()
    };

    // The CLI does not have a live recorder available, so we build
    // a synthetic `MarkerEventView` from each declared marker as if
    // it fired exactly once. This gives users a "what the report
    // would look like when these markers fire" preview — the M25
    // discipline is to ship the algorithm + report shape and let the
    // recorder-integration follow-on flesh out live firings.
    let mut events: Vec<MarkerEventView> = Vec::new();
    let mut combined = result.markers.clone();
    combined.extend(toml_markers);
    for (counter, decl) in combined.into_iter().enumerate() {
        let payload = MarkerPayload {
            marker_id: counter,
            boundary_id: decl.boundary_id.clone(),
            direction: decl.direction,
            key_text: decl.key_text.clone(),
            // Synthetic key value: the textual key expression doubles
            // as the value placeholder so the CLI can show ambiguous
            // / matched buckets even without live recorder data.
            key_value: decl.key_text.clone(),
            show_text: decl.show_text.clone(),
            show_value: decl.show_text.clone(),
            description: decl.description.clone(),
            format: decl.format.clone(),
        };
        events.push(MarkerEventView::new(
            "(synthetic)",
            counter as i64,
            decl.location.path.clone(),
            decl.location.line,
            payload,
        ));
    }
    let index = PairIndex::build(&events);
    let report = CorrelationReport::from_index(&index);
    print!("{}", report.render());
    for diag in result.diagnostics {
        eprintln!("diagnostic {}:{}: {}", diag.path.display(), diag.line, diag.error,);
    }
    Ok(())
}

/// Heuristic path-A synthesis from the source-line text. When the line
/// has the shape `var = literal-or-name`, we emit a `TrivialCopy` /
/// `Literal` path-A descriptor; otherwise we fall through to Path B.
/// This is a deliberate "no-recorder-side integration" placeholder —
/// production path-A descriptors come from the recorder's event stream
/// per spec §6.8.7.
fn synthesise_path_a(_source_expr_text: &str) -> Option<crate::origin_metadata_indexer::PathAAssignment> {
    // Without a per-language parser at this layer we cannot reliably
    // distinguish TrivialCopy / Literal / Computational from the
    // source text alone — that's exactly what the M2 origin classifier
    // does, and it requires a full pattern set. We therefore leave
    // every change on Path B; the capability matrix marks every
    // variable as `path_b` and the originmeta records still ship.
    None
}

/// M29 — `ct trace origin <session.toml> --variable <name> ...`
/// renders the value-origin chain for a queried variable, with each
/// hop labelled by the owning process.
///
/// **Scope per the M29 ship-core directive.** The recorder-driven
/// fixture infrastructure described in the E2E design doc §3.4
/// (frontend Vite plugin + per-backend recorder + `record.sh`) is
/// deferred — without it, the CLI cannot drive a live per-backend
/// single-trace chain compute. The command therefore emits the
/// chain shape derived from the session's correlation markers + a
/// synthetic per-trace skeleton drawn from the markers themselves.
/// The text/json/markdown rendering paths are exercised end-to-end;
/// each rendered hop carries the owning process's role + recording
/// id so multi-trace surfaces are visible.
fn run_origin_subcommand(
    session: &std::path::Path,
    variable: &str,
    thread: Option<&str>,
    step: i64,
    format: &str,
) -> Result<(), Box<dyn Error>> {
    use crate::correlation_index::{MarkerEventView, PairIndex};
    use crate::correlation_markers::{MarkerPayload, MarkerScanner};
    use crate::cross_process_origin::{SiblingContinuation, TraceIdentity, apply_cross_process_clause};
    use crate::session_manifest::SessionManifest;
    use crate::task::{Location, OriginChain, OriginHop, OriginKind, OriginMetrics, Terminator, TerminatorKind};

    let manifest = SessionManifest::load(session)
        .map_err(|e| -> Box<dyn Error> { format!("failed to load session manifest: {e}").into() })?;

    // Scan the session's source root for correlation markers so the
    // CLI can identify which traces participate in cross-process
    // chains.
    let scan_result = MarkerScanner::scan_roots(&[manifest.base_dir.as_path()]);
    let mut events: Vec<MarkerEventView> = Vec::new();
    for (idx, decl) in scan_result.markers.iter().enumerate() {
        // Best-effort recording-id assignment: scan markers under
        // each trace's role label. The marker's source file path is
        // used as a hint for which trace owns it.
        let owning_recording_id = manifest
            .traces
            .iter()
            .find(|t| decl.location.path.contains(&t.role) || decl.location.path.contains(&t.recording_id.0))
            .map(|t| t.recording_id.0.clone())
            .unwrap_or_else(|| {
                manifest
                    .traces
                    .first()
                    .map(|t| t.recording_id.0.clone())
                    .unwrap_or_default()
            });
        let payload = MarkerPayload {
            marker_id: idx,
            boundary_id: decl.boundary_id.clone(),
            direction: decl.direction,
            key_text: decl.key_text.clone(),
            key_value: decl.key_text.clone(),
            show_text: decl.show_text.clone(),
            show_value: decl.show_text.clone(),
            description: decl.description.clone(),
            format: decl.format.clone(),
        };
        events.push(MarkerEventView::new(
            owning_recording_id,
            idx as i64,
            decl.location.path.clone(),
            decl.location.line,
            payload,
        ));
    }
    let pair_index = PairIndex::build(&events);

    // Build a synthetic frontend-side chain ending at the receive
    // marker (when one is declared) so the cross-process composer
    // can populate the cross-process spans.
    let first_trace = manifest
        .traces
        .first()
        .ok_or_else(|| -> Box<dyn Error> { "manifest has no [[trace]] entries".into() })?;
    let hop = OriginHop {
        kind: OriginKind::TrivialCopy,
        target_expr: variable.to_string(),
        source_expr: variable.to_string(),
        source_variable: None,
        location: Location {
            path: format!("<session:{}>", first_trace.role),
            line: 1,
            ..Location::default()
        },
        source_text: format!("{variable} <- session origin entry point"),
        step_id: step.max(0),
        frame_transition: None,
        operand_snapshots: Vec::new(),
        truncated_operands: false,
        confidence: 0.5,
        classification_provenance: Some("M29 CLI: ct trace origin <session.toml>".to_string()),
        correlation_transition: None,
    };
    let chain = OriginChain {
        query_variable: variable.to_string(),
        query_step_id: step,
        hops: vec![hop],
        terminator: Terminator::new(TerminatorKind::UnknownSource),
        truncated: false,
        continuation_token: None,
        metrics: OriginMetrics::default(),
        cross_process_spans: Vec::new(),
        confidence: 0.5,
    };

    let identity = TraceIdentity::new(&first_trace.recording_id.0, &first_trace.role);
    let mut noop_resolver = |_: &str, _: i64, _: &str| -> Option<SiblingContinuation> { None };
    let (chain, _outcome) = apply_cross_process_clause(
        chain,
        &identity,
        &pair_index,
        &mut noop_resolver as crate::cross_process_origin::SiblingChainResolver,
    );

    match format {
        "json" => {
            let json = serde_json::to_string_pretty(&chain)?;
            println!("{json}");
        }
        "markdown" => {
            println!("# Origin chain — `{}`", variable);
            println!();
            if let Some(thread) = thread {
                println!("- **Thread:** `{}`", thread);
            }
            println!("- **Session:** `{}`", session.display());
            println!("- **Trace count:** {}", manifest.traces.len());
            println!();
            println!("## Hops");
            for (i, hop) in chain.hops.iter().enumerate() {
                let owning_role = chain
                    .cross_process_spans
                    .iter()
                    .find(|s| (s.first_hop_index as usize..=s.last_hop_index as usize).contains(&i))
                    .map(|s| s.role.as_str())
                    .unwrap_or("?");
                println!(
                    "{}. **[{}]** {} = `{}` ({:?}) at `{}:{}`",
                    i + 1,
                    owning_role,
                    hop.target_expr,
                    hop.source_expr,
                    hop.kind,
                    hop.location.path,
                    hop.location.line
                );
            }
            println!();
            println!("## Terminator");
            println!("- **Kind:** `{:?}`", chain.terminator.kind);
            if !chain.terminator.expression.is_empty() {
                println!("- **Expression:** `{}`", chain.terminator.expression);
            }
        }
        _ => {
            // text (default)
            println!("origin chain for `{}` in session `{}`", variable, session.display());
            println!("--------------------------------------------------");
            if let Some(thread) = thread {
                println!("thread: {}", thread);
            }
            println!("traces: {}", manifest.traces.len());
            for trace in &manifest.traces {
                println!(
                    "  - recording_id={} role={} prefix={}",
                    trace.recording_id, trace.role, trace.default_thread_prefix
                );
            }
            println!();
            for (i, hop) in chain.hops.iter().enumerate() {
                let owning_role = chain
                    .cross_process_spans
                    .iter()
                    .find(|s| (s.first_hop_index as usize..=s.last_hop_index as usize).contains(&i))
                    .map(|s| s.role.as_str())
                    .unwrap_or("?");
                println!(
                    "hop {}: [{}] {:?} {} <- {} at {}:{}",
                    i + 1,
                    owning_role,
                    hop.kind,
                    hop.target_expr,
                    hop.source_expr,
                    hop.location.path,
                    hop.location.line
                );
                if let Some(tx) = &hop.correlation_transition {
                    println!(
                        "    crosses to recording={} step={} (boundary={}, key={})",
                        tx.correlated_recording_id, tx.correlated_step_id, tx.boundary_id, tx.match_key_value
                    );
                }
            }
            println!(
                "terminator: {:?} {}",
                chain.terminator.kind, chain.terminator.expression
            );
        }
    }
    Ok(())
}
