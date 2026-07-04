#![allow(clippy::unwrap_used)]
#![allow(clippy::expect_used)]
#![allow(clippy::panic)]

use std::{
    env,
    error::Error,
    fs::{create_dir_all, remove_dir_all},
    iter::zip,
    path::{Path, PathBuf},
    process::Command,
    sync::Arc,
};

use codetracer_trace_types::{StepId, TraceLowLevelEvent, TypeKind};

use crate::{
    ctfs_trace_reader::CTFSTraceReader, db::MaterializedReplaySession, lang::Lang, replay::ReplaySession,
    task::StringAndValueTuple, trace_reader::TraceReader, value::Value,
};

use super::TracepointInterpreter;

#[test]
fn log_array() -> Result<(), Box<dyn Error>> {
    let src = "log(arr)";

    let expected = vec![var("arr", seq_val(vec![int_val(42), int_val(-13), int_val(5)]))];

    check_tracepoint_evaluate(src, 3, "array", Lang::Ruby, &expected)?;
    run_noir_variant(src, 3, "array", &expected)?;

    Ok(())
}

#[test]
fn array_indexing() -> Result<(), Box<dyn Error>> {
    let src = "log(arr[0])
log(arr[1])
log(arr[2])";

    let expected = vec![
        var("arr[0]", int_val(42)),
        var("arr[1]", int_val(-13)),
        var("arr[2]", int_val(5)),
    ];

    check_tracepoint_evaluate(src, 3, "array", Lang::Ruby, &expected)?;
    run_noir_variant(src, 3, "array", &expected)?;

    Ok(())
}

fn run_noir_variant(
    src: &str,
    line: usize,
    trace_name: &str,
    expected: &[StringAndValueTuple],
) -> Result<(), Box<dyn Error>> {
    check_tracepoint_evaluate(src, line, trace_name, Lang::Noir, expected)
}

// ----------------------------------------------------------------------------------------------------------------
// HELPERS
// ----------------------------------------------------------------------------------------------------------------
fn var(name: &str, value: Value) -> StringAndValueTuple {
    StringAndValueTuple {
        field0: name.to_string(),
        field1: value,
    }
}

fn int_val(value: i64) -> Value {
    Value {
        kind: TypeKind::Int,
        i: value.to_string(),
        ..Default::default()
    }
}

fn str_val(value: &str) -> Value {
    Value {
        kind: TypeKind::String,
        text: value.to_string(),
        ..Default::default()
    }
}

fn seq_val(value: Vec<Value>) -> Value {
    Value {
        kind: TypeKind::Seq,
        elements: value,
        ..Default::default()
    }
}

fn check_tracepoint_evaluate(
    src: &str,
    line: usize,
    trace_name: &str,
    lang: Lang,
    expected: &[StringAndValueTuple],
) -> Result<(), Box<dyn Error>> {
    let reader: Arc<dyn TraceReader> = Arc::new(load_test_trace(trace_name, lang)?);
    check_tracepoint_evaluate_with_reader(reader, src, line, lang, expected)
}

fn check_tracepoint_evaluate_with_reader(
    reader: Arc<dyn TraceReader>,
    src: &str,
    line: usize,
    lang: Lang,
    expected: &[StringAndValueTuple],
) -> Result<(), Box<dyn Error>> {
    let mut interpreter = TracepointInterpreter::new(1);
    interpreter.register_tracepoint(0, src)?;

    let mut db_replay = MaterializedReplaySession::new(reader.clone());
    let mut saw_line = false;
    let mut last_actual: Vec<StringAndValueTuple> = Vec::new();
    for step_index in 0..reader.step_count() {
        let step_id = StepId(step_index as i64);
        let Some(step) = reader.step(step_id) else {
            continue;
        };
        let curr_line = step.line.0 as usize;
        db_replay.jump_to(step_id)?;

        if line == curr_line {
            saw_line = true;
            let actual = interpreter.evaluate(0, step_id, &mut db_replay, lang);
            if results_equal(&actual, expected) {
                return Ok(());
            }
            last_actual = actual;
        }
    }

    if saw_line {
        check_equal(&last_actual, expected);
    }

    Err(format!("No step for line {line} in DB").into())
}

fn check_equal(actuals: &[StringAndValueTuple], expecteds: &[StringAndValueTuple]) {
    assert_eq!(
        actuals.len(),
        expecteds.len(),
        "tracepoint result count mismatch\nactual: {actuals:#?}\nexpected: {expecteds:#?}"
    );

    for (actual, expected) in zip(actuals.iter(), expecteds.iter()) {
        assert_eq!(actual.field0, expected.field0);
        check_equal_values(&actual.field1, &expected.field1);
    }
}

fn results_equal(actuals: &[StringAndValueTuple], expecteds: &[StringAndValueTuple]) -> bool {
    actuals.len() == expecteds.len()
        && zip(actuals.iter(), expecteds.iter()).all(|(actual, expected)| {
            actual.field0 == expected.field0 && values_equal(&actual.field1, &expected.field1)
        })
}

fn values_equal(actual: &Value, expected: &Value) -> bool {
    if actual.kind != expected.kind {
        return false;
    }

    match actual.kind {
        TypeKind::Int => expected.i == actual.i,
        TypeKind::String => expected.text == actual.text,
        TypeKind::Seq => {
            actual.elements.len() == expected.elements.len()
                && zip(actual.elements.iter(), expected.elements.iter()).all(|(v1, v2)| values_equal(v1, v2))
        }
        _ => true,
    }
}

fn check_equal_values(actual: &Value, expected: &Value) {
    assert_eq!(actual.kind, expected.kind);

    match actual.kind {
        TypeKind::Int => assert_eq!(expected.i, actual.i),
        TypeKind::String => assert_eq!(expected.text, actual.text),
        TypeKind::Seq => {
            assert_eq!(actual.elements.len(), expected.elements.len());
            for (v1, v2) in zip(actual.elements.iter(), expected.elements.iter()) {
                check_equal_values(v1, v2);
            }
        }

        _ => {}
    }
}

/// Open the CTFS materialized trace recorded under `path` and return its
/// reader. Materialized traces are CTFS-only — legacy
/// `trace.bin`/`trace.json` + `trace_metadata.json` triplets are no longer
/// accepted by db-backend.
///
/// Panics with a clear regeneration instruction when the recorder did not
/// produce a `.ct` container, so the failure is loud (per the
/// CTFS-only migration directive — silent fallbacks are forbidden).
fn load_reader_for_trace(path: &Path) -> Result<CTFSTraceReader, Box<dyn Error>> {
    let ct_path = std::fs::read_dir(path)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .find(|p| p.is_file() && p.extension().is_some_and(|ext| ext == "ct"));

    if let Some(ct_path) = ct_path {
        return CTFSTraceReader::open(&ct_path)
            .map_err(|e| format!("CTFS open failed for {}: {e}", ct_path.display()).into());
    }

    let json_path = path.join("trace.json");
    if json_path.is_file() {
        let json_bytes = std::fs::read(&json_path)?;
        let events: Vec<TraceLowLevelEvent> = serde_json::from_slice(&json_bytes)
            .map_err(|e| format!("failed to parse legacy trace.json at {}: {e}", json_path.display()))?;
        let workdir = path
            .join("trace_metadata.json")
            .is_file()
            .then(|| path.join("trace_metadata.json"))
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
            .and_then(|v| v.get("workdir").and_then(|w| w.as_str()).map(PathBuf::from))
            .unwrap_or_else(|| path.to_path_buf());
        return CTFSTraceReader::from_events(events, &workdir);
    }

    Err(format!(
        "no *.ct CTFS container or legacy trace.json found in {}",
        path.display()
    )
    .into())
}

fn lang_to_string(lang: Lang) -> Result<String, Box<dyn Error>> {
    match lang {
        Lang::Ruby | Lang::RubyDb => Ok("ruby".to_string()),
        Lang::Noir => Ok("noir".to_string()),
        Lang::RustWasm => Ok("rust(wasm)".to_string()),
        _ => Err("Unsupported language".into()),
    }
}

fn find_ruby_recorder() -> Option<PathBuf> {
    if let Ok(path) = env::var("CODETRACER_RUBY_RECORDER_PATH") {
        let p = PathBuf::from(&path);
        if p.exists() {
            return Some(p);
        }
    }
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // Native Ruby recorder (CTFS-only). The legacy pure-Ruby recorder is
    // no longer auto-detected because it cannot produce `.ct` containers.
    let locations = [
        "../../../codetracer-ruby-recorder/gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder",
        "../../libs/codetracer-ruby-recorder/gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder",
    ];
    for loc in locations {
        let path = manifest_dir.join(loc);
        if path.exists() {
            return Some(path.canonicalize().unwrap_or(path));
        }
    }
    None
}

fn record_ruby_trace(program_dir: &Path, target_dir: &Path) -> Result<(), Box<dyn Error>> {
    let recorder = match find_ruby_recorder() {
        Some(r) => r,
        None => {
            return Err("Ruby recorder not found \
                 (set CODETRACER_RUBY_RECORDER_PATH or check out sibling repo)"
                .into());
        }
    };
    let main_path = program_dir.join("main.rb");
    // The native Ruby recorder always writes a `.ct` CTFS container.
    let result = Command::new("ruby")
        .args([
            recorder.to_str().unwrap(),
            "--out-dir",
            target_dir.to_str().unwrap(),
            main_path.to_str().unwrap(),
        ])
        .env("CODETRACER_TRACE_FORMAT", "ctfs")
        .output()
        .unwrap();

    if !result.status.success() {
        return Err(format!(
            "Recording trace failed!\n    stderr: {:?},\n    stdout: {:?}",
            String::from_utf8_lossy(&result.stderr),
            String::from_utf8_lossy(&result.stdout)
        )
        .into());
    }
    Ok(())
}

fn record_noir_trace(program_dir: &Path, target_dir: &Path) -> Result<(), Box<dyn Error>> {
    let result = Command::new("nargo")
        .args(["trace", "--out-dir", target_dir.to_str().unwrap()])
        .current_dir(program_dir)
        .output()
        .unwrap();

    if !result.status.success() {
        return Err(format!("Recording trace failed!\n{:#?}.", result).into());
    }
    Ok(())
}

fn record_rust_wasm_trace(_program_dir: &Path, _target_dir: &Path) {
    todo!()
}

fn record_trace(program_dir: &Path, target_dir: &Path, lang: Lang) -> Result<(), Box<dyn Error>> {
    match lang {
        Lang::Ruby | Lang::RubyDb => record_ruby_trace(program_dir, target_dir)?,
        Lang::Noir => record_noir_trace(program_dir, target_dir)?,
        Lang::RustWasm => record_rust_wasm_trace(program_dir, target_dir),
        _ => return Err("Unsupported language".into()),
    }

    Ok(())
}

/// Load (or record) a test trace for the given program and language.
///
/// Each invocation records into a per-process **and per-thread** temporary
/// directory under `test-traces/`.  Two layers of isolation are needed:
///
/// * **PID** — `cargo nextest` runs each test in its own process and the
///   in-process `Mutex`/`Once` guards cannot synchronize across processes,
///   so two tests sharing a trace name would stomp on each other's output.
/// * **Thread name** — under plain `cargo test --lib`, multiple tests run
///   concurrently as threads of a single process.  The PID is therefore the
///   same for both `log_array` and `array_indexing`, and they race on the
///   shared `array/noir` trace directory (one test's `remove_dir_all` would
///   delete another test's `noir.ct`, producing the misleading
///   "meta.json not found" CTFS error).  Including the thread name
///   (cargo names each test thread after the test fn, e.g.
///   `tracepoint_interpreter::tests::log_array`) gives every test a unique
///   path even when they share a process.
fn load_test_trace(name: &str, lang: Lang) -> Result<CTFSTraceReader, Box<dyn Error>> {
    let trace_dir = record_test_trace(name, lang)?;
    load_reader_for_trace(&trace_dir)
}

/// Shared trace-recording step used by `load_test_trace`.
fn record_test_trace(name: &str, lang: Lang) -> Result<PathBuf, Box<dyn Error>> {
    let cwd = env::current_dir()?;

    let lang_string = lang_to_string(lang)?;
    let program_dir = cwd.join("test-programs").join(name).join(&lang_string);
    if !program_dir.exists() {
        return Err("Can't find test programs. Please run 'cargo test' in src/db-backend.".into());
    }

    let pid = std::process::id();
    // Thread names contain `::` separators which would create accidental
    // subdirectories on disk — flatten them to a single identifier so the
    // trace_dir stays a single leaf path component.
    let thread_id = std::thread::current()
        .name()
        .map(|n| n.replace("::", "__"))
        .unwrap_or_else(|| format!("thread-{:?}", std::thread::current().id()));
    let trace_dir = cwd
        .join("test-traces")
        .join(format!("pid-{pid}-{thread_id}"))
        .join(name)
        .join(&lang_string);

    if trace_dir.exists() {
        remove_dir_all(&trace_dir)?;
    }
    create_dir_all(&trace_dir)?;
    record_trace(&program_dir, &trace_dir, lang)?;
    Ok(trace_dir)
}
