use std::process::Command;
use std::env;
use std::fs;
use std::path::Path;

fn run_small_in_dir(program: &str, dir: &Path) -> String {
    let file_name = format!(
        "test_{}.small",
        std::time::SystemTime::now()
            .elapsed()
            .unwrap()
            .as_nanos()
    );
    let file_path = dir.join(file_name);
    fs::write(&file_path, program).unwrap();
    let bin = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("target/debug/small-lang");
    let output = Command::new(bin)
        .arg(&file_path)
        .current_dir(dir)
        .output()
        .expect("failed to run small-lang");
    fs::remove_file(&file_path).ok();
    assert!(output.status.success());
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn run_small(program: &str) -> String {
    let dir = env::temp_dir();
    run_small_in_dir(program, &dir)
}

const CASES: &[(&str, &str)] = &[
    ("(defun add-one (x) (add x 1)) (print (add-one 3))", "4"),
    ("(set x 1) (print x)", "1"),
    ("(set x 0) (set r (ref x)) (set-deref r 5) (print x)", "5"),
    ("(set v (vector 1 2)) (print (# v 0))", "1"),
    ("(set v (vector 1 2)) (push v 3) (print (# v 2))", "3"),
    ("(loop i 0 3 (print i))", "0\n1\n2"),
    ("(set x 1) (set r (ref x)) (print (deref r))", "1"),
    ("(print (add 2 3))", "5"),
    ("(print 7)", "7"),
];

#[test]
fn programs_produce_expected_output() {
    for (program, expected) in CASES {
        let result = run_small(program);
        assert_eq!(result, *expected, "Program `{}` output mismatch", program);
    }
}

#[test]
fn write_file_creates_file() {
    let dir = env::temp_dir();
    let out_path = dir.join(format!(
        "test_{}.txt",
        std::time::SystemTime::now()
            .elapsed()
            .unwrap()
            .as_nanos()
    ));
    let program = format!("(write-file \"{}\" \"hello\")", out_path.display());
    let result = run_small_in_dir(&program, &dir);
    assert_eq!(result, "");
    let content = fs::read_to_string(&out_path).expect("file missing");
    assert_eq!(content, "hello");
    fs::remove_file(&out_path).ok();
}
