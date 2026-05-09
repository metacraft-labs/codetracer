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

use codetracer_trace_types::{StepId, TypeKind};

use crate::{
    ctfs_trace_reader::CTFSTraceReader,
    db::{Db, MaterializedReplaySession},
    in_memory_trace_reader::InMemoryTraceReader,
    lang::Lang,
    replay::ReplaySession,
    task::StringAndValueTuple,
    trace_reader::TraceReader,
    value::Value,
};

use super::TracepointInterpreter;

#[test]
fn log_array() -> Result<(), Box<dyn Error>> {
    if find_ruby_recorder().is_none() {
        eprintln!("SKIPPED: Ruby recorder not found");
        return Ok(());
    }

    let src = "log(arr)";

    let expected = vec![var("arr", seq_val(vec![int_val(42), int_val(-13), int_val(5)]))];

    check_tracepoint_evaluate(src, 3, "array", Lang::Ruby, &expected)?;
    run_noir_variant(src, 3, "array", &expected)?;

    Ok(())
}

#[test]
fn array_indexing() -> Result<(), Box<dyn Error>> {
    if find_ruby_recorder().is_none() {
        eprintln!("SKIPPED: Ruby recorder not found");
        return Ok(());
    }

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

/// Run the Noir variant of a tracepoint test if `nargo` is available and
/// produces a CTFS container.  Materialized traces are CTFS-only — when
/// `nargo` is found but emits the legacy `trace.bin`/`trace_metadata.json`
/// triplet instead of a `.ct` container, the test panics with a clear
/// upgrade instruction rather than silently skipping. This matches the
/// directive that legacy materialized-trace bundles are no longer accepted.
fn run_noir_variant(
    src: &str,
    line: usize,
    trace_name: &str,
    expected: &[StringAndValueTuple],
) -> Result<(), Box<dyn Error>> {
    if !find_nargo() {
        eprintln!("SKIPPED: Noir variant — nargo not found on PATH");
        return Ok(());
    }
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
    let db = load_test_trace(trace_name, lang)?;

    let mut interpreter = TracepointInterpreter::new(1);
    interpreter.register_tracepoint(0, src)?;

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db.clone()));
    let mut db_replay = MaterializedReplaySession::new(reader);
    for step in db.step_from(StepId(0), true) {
        let curr_line = step.line.0 as usize;
        db_replay.jump_to(step.step_id)?;

        if line == curr_line {
            let actual = interpreter.evaluate(0, step.step_id, &mut db_replay, lang);
            check_equal(&actual, expected);
            return Ok(());
        }
    }

    Err(format!("No step for line {line} in DB").into())
}

fn check_equal(actuals: &[StringAndValueTuple], expecteds: &[StringAndValueTuple]) {
    assert_eq!(actuals.len(), expecteds.len());

    for (actual, expected) in zip(actuals.iter(), expecteds.iter()) {
        assert_eq!(actual.field0, expected.field0);
        check_equal_values(&actual.field1, &expected.field1);
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
/// populated `Db`. Materialized traces are CTFS-only — legacy
/// `trace.bin`/`trace.json` + `trace_metadata.json` triplets are no longer
/// accepted by db-backend.
///
/// Panics with a clear regeneration instruction when the recorder did not
/// produce a `.ct` container, so the failure is loud (per the
/// CTFS-only migration directive — silent fallbacks are forbidden).
fn load_db_for_trace(path: &Path) -> Db {
    let ct_path = std::fs::read_dir(path)
        .unwrap_or_else(|e| panic!("read_dir {}: {}", path.display(), e))
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .find(|p| p.is_file() && p.extension().is_some_and(|ext| ext == "ct"))
        .unwrap_or_else(|| {
            panic!(
                "no *.ct CTFS container found in {}.\n  \
                 Materialized traces are CTFS-only — legacy \
                 trace.bin/trace.json/trace_metadata.json bundles are no \
                 longer accepted.\n  \
                 If the recorder is producing the legacy 3-file layout, \
                 update it to emit a `.ct` container (the trace-format \
                 migration is documented in \
                 codetracer-specs/Trace-Files/CTFS-Migration-Guide.md).",
                path.display()
            )
        });

    let reader =
        CTFSTraceReader::open(&ct_path).unwrap_or_else(|e| panic!("CTFS open failed for {}: {}", ct_path.display(), e));
    reader.db().clone()
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

fn find_nargo() -> bool {
    Command::new("nargo").arg("--version").output().is_ok()
}

fn record_noir_trace(program_dir: &Path, target_dir: &Path) -> Result<(), Box<dyn Error>> {
    if !find_nargo() {
        return Err("nargo not found on PATH".into());
    }
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
fn load_test_trace(name: &str, lang: Lang) -> Result<Db, Box<dyn Error>> {
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

    Ok(load_db_for_trace(&trace_dir))
}
