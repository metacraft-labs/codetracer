use std::process::Command;
use std::env;
use std::fs;

fn run_small(program: &str) -> String {
    let dir = env::temp_dir();
    let file_name = format!("test_{}.small", std::time::SystemTime::now().elapsed().unwrap().as_nanos());
    let file_path = dir.join(file_name);
    fs::write(&file_path, program).unwrap();
    let bin = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("target/debug/small-lang");
    let output = Command::new(bin)
        .arg(&file_path)
        .output()
        .expect("failed to run small-lang");
    assert!(output.status.success());
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

const CASES: &[(&str, &str)] = &[
    ("(print (add 2 3))", "5"),
    ("(loop i 0 3 (print i))", "0\n1\n2"),
];

#[test]
fn programs_produce_expected_output() {
    for (program, expected) in CASES {
        let result = run_small(program);
        assert_eq!(result, *expected, "Program `{}` output mismatch", program);
    }
}
