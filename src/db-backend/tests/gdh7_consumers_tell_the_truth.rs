//! GDH-M7 — **the consumer side tells the truth, including backwards.**
//!
//! Campaign: `codetracer-specs/Planned-Features/
//! GDScript-Hot-Reload-Multi-Version-Sources.md` §7, milestone `GDH-M7`.
//!
//! # What this file grades
//!
//! GDH-M6 proved the CONTAINER is right: a real Godot recording of one
//! `res://probe.gd` hot-reloaded twice carries three `paths.dat` entries with
//! the identical string, three raw source views hash-equal to the three
//! fixtures, two `TagSourceReload` markers, and disjoint step ranges per
//! version. That milestone's consumer-side falsifier arms were *simulated in
//! Python*, over the container, because the real consumer could not answer at
//! all.
//!
//! This file grades the REAL consumer — the Rust db-backend, through its
//! production `Handler` DAP entry points — on the same recording. Design §2.2
//! measured three collapses on this side and all three shipped:
//!
//! * `Db::path_map` was `HashMap<String, PathId>` built LAST-WINS, so a
//!   pre-reload step resolved by name to the newest version;
//! * `bundled_source_path` had no version term, so every raw view materialised
//!   on top of the previous one and the last silently won;
//! * `fuzzy_path_id_for`'s stage 6 returned `Some` only when
//!   `matches.len() == 1`, so a second version turned a filename lookup that
//!   used to resolve into a silent `None`.
//!
//! # No mocks
//!
//! `allowed_mocks: none`, and none are used. The container is the real
//! engine-recorded `.ct`; the reader is `CTFSTraceReader::open`; the handler is
//! `Handler::construct_with_reader(TraceKind::Materialized, …)` built exactly
//! the way `dap_server::setup` builds one for a `.ct` launch, including
//! `load_source_views` and `load_bundled_sources`; and every stop position is
//! produced by driving the production `next_dap` / `step_back_dap` runners and
//! reading the `ct/complete-move` EVENT the GUI consumes — not by reading the
//! `Db` directly.
//!
//! # No silent skip
//!
//! Every prerequisite is a hard failure. The containers are committed, so a
//! missing one is a repository-integrity error. `ct-print` — used as a SECOND,
//! INDEPENDENT container reader for the reload markers, deliberately not the
//! reader under test — must be present and must produce a dump this harness
//! proves COMPLETE by the line-count-equals-header-counts rule. Its absence is
//! a CHECK-FAIL, never a skip.
//!
//! # Falsifier arms
//!
//! Each is a real mutation of the shipped code, behind a cargo feature that is
//! off in `default`. Run one with:
//!
//! ```text
//! cargo test --features gdh7-falsify-string-keyed-cache \
//!            --test gdh7_consumers_tell_the_truth
//! ```
//!
//! | feature | restores | must redden |
//! |---|---|---|
//! | `gdh7-falsify-string-keyed-cache` | §7.2's string-keyed source cache | reverse-navigation |
//! | `gdh7-falsify-single-destination` | `load_bundled_sources`' one-file write | reverse-navigation |
//! | `gdh7-falsify-zero-source-generation` | the literal `0` in `Location` | through-DAP attribution |
//! | `gdh7-falsify-fuzzy-unique-only` | stage 6's `matches.len() == 1` | resolution (reported under its OWN name) |
//!
//! Every arm must leave the SINGLE-VERSION CONTROL green. An arm that fails
//! everywhere has not been shown to discriminate — this campaign has now found
//! seven falsifiers that could not.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::mpsc;

use codetracer_trace_types::StepId;
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::dap::{DapMessage, ProtocolMessage, Request};
use db_backend::dap_handler::Handler;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::TraceKind;
use db_backend::trace_reader::TraceReader;
use serde_json::Value as JsonValue;

// ---------------------------------------------------------------------------
// Counted assertions — Verification-Harness-Traps.md trap 4c.
//
// A check that tracks its own assertion count and FAILS when it does not reach
// the number written at the end of it turns a silent skip into a red run on the
// spot. Every number below was written from a run, never guessed.
// ---------------------------------------------------------------------------

struct Checker {
    gate: &'static str,
    asserted: usize,
    failed: Vec<String>,
}

impl Checker {
    fn new(gate: &'static str) -> Self {
        Checker {
            gate,
            asserted: 0,
            failed: Vec::new(),
        }
    }

    /// One counted claim.
    fn ck(&mut self, ok: bool, what: String) {
        self.asserted += 1;
        if ok {
            println!("[gdh7]   ok   {what}");
        } else {
            println!("[gdh7]   FAIL {what}");
            self.failed.push(what);
        }
    }

    fn eq<T: std::fmt::Debug + PartialEq>(&mut self, got: T, want: T, what: &str) {
        let ok = got == want;
        self.ck(ok, format!("{what} (got {got:?}, want {want:?})"));
    }

    /// The instrument itself failed. Per trap 3 and the campaign's rule that
    /// rc 2 is a DRIVER-FAIL and never a kill, this is reported under its own
    /// name and panics immediately — it must never be read as the subject
    /// having been measured and found wrong.
    fn check_fail(&self, why: String) -> ! {
        panic!("GDH7-CHECK-FAIL[{}]: {why}", self.gate);
    }

    fn finish(self, expected_claims: usize) {
        println!(
            "[gdh7] {}: {} assertion(s), {} red",
            self.gate,
            self.asserted,
            self.failed.len()
        );
        assert_eq!(
            self.asserted, expected_claims,
            "GDH7-FAIL[{}]: assertion count is {}, expected {} — this gate did not make all the \
             claims it is supposed to make",
            self.gate, self.asserted, expected_claims
        );
        assert!(
            self.failed.is_empty(),
            "GDH7-FAIL[{}]: {} of {} claims red:\n  {}",
            self.gate,
            self.failed.len(),
            self.asserted,
            self.failed.join("\n  ")
        );
    }
}

// ---------------------------------------------------------------------------
// Fixtures.
// ---------------------------------------------------------------------------

const FIXTURE_PATH: &str = "res://probe.gd";

/// The three fixture sources, in version order. Their probe LINE NUMBERS are
/// disjoint by construction (GDH-M6's own anti-vacuity requires it), and their
/// probe TEXT differs at every line, so "the right text at that line" is a real
/// discrimination rather than two versions agreeing for free.
const FIXTURE_SOURCES: [&str; 3] = ["probe_v1.gd", "probe_v2.gd", "probe_v3.gd"];

fn fixtures_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("gdscript")
}

fn reloaded_dir() -> PathBuf {
    fixtures_root().join("gdh7_reloaded")
}

fn control_dir() -> PathBuf {
    fixtures_root().join("gdh7_control")
}

fn container(dir: &Path) -> PathBuf {
    let ct = dir.join("gdscript_trace.ct");
    assert!(
        ct.is_file(),
        "GDH7-CHECK-FAIL: fixture container missing at {} — this test must NOT silently skip; \
         it is committed, so absence is a repository-integrity error",
        ct.display()
    );
    ct
}

/// `ct-print`, the campaign's container inspector, resolved at the sibling path
/// every GDH driver already uses.
///
/// It is a SECOND, INDEPENDENT reader, deliberately not the one under test: the
/// reload markers this harness ties its navigation to must be read from the
/// container rather than assumed from the fixture, and reading them with the
/// very reader whose correctness is the subject would be circular.
fn ct_print() -> PathBuf {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../codetracer-trace-format-nim/ct-print")
        .canonicalize()
        .unwrap_or_else(|e| {
            panic!(
                "GDH7-CHECK-FAIL: ct-print not resolvable next to the workspace \
                 (../../../codetracer-trace-format-nim/ct-print): {e}. It is this harness's \
                 independent container reader and its absence is an instrument failure, not a \
                 reason to skip."
            )
        });
    assert!(
        p.is_file(),
        "GDH7-CHECK-FAIL: ct-print at {} is not a file",
        p.display()
    );
    p
}

/// One `ct-print --events` dump, PROVEN COMPLETE.
///
/// Completeness is arithmetic, never `lines > 0`: `1 + steps + 2*calls + io +
/// source_reloads`. A truncated dump is non-empty and would satisfy a bare
/// check just as well as a good one, while yielding a smaller marker set — and
/// "there are no markers between these steps" read off a truncated dump is the
/// silent self-pass this campaign exists to keep out.
struct Dump {
    header: JsonValue,
    /// `(step_index, reload_ordinal, old_path_id, new_path_id)` per marker.
    markers: Vec<(u64, u64, u64, u64)>,
    /// Every `step_index` the INDEPENDENT reader reports a step at.
    ///
    /// This is the container's own step index space, and it is not contiguous:
    /// a `TagSourceReload` marker CONSUMES an index, so the set has a hole at
    /// each marker. Collected so the reader under test can be checked against
    /// it rather than against itself — see
    /// `gdh7_no_step_is_attributed_to_the_wrong_version_through_dap`, where
    /// the generation comparison would otherwise be reader-versus-reader.
    step_indices: BTreeSet<u64>,
}

fn ct_print_events(ct: &Path) -> Dump {
    let out = Command::new(ct_print())
        .arg("--events")
        .arg(ct)
        .output()
        .unwrap_or_else(|e| panic!("GDH7-CHECK-FAIL: could not run ct-print on {}: {e}", ct.display()));
    assert!(
        out.status.success(),
        "GDH7-CHECK-FAIL: ct-print exited {:?} on {}\nstderr: {}",
        out.status.code(),
        ct.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    let lines: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
    assert!(!lines.is_empty(), "GDH7-CHECK-FAIL: ct-print produced an empty dump");

    let header: JsonValue =
        serde_json::from_str(lines[0]).unwrap_or_else(|e| panic!("GDH7-CHECK-FAIL: ct-print header is not JSON: {e}"));
    let counts = header.get("counts").expect("ct-print header carries `counts`");
    let n = |k: &str| counts.get(k).and_then(JsonValue::as_u64).unwrap_or(0);
    let expected = 1 + n("steps") + 2 * n("calls") + n("io_events") + n("source_reloads");
    assert_eq!(
        lines.len() as u64,
        expected,
        "GDH7-CHECK-FAIL: ct-print dump of {} is INCOMPLETE — {} lines, but \
         1 + steps({}) + 2*calls({}) + io({}) + source_reloads({}) = {}. A cardinality mismatch \
         measured against a truncated dump is an instrument failure, not a finding about the \
         subject.",
        ct.display(),
        lines.len(),
        n("steps"),
        n("calls"),
        n("io_events"),
        n("source_reloads"),
        expected
    );

    let mut markers = Vec::new();
    let mut step_indices: BTreeSet<u64> = BTreeSet::new();
    for line in &lines[1..] {
        let ev: JsonValue = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if ev.get("kind").and_then(JsonValue::as_str) == Some("step")
            && let Some(i) = ev.get("step_index").and_then(JsonValue::as_u64)
        {
            step_indices.insert(i);
        }
        if ev.get("kind").and_then(JsonValue::as_str) != Some("source_reload") {
            continue;
        }
        let step_index = ev.get("step_index").and_then(JsonValue::as_u64).unwrap_or(u64::MAX);
        let reload_ordinal = ev.get("reload_ordinal").and_then(JsonValue::as_u64).unwrap_or(0);
        let changed = ev
            .get("changed")
            .and_then(JsonValue::as_array)
            .cloned()
            .unwrap_or_default();
        let (old_id, new_id) = changed
            .first()
            .map(|c| {
                (
                    c.get("old_path_id").and_then(JsonValue::as_u64).unwrap_or(u64::MAX),
                    c.get("new_path_id").and_then(JsonValue::as_u64).unwrap_or(u64::MAX),
                )
            })
            .unwrap_or((u64::MAX, u64::MAX));
        markers.push((step_index, reload_ordinal, old_id, new_id));
    }

    // Instrument completeness, second leg: the number of step LINES must equal
    // the header's own step count. The line-count arithmetic above proves the
    // dump is not truncated; this proves the step half of it was parsed, so a
    // set that is short because `step_index` was spelled differently cannot be
    // mistaken for a container with holes in it. An instrument failure, so it
    // is a CHECK-FAIL and not a counted claim.
    let declared_steps = counts.get("steps").and_then(JsonValue::as_u64).unwrap_or(0);
    assert_eq!(
        step_indices.len() as u64,
        declared_steps,
        "GDH7-CHECK-FAIL: parsed {} step index/indices out of a dump whose header declares {} \
         steps. The step index set below is used to decide which indices the container does NOT \
         hold, and a short set would invent holes.",
        step_indices.len(),
        declared_steps
    );

    Dump {
        header,
        markers,
        step_indices,
    }
}

// ---------------------------------------------------------------------------
// Reader + handler, built the production way.
// ---------------------------------------------------------------------------

fn open_reader(ct: &Path) -> Arc<dyn TraceReader> {
    Arc::new(
        CTFSTraceReader::open(ct)
            .unwrap_or_else(|e| panic!("GDH7-CHECK-FAIL: CTFS open failed for {}: {e}", ct.display())),
    )
}

fn build_handler(ct: &Path, reader: Arc<dyn TraceReader>) -> Handler {
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.set_trace_folder(ct);
    handler.load_source_views(ct);

    // ---- HERMETICITY: this run must not read a previous run's extraction ---
    //
    // `Handler::load_bundled_sources` extracts into
    // `temp_dir()/codetracer-bundled-sources/<hash of the container path>`
    // (`dap_handler.rs`), a directory that PERSISTS between runs and is keyed
    // by the container path ALONE — not by the cargo features the binary was
    // built with. So a falsifier arm that writes fewer destinations than a
    // correct build reads the correct build's leftovers at the destinations it
    // skipped, and the arm's kill count silently depends on what ran before
    // it. MEASURED, which is why this is here rather than in a comment:
    // `gdh7-falsify-single-destination` reddens TWO claims in each gate
    // against a clean extraction root and only ONE against a root a correct
    // build had already filled.
    //
    // A first `load_bundled_sources` is the only way to learn the root — the
    // hash is private to the production function, and re-deriving it here is
    // exactly the write/read layout drift the shipped code avoids by having
    // one `bundled_source_path`. So: discover, WIPE, extract for real, and
    // verify each step. The wipe is of a directory this process's own
    // extraction owns, and it is refilled before anything reads it.
    handler.load_bundled_sources(ct);
    if let Some(root) = handler.bundled_sources_root.clone() {
        std::fs::remove_dir_all(&root).unwrap_or_else(|e| {
            panic!(
                "GDH7-CHECK-FAIL: could not clear the bundled-sources root {}: {e}. Leaving it \
                 would let this run read an earlier, differently-built run's layout.",
                root.display()
            )
        });
        assert!(
            !root.exists(),
            "GDH7-CHECK-FAIL: bundled-sources root {} survived its own removal",
            root.display()
        );
        handler.bundled_sources_root = None;
        handler.load_bundled_sources(ct);
        assert_eq!(
            handler.bundled_sources_root.as_deref(),
            Some(root.as_path()),
            "GDH7-CHECK-FAIL: the second extraction did not land where the first did; the \
             destination is supposed to be deterministic in the container path"
        );
    }

    handler.initialized = true;
    handler
}

fn make_request(command: &str) -> Request {
    Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: command.to_string(),
        arguments: JsonValue::Null,
    }
}

/// The `location` object out of the `ct/complete-move` EVENT — the production
/// wire surface the Nim frontend's `sourceRevisionKey` reads.
///
/// Per trap 2: a `success: true` on any response is NOT evidence. This returns
/// the produced artefact — the location the debugger says it is at — and the
/// callers assert its bytes and its fields.
fn move_location(rx: &mpsc::Receiver<DapMessage>) -> JsonValue {
    let mut found = None;
    while let Ok(msg) = rx.try_recv() {
        if let DapMessage::Event(e) = msg
            && e.event == "ct/complete-move"
        {
            found = e.body.get("location").cloned();
        }
    }
    found.expect("GDH7-CHECK-FAIL: no ct/complete-move event carried a `location`")
}

/// Position the session at `step` and read the stop the debugger reports.
///
/// `jump_to` positions; `next_dap` is what makes the handler EMIT the
/// `ct/complete-move` event, and it advances by one first — so the stop this
/// returns is the one AFTER `step`, and callers must read the position out of
/// the returned location (`rrTicks`) rather than assume it is `step`. Getting
/// that backwards would make the gate assert a version against the wrong
/// step's expectation, which is the same class of error the gate exists to
/// catch.
fn stop_after(handler: &mut Handler, step: StepId) -> JsonValue {
    handler.step_id = step;
    handler
        .replay
        .jump_to(step)
        .unwrap_or_else(|e| panic!("GDH7-CHECK-FAIL: jump_to({step:?}) failed on a materialized trace: {e}"));
    step_forward(handler)
}

/// One production `stepIn`, returning the stop it lands on.
///
/// `stepIn` and not `next`, and the difference is the whole reason the walk
/// below is worth anything. DAP `next` is a step-OVER: it stays in `_process`
/// and never descends into `probe()`, where the fixture's version-discriminating
/// lines live. A first cut of this harness walked with `next_dap`, reported
/// **185 stops with every `sourceGeneration` correct**, and examined **ZERO**
/// probe lines — a green-looking walk over the one part of the recording that
/// cannot tell the versions apart. Only the `probe_stops` count caught it; it is
/// trap 4a's "a check whose SUBJECT can be emptied passes over the emptying",
/// and the count assertion is kept for exactly that reason.
fn step_forward(handler: &mut Handler) -> JsonValue {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    handler
        .step_in_dap(make_request("stepIn"), tx)
        .unwrap_or_else(|e| panic!("GDH7-CHECK-FAIL: step_in_dap failed: {e}"));
    move_location(&rx)
}

/// What the CONTAINER says about the stop the debugger just reported: the
/// version ordinal of the step at `rrTicks`, read from the reader's own path
/// table.
fn container_ordinal_at(reader: &Arc<dyn TraceReader>, loc: &JsonValue) -> Option<i64> {
    let ticks = ticks_of(loc);
    if ticks < 0 {
        return None;
    }
    let step = reader.step(StepId(ticks))?;
    Some(reader.path_version_ordinal(step.path_id))
}

/// Walk the WHOLE recording with the production `next` runner, collecting every
/// stop the debugger reports.
///
/// The entry's claim is about "every stop position reported by the debugger,
/// across the whole recording", so the walk is the measurement and a jump-based
/// sample would be a weaker one. Bounded by the container's own step count: a
/// runner that stops advancing must end the walk, and the caller asserts the
/// number of stops against what the container declares.
fn walk_all_stops(handler: &mut Handler, reader: &Arc<dyn TraceReader>) -> Vec<JsonValue> {
    let mut stops = Vec::new();
    let mut loc = stop_after(handler, StepId(0));
    stops.push(loc.clone());
    let bound = reader.step_count() + 8;
    let mut last = ticks_of(&loc);
    for _ in 0..bound {
        loc = step_forward(handler);
        let t = ticks_of(&loc);
        if t <= last {
            break; // the runner stopped advancing — end of the recording
        }
        last = t;
        stops.push(loc.clone());
    }
    stops
}

/// One production `stepBack`, returning the stop it lands on.
fn step_back(handler: &mut Handler) -> JsonValue {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    handler
        .step_back_dap(make_request("stepBack"), None, tx)
        .unwrap_or_else(|e| panic!("GDH7-CHECK-FAIL: step_back_dap failed: {e}"));
    move_location(&rx)
}

fn generation_of(loc: &JsonValue) -> i64 {
    loc.get("sourceGeneration")
        .and_then(JsonValue::as_i64)
        .expect("GDH7-CHECK-FAIL: the wire `location` carries no `sourceGeneration`")
}

fn digest_of(loc: &JsonValue) -> String {
    loc.get("sourceDigest")
        .and_then(JsonValue::as_str)
        .unwrap_or_default()
        .to_string()
}

fn line_of(loc: &JsonValue) -> i64 {
    loc.get("line").and_then(JsonValue::as_i64).unwrap_or(-1)
}

fn ticks_of(loc: &JsonValue) -> i64 {
    loc.get("rrTicks").and_then(JsonValue::as_i64).unwrap_or(-1)
}

/// The source line the CONSUMER CHAIN serves for this stop — the destination
/// `bundled_source_path` derives from the stop's own reported generation, read
/// through the production `ExprLoader::get_source_line_v2`.
///
/// This is the whole chain under test in one call: the reader says which
/// version the step belongs to, the wire carries it, and the materialised
/// bundle is keyed by it.
fn served_line(handler: &mut Handler, loc: &JsonValue) -> String {
    let root = handler
        .bundled_sources_root
        .clone()
        .unwrap_or_else(|| panic!("GDH7-CHECK-FAIL: no bundled-sources root — load_bundled_sources extracted nothing"));
    let generation = generation_of(loc);
    let row = line_of(loc).max(0) as usize;
    let probe = PathBuf::from(FIXTURE_PATH);
    let (text, _origin) = handler
        .expr_loader
        .get_source_line_v2(&probe, row, Some(&root), generation);
    text
}

/// The fixture file's own text at `line` (1-based), for version `ordinal`.
fn fixture_line(ordinal: usize, line: i64) -> String {
    let p = reloaded_dir().join(FIXTURE_SOURCES[ordinal]);
    let text = std::fs::read_to_string(&p)
        .unwrap_or_else(|e| panic!("GDH7-CHECK-FAIL: fixture source {} unreadable: {e}", p.display()));
    text.lines().nth((line.max(1) - 1) as usize).unwrap_or("").to_string()
}

/// Every step index whose recorded line is one of the fixture's PROBE lines,
/// paired with the version ordinal its path id resolves to.
///
/// Derived from the container and the fixtures — never a literal.
fn probe_steps(reader: &Arc<dyn TraceReader>, probe_lines: &[BTreeSet<i64>]) -> Vec<(StepId, usize, i64)> {
    let mut out = Vec::new();
    for idx in 0..reader.step_count() {
        let sid = StepId(idx as i64);
        let Some(step) = reader.step(sid) else { continue };
        let ordinal = reader.path_version_ordinal(step.path_id) as usize;
        if ordinal < probe_lines.len() && probe_lines[ordinal].contains(&step.line.0) {
            out.push((sid, ordinal, step.line.0));
        }
    }
    out
}

/// The probe lines each fixture version declares, read out of the fixture text
/// rather than written here.
///
/// The pattern is anchored to SYNTAX, not vocabulary — trap 4d. Matching the
/// bare token `GDH6|` also matched the fixtures' own header COMMENT on line 11,
/// which is present in all three files at the same line number; the
/// disjointness precondition then went red (13 distinct lines for 15 declared)
/// and, worse, line 11 entered every version's set, so a stop on it would have
/// been "checked" against three different expectations. The line must be an
/// executable `print(` carrying the per-iteration probe token.
fn probe_lines_per_version() -> Vec<BTreeSet<i64>> {
    FIXTURE_SOURCES
        .iter()
        .map(|name| {
            let p = reloaded_dir().join(name);
            let text = std::fs::read_to_string(&p)
                .unwrap_or_else(|e| panic!("GDH7-CHECK-FAIL: fixture source {} unreadable: {e}", p.display()));
            text.lines()
                .enumerate()
                .filter(|(_, l)| {
                    let t = l.trim_start();
                    // Leading indentation + a `print(` receiver is something
                    // only code produces; a comment about the probes does not.
                    t.starts_with("print(") && l.starts_with(['\t', ' ']) && t.contains("GDH6|it=")
                })
                .map(|(i, _)| (i + 1) as i64)
                .collect()
        })
        .collect()
}

// ===========================================================================
// GDH-G3 through the DAP surface.
// ===========================================================================

/// **`gdh7_no_step_is_attributed_to_the_wrong_version_through_dap`**
///
/// GDH-G3 re-run through the DAP surface rather than through `ct-print`. Every
/// stop position the debugger reports carries a `source_generation` matching
/// the version its step belongs to, and the source served at that stop matches
/// that version's text at that line.
///
/// The re-run is not redundant: `ct-print` and the db-backend are different
/// readers and design §2.2(e) measured them DISAGREEING about which duplicate
/// wins.
#[test]
fn gdh7_no_step_is_attributed_to_the_wrong_version_through_dap() {
    let mut ck = Checker::new("gdh7_no_step_is_attributed_to_the_wrong_version_through_dap");
    let ct = container(&reloaded_dir());
    let dump = ct_print_events(&ct);
    let reader = open_reader(&ct);
    let mut handler = build_handler(&ct, Arc::clone(&reader));

    // ---- anti-vacuity, all of it BEFORE any comparison --------------------
    let ids = reader.path_ids_for(FIXTURE_PATH);
    ck.eq(
        ids.len(),
        3,
        "the reader resolves the fixture path to THREE versions (the container's own paths.dat \
         carries three entries with one identical string)",
    );
    if ids.len() != 3 {
        ck.check_fail(format!(
            "the reader resolved {} version(s) for `{FIXTURE_PATH}`; every claim below is about \
             which of them a step belongs to and none of them can be reached",
            ids.len()
        ));
    }

    let ordinals: Vec<i64> = ids.iter().map(|id| reader.path_version_ordinal(*id)).collect();
    ck.eq(
        ordinals,
        vec![0, 1, 2],
        "the three ids carry the ordinals 0/1/2 in path-id order (oldest first)",
    );

    let digests: BTreeSet<String> = ids.iter().map(|id| reader.source_digest_for_path(*id)).collect();
    ck.eq(
        digests.len(),
        3,
        "the three versions carry THREE DISTINCT source digests — a digest keyed by path string \
         would collapse to one",
    );
    ck.ck(
        digests.iter().all(|d| d.starts_with("sha256:") && d.len() == 71),
        format!("every digest is a well-formed sha256 tag: {digests:?}"),
    );

    let probe_lines = probe_lines_per_version();
    ck.ck(
        probe_lines.iter().all(|s| !s.is_empty()),
        format!("every fixture version declares probe lines: {probe_lines:?}"),
    );
    let mut all: BTreeSet<i64> = BTreeSet::new();
    let total_declared: usize = probe_lines.iter().map(|s| s.len()).sum();
    for s in &probe_lines {
        all.extend(s.iter().copied());
    }
    ck.eq(
        all.len(),
        total_declared,
        "the versions' probe LINE NUMBERS are disjoint, so matching a line number is not \
         satisfiable by the wrong version",
    );

    let container_probe_steps = probe_steps(&reader, &probe_lines);
    // DERIVED, never a literal: the number of probe steps the CONTAINER holds,
    // per version. Asserting the per-version counts rather than only the total
    // is trap 4b's rule — a total that happens to be right while one version
    // contributed nothing would otherwise pass.
    let mut per_version = [0usize; 3];
    for (_, ord, _) in &container_probe_steps {
        per_version[*ord] += 1;
    }
    ck.ck(
        per_version.iter().all(|n| *n > 0),
        format!("every version contributed probe steps to the container: {per_version:?}"),
    );

    // ---- the reader, checked against a SECOND reader ----------------------
    //
    // Why this is here at all. Every generation claim below compares the wire
    // field against `container_ordinal_at`, which asks THE READER UNDER TEST
    // for the same step's ordinal. That is a real check of the plumbing from
    // `Db` to the DAP event, and it is NOT a check of the reader against the
    // container — both sides come from one `CTFSTraceReader`. The independent
    // grounding in this gate is the served TEXT (reader versus the committed
    // fixture bytes, 124 stops below); the two claims here add the other half,
    // by grounding the reader's STEP INDEX SPACE against `ct-print`.
    //
    // A MARKER CONSUMES A STEP INDEX. The container's step indices are
    // therefore NOT contiguous: GDH-M6's corrected invariant puts this
    // recording's versions at [0,76] / [78,177] / [179,311] with 77 and 178 as
    // holes, and `ct-print` reports exactly that — 310 steps over 312 slots.
    //
    // THE READER UNDER TEST DOES NOT REPRODUCE THE HOLES. `step_count()` is
    // 312 and `step()` answers `Some` at every index in it, returning at each
    // marker slot a DUPLICATE of the step before it. So the version ranges the
    // consumer sees are the contiguous [0,77] / [78,178] / [179,311]. This is
    // pre-existing — GDH-M7 touches neither `step` nor `step_count` — and no
    // container before this campaign's had a hole for it to get wrong. It is
    // PINNED rather than asserted away: the deviation is allowed to be exactly
    // the marker indices and nothing else, and each phantom must be a copy of
    // its predecessor, so a third phantom, a moved one, or one that invents a
    // position of its own turns this gate red.
    //
    // It errs toward the OLD version (index 77 reads as v1, which is the side
    // the marker separates from), so it does not misattribute across the
    // boundary — but a phantom step is still a position the debugger reports
    // that the recording does not contain, and it is filed as such.
    let reader_indices: BTreeSet<u64> = (0..reader.step_count())
        .filter(|i| reader.step(StepId(*i as i64)).is_some())
        .map(|i| i as u64)
        .collect();
    let marker_indices: BTreeSet<u64> = dump.markers.iter().map(|(i, _, _, _)| *i).collect();
    let phantom: BTreeSet<u64> = reader_indices.difference(&dump.step_indices).copied().collect();
    ck.eq(
        phantom.clone(),
        marker_indices.clone(),
        "the ONLY indices where the reader claims a step and the independent reader reports none \
         are the reload-marker indices — a marker consumes a step index, and the reader answers a \
         phantom at each one (pre-existing; GDH-M7 touches neither `step` nor `step_count`)",
    );
    ck.ck(
        !phantom.is_empty()
            && phantom.iter().all(
                |i| match (reader.step(StepId(*i as i64)), reader.step(StepId(*i as i64 - 1))) {
                    (Some(here), Some(before)) => here.path_id == before.path_id && here.line == before.line,
                    _ => false,
                },
            ),
        format!(
            "each phantom is a DUPLICATE of the step before it, not a position of its own \
             ({phantom:?}) — so the deviation is the known one and a new shape would show up here"
        ),
    );

    // ---- no step's version can be answered by failing to look -------------
    //
    // `Db::path_version_ordinal` answers `0` for three different states, and
    // only one of them is an answer: a genuine first version, a path id
    // outside the path table, and a path id absent from the list registered
    // under its own string. The last two are "I could not look", and on the
    // wire they are indistinguishable from a legacy single-version trace —
    // the silent-self-pass shape verbatim. They are `warn!`ed in `db.rs`;
    // this asserts their ABSENCE over every step, so the gate does not
    // depend on anyone reading a log line.
    let mut unresolvable: Vec<String> = Vec::new();
    for idx in 0..reader.step_count() {
        let Some(step) = reader.step(StepId(idx as i64)) else {
            continue;
        };
        match reader.path(step.path_id) {
            None => unresolvable.push(format!(
                "step {idx}: path id {} is not in the path table",
                step.path_id.0
            )),
            Some(p) => {
                if !reader.path_ids_for(p).contains(&step.path_id) {
                    unresolvable.push(format!(
                        "step {idx}: path id {} carries `{p}` but is not among its registered versions {:?}",
                        step.path_id.0,
                        reader.path_ids_for(p)
                    ));
                }
            }
        }
    }
    ck.ck(
        unresolvable.is_empty(),
        format!(
            "every step's path id is a REGISTERED version of its own path string ({} are not: \
             {:?}) — a step whose id cannot be found in the registry gets the degraded ordinal 0, \
             which reads on the wire as 'this is the original version'",
            unresolvable.len(),
            unresolvable.iter().take(4).collect::<Vec<_>>()
        ),
    );

    // ---- the measurement: WALK the whole recording through `next` ---------
    let stops = walk_all_stops(&mut handler, &reader);
    ck.ck(
        !stops.is_empty(),
        format!(
            "the debugger reported stops when walked forward ({} of them)",
            stops.len()
        ),
    );

    // Only the probe stops carry a version-discriminating line, so they are the
    // ones whose TEXT can be checked; the generation is checked at EVERY stop.
    let mut probe_stops = 0usize;
    let mut wrong_generation = Vec::new();
    let mut wrong_text = Vec::new();
    let mut nonzero_generations = 0usize;
    let mut seen_versions: BTreeSet<i64> = BTreeSet::new();
    let mut stop_texts: Vec<(i64, i64, String)> = Vec::new();
    for loc in &stops {
        let Some(want_ordinal) = container_ordinal_at(&reader, loc) else {
            continue;
        };
        let reported = generation_of(loc);
        if reported != 0 {
            nonzero_generations += 1;
        }
        seen_versions.insert(reported);
        if reported != want_ordinal {
            wrong_generation.push(format!(
                "step {} line {}: reported generation {reported}, the container says {want_ordinal}",
                ticks_of(loc),
                line_of(loc)
            ));
        }
        let line = line_of(loc);
        if (want_ordinal as usize) < probe_lines.len() && probe_lines[want_ordinal as usize].contains(&line) {
            probe_stops += 1;
            let served = served_line(&mut handler, loc);
            let want = fixture_line(want_ordinal as usize, line);
            stop_texts.push((ticks_of(loc), line, served.trim().to_string()));
            if served.trim() != want.trim() {
                wrong_text.push(format!(
                    "step {} line {line} (v{}): served {:?}, fixture has {:?}",
                    ticks_of(loc),
                    want_ordinal + 1,
                    served.trim(),
                    want.trim()
                ));
            }
        }
    }

    // Per the entry: assert at least one stop reports a NON-ZERO
    // `source_generation` BEFORE asserting any of them are correct. A run in
    // which every value is 0 satisfies "each matches its version" only if every
    // step is v1, and the harness must confirm otherwise.
    ck.ck(
        nonzero_generations > 0,
        format!(
            "at least one stop reports a NON-ZERO sourceGeneration ({nonzero_generations} of {} \
             did) — otherwise 'each matches its version' would be satisfiable by a backend that \
             writes 0 everywhere",
            stops.len()
        ),
    );
    ck.eq(
        seen_versions.len(),
        3,
        "the walk reported THREE DISTINCT generations, so the comparison discriminates between \
         versions rather than agreeing on one",
    );
    // EXACTLY, not `>=`. The walk's positions are strictly increasing, so it
    // cannot revisit a step and a surplus would mean it examined something the
    // container does not call a probe step. `>=` was the original spelling and
    // it let the stronger of the two readings go unasserted.
    ck.eq(
        probe_stops,
        container_probe_steps.len(),
        "the walk reached EVERY probe step the container holds, and only those",
    );
    ck.ck(
        stop_texts.iter().all(|(_, _, t)| !t.is_empty()),
        format!(
            "every examined stop served NON-EMPTY text ({} of {} were empty) — an empty string \
             matches an empty expectation for free",
            stop_texts.iter().filter(|(_, _, t)| t.is_empty()).count(),
            stop_texts.len()
        ),
    );
    ck.ck(
        wrong_generation.is_empty(),
        format!(
            "every stop's sourceGeneration is its own step's version ordinal ({} wrong: {:?})",
            wrong_generation.len(),
            wrong_generation.iter().take(4).collect::<Vec<_>>()
        ),
    );
    ck.ck(
        wrong_text.is_empty(),
        format!(
            "the source SERVED at every probe stop is that version's own text at that line ({} \
             wrong: {:?})",
            wrong_text.len(),
            wrong_text.iter().take(4).collect::<Vec<_>>()
        ),
    );

    ck.finish(17);
}

/// The CONTROL for the gate above: a legacy single-version recording, where
/// every `source_generation` must be 0.
///
/// This is what proves the field is populated FROM THE CONTAINER rather than
/// incremented blindly. Without it, a backend that returned the step index
/// would pass the reloaded half.
#[test]
fn gdh7_control_single_version_recording_reports_generation_zero() {
    let mut ck = Checker::new("gdh7_no_step_is_attributed_to_the_wrong_version_through_dap [CONTROL]");
    let ct = container(&control_dir());
    let reader = open_reader(&ct);
    let mut handler = build_handler(&ct, Arc::clone(&reader));

    let ids = reader.path_ids_for(FIXTURE_PATH);
    ck.eq(
        ids.len(),
        1,
        "the control recording carries exactly ONE version of the fixture path",
    );
    if ids.len() != 1 {
        ck.check_fail("the control recording is not single-version; it cannot control anything".to_string());
    }

    let probe_lines = probe_lines_per_version();
    let stops = walk_all_stops(&mut handler, &reader);
    ck.ck(
        !stops.is_empty(),
        format!("the control recording produced stops to examine ({})", stops.len()),
    );
    if stops.is_empty() {
        ck.check_fail("no stops in the control recording — every claim below is vacuous".to_string());
    }

    let mut nonzero = Vec::new();
    let mut wrong_text = Vec::new();
    let mut probe_stops = 0usize;
    for loc in &stops {
        if container_ordinal_at(&reader, loc).is_none() {
            continue;
        }
        let reported = generation_of(loc);
        if reported != 0 {
            nonzero.push(format!(
                "step {} line {}: generation {reported}",
                ticks_of(loc),
                line_of(loc)
            ));
        }
        let line = line_of(loc);
        if probe_lines[0].contains(&line) {
            probe_stops += 1;
            let served = served_line(&mut handler, loc);
            let want = fixture_line(0, line);
            if served.trim() != want.trim() {
                wrong_text.push(format!(
                    "step {} line {line}: served {:?}, want {:?}",
                    ticks_of(loc),
                    served.trim(),
                    want.trim()
                ));
            }
        }
    }
    ck.ck(
        probe_stops > 0,
        format!("the control walk reached {probe_stops} probe stop(s) — the text half is not vacuous"),
    );
    ck.ck(
        nonzero.is_empty(),
        format!(
            "EVERY stop in a single-version recording reports sourceGeneration 0 ({} did not: {:?})",
            nonzero.len(),
            nonzero.iter().take(4).collect::<Vec<_>>()
        ),
    );
    ck.ck(
        wrong_text.is_empty(),
        format!(
            "the source served at every control stop is v1's text ({} wrong: {:?})",
            wrong_text.len(),
            wrong_text.iter().take(4).collect::<Vec<_>>()
        ),
    );

    ck.finish(5);
}

// ===========================================================================
// GDH-G5 — backwards across the boundary.
// ===========================================================================

/// **`gdh7_reverse_across_the_boundary_shows_v1`**
///
/// GDH-G5. Step forward past the reload to a post-reload stop, read the source
/// served there (must be the newest version's text), then step BACKWARD to a
/// pre-reload stop and read the source again. It must be v1's text,
/// byte-identical to what a forward-only session serves for that same step id.
///
/// This is the property most likely to be got wrong, because a cache that is
/// correct going forward can still be wrong coming back — design §7.2 names
/// keying the pane by path STRING as the expected implementation error, and the
/// `gdh7-falsify-string-keyed-cache` arm is exactly that.
#[test]
fn gdh7_reverse_across_the_boundary_shows_v1() {
    let mut ck = Checker::new("gdh7_reverse_across_the_boundary_shows_v1");
    let ct = container(&reloaded_dir());
    let dump = ct_print_events(&ct);
    let reader = open_reader(&ct);
    let mut handler = build_handler(&ct, Arc::clone(&reader));

    // ---- anti-vacuity ------------------------------------------------------
    let ids = reader.path_ids_for(FIXTURE_PATH);
    ck.eq(ids.len(), 3, "the reader resolves the fixture path to three versions");
    if ids.len() != 3 {
        ck.check_fail("fewer than three versions; there is no boundary to cross".to_string());
    }

    // The markers are read from the CONTAINER by an independent reader, never
    // assumed from the fixture.
    ck.ck(
        !dump.markers.is_empty(),
        format!(
            "the container carries TagSourceReload marker(s), read by ct-print: {:?} (header \
             declares source_reloads={})",
            dump.markers,
            dump.header
                .get("counts")
                .and_then(|c| c.get("source_reloads"))
                .and_then(JsonValue::as_u64)
                .unwrap_or(0)
        ),
    );
    if dump.markers.is_empty() {
        ck.check_fail("no reload markers in the container; the navigation below crosses nothing".to_string());
    }

    let probe_lines = probe_lines_per_version();
    let steps = probe_steps(&reader, &probe_lines);
    let newest_ord = 2usize;
    let oldest_ord = 0usize;
    let post = steps
        .iter()
        .rev()
        .find(|(_, o, _)| *o == newest_ord)
        .copied()
        .unwrap_or_else(|| ck.check_fail("no post-reload probe stop found".to_string()));
    let pre = steps
        .iter()
        .find(|(_, o, _)| *o == oldest_ord)
        .copied()
        .unwrap_or_else(|| ck.check_fail("no pre-reload probe stop found".to_string()));
    ck.ck(
        pre.0.0 < post.0.0,
        format!(
            "the pre-reload stop ({}) precedes the post-reload one ({})",
            pre.0.0, post.0.0
        ),
    );

    let crossing: Vec<&(u64, u64, u64, u64)> = dump
        .markers
        .iter()
        .filter(|(idx, _, _, _)| (*idx as i64) > pre.0.0 && (*idx as i64) < post.0.0)
        .collect();
    ck.ck(
        !crossing.is_empty(),
        format!(
            "at least one TagSourceReload marker lies BETWEEN the two stops ({} do: {:?}) — read \
             from the container, so 'the navigation crossed a boundary' is measured and not \
             assumed",
            crossing.len(),
            crossing
        ),
    );

    // v1's and v2/v3's texts must actually DIFFER, or "it returned v1" is not a
    // discrimination at all.
    let v1_text = fixture_line(oldest_ord, pre.2);
    let v3_text = fixture_line(newest_ord, post.2);
    ck.ck(
        v1_text.trim() != v3_text.trim() && !v1_text.trim().is_empty() && !v3_text.trim().is_empty(),
        format!(
            "the two versions' texts at the compared lines DIFFER and are both non-empty: \
             v1@{} {:?} vs v3@{} {:?}",
            pre.2,
            v1_text.trim(),
            post.2,
            v3_text.trim()
        ),
    );

    // ---- forward past the reload ------------------------------------------
    let post_loc = stop_after(&mut handler, StepId(post.0.0 - 1));
    let post_served = served_line(&mut handler, &post_loc);
    let post_ticks = ticks_of(&post_loc);
    ck.eq(
        generation_of(&post_loc),
        container_ordinal_at(&reader, &post_loc).unwrap_or(-1),
        "the post-reload stop's reported generation is the one the CONTAINER records for that step",
    );
    let post_want = fixture_line(generation_of(&post_loc).max(0) as usize, line_of(&post_loc));
    ck.ck(
        post_served.trim() == post_want.trim() && !post_want.trim().is_empty(),
        format!(
            "the source served at the post-reload stop (step {post_ticks}, line {}) is that \
             version's own text (served {:?}, want {:?})",
            line_of(&post_loc),
            post_served.trim(),
            post_want.trim()
        ),
    );

    // ---- now BACKWARDS, through the production stepBack runner -------------
    let mut back_loc = post_loc.clone();
    let mut moves = 0usize;
    // Bounded: a runner that stops advancing must fail the gate rather than
    // spin. The bound is the whole step count, so reaching it means the
    // navigation genuinely could not get back.
    let bound = reader.step_count() + 8;
    while ticks_of(&back_loc) > pre.0.0 && moves < bound {
        let next_back = step_back(&mut handler);
        if ticks_of(&next_back) >= ticks_of(&back_loc) {
            back_loc = next_back;
            break; // the runner stopped moving backwards
        }
        back_loc = next_back;
        moves += 1;
    }
    ck.ck(
        moves > 0 && moves < bound,
        format!("the backward navigation MOVED and terminated within its bound ({moves} stepBack requests)"),
    );
    ck.ck(
        ticks_of(&back_loc) < post_ticks,
        format!(
            "the final step id ({}) is strictly LESS than the post-reload one ({post_ticks}) — a \
             session that failed to step and re-read the same position would otherwise pass",
            ticks_of(&back_loc)
        ),
    );

    let back_gen = generation_of(&back_loc);
    ck.eq(
        back_gen,
        container_ordinal_at(&reader, &back_loc).unwrap_or(-1),
        "the backward stop's reported generation is the one the CONTAINER records for that step",
    );
    ck.eq(
        back_gen,
        oldest_ord as i64,
        "and that generation is V1's — the navigation really did land before the first reload",
    );
    let back_served = served_line(&mut handler, &back_loc);
    ck.ck(
        !back_served.trim().is_empty(),
        format!(
            "the backward read served a NON-EMPTY source line: {:?}",
            back_served.trim()
        ),
    );

    // The headline claim, asserted on BYTES.
    let back_want = fixture_line(oldest_ord, line_of(&back_loc));
    ck.ck(
        back_served.trim() == back_want.trim() && !back_want.trim().is_empty(),
        format!(
            "STEPPING BACK ACROSS THE RELOAD SHOWS V1: served {:?} at line {}, v1's fixture has \
             {:?}",
            back_served.trim(),
            line_of(&back_loc),
            back_want.trim()
        ),
    );
    ck.ck(
        back_served.trim() != post_served.trim(),
        format!(
            "and it is NOT the post-reload text ({:?}) rendered at v1's line numbers — which is \
             what a string-keyed cache or a single-destination bundle would serve",
            post_served.trim()
        ),
    );
    // ---- the forward-only CONTROL -----------------------------------------
    //
    // The byte-for-byte comparison target, and it is taken at THE STEP THE
    // BACKWARD NAVIGATION ACTUALLY REACHED — not at a step chosen in advance.
    // A first cut picked the target before navigating and compared two
    // different positions; that comparison could only ever be a coincidence,
    // and it went red, which is the correct outcome for a control that is not
    // measuring what it claims.
    //
    // The control is a SEPARATE handler that has only ever moved forward, so
    // its bundled-source state cannot have been influenced by a backward read.
    // It walks from step 0 with the production `stepIn` runner until it stands
    // on the same step id. Failing to reach it is a CHECK-FAIL: comparing
    // against nothing is how a gate passes for free.
    let back_ticks = ticks_of(&back_loc);
    let control_text = {
        let creader = open_reader(&ct);
        let mut chandler = build_handler(&ct, creader);
        let mut loc = stop_after(&mut chandler, StepId(0));
        let mut guard = 0usize;
        while ticks_of(&loc) < back_ticks && guard < bound {
            loc = step_forward(&mut chandler);
            guard += 1;
        }
        if ticks_of(&loc) != back_ticks {
            ck.check_fail(format!(
                "the forward-only control session could not reach step {back_ticks} (stopped at \
                 {}) — there is nothing to compare the backward read against",
                ticks_of(&loc)
            ));
        }
        let text = served_line(&mut chandler, &loc);
        if text.trim().is_empty() {
            ck.check_fail(format!(
                "the forward-only control session served NO source at step {back_ticks} — an \
                 empty string would match an empty string"
            ));
        }
        text
    };
    ck.ck(
        back_served.trim() == control_text.trim() && !control_text.trim().is_empty(),
        format!(
            "the backward read is byte-identical to what the FORWARD-ONLY control session serves \
             at the same step ({back_ticks}): {:?} vs {:?}",
            back_served.trim(),
            control_text.trim()
        ),
    );
    ck.ck(
        !digest_of(&back_loc).is_empty() && digest_of(&back_loc) != digest_of(&post_loc),
        format!(
            "the backward stop's sourceDigest is non-empty and DIFFERS from the forward one \
             ({} vs {}) — the frontend's sourceRevisionKey is (path, generation, digest), and a \
             digest that did not move would key both stops to one cached pane",
            digest_of(&back_loc),
            digest_of(&post_loc)
        ),
    );

    ck.finish(16);
}
