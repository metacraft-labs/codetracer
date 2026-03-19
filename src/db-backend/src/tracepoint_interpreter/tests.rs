#![allow(clippy::unwrap_used)]
#![allow(clippy::expect_used)]
#![allow(clippy::panic)]

use core::panic;
use std::{
    env,
    error::Error,
    fs::{create_dir, remove_dir_all},
    iter::zip,
    path::{Path, PathBuf},
    process::Command,
    sync::{LazyLock, Mutex, Once},
};

use codetracer_trace_types::{StepId, TypeKind};

use crate::{
    db::{Db, DbReplay},
    lang::Lang,
    replay::Replay,
    task::StringAndValueTuple,
    trace_processor::{load_trace_data, load_trace_metadata, TraceProcessor},
    value::Value,
};

use super::TracepointInterpreter;

#[test]
#[ignore]
fn log_array() -> Result<(), Box<dyn Error>> {
    if find_ruby_recorder().is_none() {
        eprintln!("SKIPPED: Ruby recorder not found");
        return Ok(());
    }

    let src = "log(arr)";

    let expected = vec![var("arr", seq_val(vec![int_val(42), int_val(-13), int_val(5)]))];

    check_tracepoint_evaluate(src, 3, "array", Lang::Ruby, &expected)?;
    if find_nargo() {
        check_tracepoint_evaluate(src, 3, "array", Lang::Noir, &expected)?;
    } else {
        eprintln!("SKIPPED: Noir variant — nargo not found on PATH");
    }

    Ok(())
}

#[test]
#[ignore]
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
    if find_nargo() {
        check_tracepoint_evaluate(src, 3, "array", Lang::Noir, &expected)?;
    } else {
        eprintln!("SKIPPED: Noir variant — nargo not found on PATH");
    }

    Ok(())
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

    let mut db_replay = DbReplay::new(Box::new(db.clone()));
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

fn load_db_for_trace(path: &Path) -> Db {
    let trace_file = path.join("trace.json");
    let trace_metadata_file = path.join("trace_metadata.json");
    let trace = load_trace_data(&trace_file, codetracer_trace_reader::TraceEventsFileFormat::Json)
        .expect("expected that it can load the trace file");
    let trace_metadata =
        load_trace_metadata(&trace_metadata_file).expect("expected that it can load the trace metadata file");
    let mut db = Db::new(&trace_metadata.workdir);
    let mut trace_processor = TraceProcessor::new(&mut db);
    trace_processor.postprocess(&trace).unwrap();
    db
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
    let locations = [
        "../../../codetracer-ruby-recorder/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder",
        "../../libs/codetracer-ruby-recorder/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder",
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
    let trace_path = target_dir.join("trace.json");
    let result = Command::new("ruby")
        .args([
            recorder.to_str().unwrap(),
            "--out-dir",
            target_dir.to_str().unwrap(),
            main_path.to_str().unwrap(),
        ])
        .env("CODETRACER_DB_TRACE_PATH", trace_path.to_str().unwrap())
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
        .args(["trace", "--trace-dir", target_dir.to_str().unwrap()])
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

static DIR_MUTEX: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));
static CLEAN_TRACES: Once = Once::new();

fn load_test_trace(name: &str, lang: Lang) -> Result<Db, Box<dyn Error>> {
    let cwd = env::current_dir()?;

    let lang_string = lang_to_string(lang)?;
    let program_dir = cwd.join("test-programs").join(name).join(&lang_string);
    if !program_dir.exists() {
        return Err("Can't find test programs. Please run 'cargo test' in src/db-backend.".into());
    }

    let test_trace_path = cwd.join("test-traces");

    let program_trace_path = test_trace_path.join(name);
    let program_lang_path = program_trace_path.join(&lang_string);

    {
        let _guard = DIR_MUTEX.lock().unwrap();

        // Clear old traces
        CLEAN_TRACES.call_once(|| {
            if test_trace_path.exists() {
                if let Err(x) = remove_dir_all(&test_trace_path) {
                    panic!("{}", x);
                }
            }
        });

        // Ensure parent directories
        if !test_trace_path.exists() {
            create_dir(&test_trace_path).unwrap();
        }

        if !program_trace_path.exists() {
            create_dir(&program_trace_path).unwrap();
        }

        // Create trace if not already created
        if !program_lang_path.exists() {
            create_dir(&program_lang_path).unwrap();
            record_trace(&program_dir, &program_lang_path, lang).unwrap();
        }
    }

    Ok(load_db_for_trace(&program_lang_path))
}
