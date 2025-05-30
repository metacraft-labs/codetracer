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

#[test]
fn prints_add_result() {
    let result = run_small("(print (add 2 3))");
    assert_eq!(result, "5");
}

#[test]
fn prints_loop_numbers() {
    let result = run_small("(loop i 0 3 (print i))");
    assert_eq!(result, "0\n1\n2");
}
