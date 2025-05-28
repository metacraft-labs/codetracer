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

use runtime_tracing::{StepId, TypeKind};

use crate::{
    db::Db,
    lang::Lang,
    task::StringAndValueTuple,
    trace_processor::{load_trace_data, load_trace_metadata, TraceProcessor},
    value::Value,
};

use super::TracepointInterpreter;

#[test]
#[ignore]
fn log_array() -> Result<(), Box<dyn Error>> {
    let src = "log(arr)";

    let expected = vec![var("arr", seq_val(vec![int_val(42), int_val(-13), int_val(5)]))];

    check_tracepoint_evaluate(src, 3, "array", Lang::Ruby, &expected)?;
    check_tracepoint_evaluate(src, 3, "array", Lang::Noir, &expected)?;

    Ok(())
}

#[test]
#[ignore]
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
    check_tracepoint_evaluate(src, 3, "array", Lang::Noir, &expected)?;

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
    let mut val = Value::default();
    val.kind = TypeKind::Int;
    val.i = value.to_string();

    val
}

fn str_val(value: &str) -> Value {
    let mut val = Value::default();
    val.kind = TypeKind::String;
    val.text = value.to_string();

    val
}

fn seq_val(value: Vec<Value>) -> Value {
    let mut val = Value::default();
    val.kind = TypeKind::Seq;
    val.elements = value;

    val
}

fn check_tracepoint_evaluate(
    src: &str,
    line: usize,
    trace_name: &str,
    lang: Lang,
    expected: &Vec<StringAndValueTuple>,
) -> Result<(), Box<dyn Error>> {
    let db = load_test_trace(trace_name, lang)?;

    let mut interpreter = TracepointInterpreter::new(1);
    interpreter.register_tracepoint(0, src)?;

    for step in db.step_from(StepId(0), true) {
        let curr_line = step.line.0 as usize;

        if line == curr_line {
            let actual = interpreter.evaluate(0, step.step_id, &db);
            check_equal(&actual, expected);
            return Ok(());
        }
    }

    Err(format!("No step for line {line} in DB").into())
}

fn check_equal(actuals: &Vec<StringAndValueTuple>, expecteds: &Vec<StringAndValueTuple>) {
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
                check_equal_values(&v1, &v2);
            }
        }

        _ => {}
    }
}

fn load_db_for_trace(path: &Path) -> Db {
    let trace_file = path.join("trace.json");
    let trace_metadata_file = path.join("trace_metadata.json");
    let trace = load_trace_data(&trace_file).expect("expected that it can load the trace file");
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

fn record_ruby_trace(program_dir: &PathBuf, target_dir: &PathBuf) {
    let main_path = program_dir.join("main.rb");
    let trace_path = target_dir.join("trace.json");
    let result = Command::new("ruby")
        .args([
            "../../libs/codetracer-ruby-recorder/src/trace.rb",
            main_path.to_str().unwrap(),
        ])
        .env("CODETRACER_DB_TRACE_PATH", trace_path.to_str().unwrap())
        .output()
        .unwrap();

    if !result.status.success() {
        panic!("Recording trace failed!\n{:#?}.", result);
    }
}

fn record_noir_trace(program_dir: &PathBuf, target_dir: &PathBuf) {
    let result = Command::new("nargo")
        .args(["trace", "--trace-dir", target_dir.to_str().unwrap()])
        .current_dir(program_dir)
        .output()
        .unwrap();

    if !result.status.success() {
        panic!("Recording trace failed!\n{:#?}.", result);
    }
}

fn record_rust_wasm_trace(_program_dir: &PathBuf, _target_dir: &PathBuf) {
    todo!()
}

fn record_trace(program_dir: &PathBuf, target_dir: &PathBuf, lang: Lang) -> Result<(), Box<dyn Error>> {
    match lang {
        Lang::Ruby | Lang::RubyDb => record_ruby_trace(program_dir, target_dir),
        Lang::Noir => record_noir_trace(program_dir, target_dir),
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
