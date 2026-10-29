//! Real filesystem/process controls; copied images are this actual rustc-built
//! executable, not a mock compiler or shell. Native Windows also exercises the
//! production Bash wrapper against the activated provider and executes it.
#[path = "../path_tools.rs"]
mod path_tools;

mod tests {
    use super::path_tools::*;
    use std::{
        env,
        path::{Path, PathBuf},
        process::Command,
    };
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };

    // No mock process: each candidate is a copy of this real rustc-built test
    // executable, and the selected absolute image must actually execute.
    #[test]
    fn path_order_relative_empty_missing_and_real_process() {
        let root = env::temp_dir().join(format!(
            "ct-path-tools-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        fs::create_dir_all(root.join("first")).unwrap();
        fs::create_dir_all(root.join("second")).unwrap();
        fs::create_dir_all(root.join("child-cwd")).unwrap();
        let name = "bash.exe";
        let image = env::current_exe().unwrap();
        for dir in [&root, &root.join("first"), &root.join("second")] {
            fs::copy(&image, dir.join(name)).unwrap();
        }
        let mut failures = Vec::new();
        let mut verify = |entries: &[&Path], expected: PathBuf| {
            let path = env::join_paths(entries).unwrap();
            let selected = executable_on_path(name, &path, &root).expect("selected executable");
            if !selected.is_absolute() {
                failures.push(format!(
                    "relative executable re-enters Windows system search: {}",
                    selected.display()
                ));
            }
            if selected != expected {
                failures.push(format!(
                    "selected {} instead of {}",
                    selected.display(),
                    expected.display()
                ));
            }
            if !selected.is_absolute() || selected != expected {
                return;
            }
            let result = Command::new(&selected)
                .current_dir(root.join("child-cwd"))
                .arg("--list")
                .output()
                .unwrap();
            assert!(result.status.success());
            assert!(
                String::from_utf8(result.stdout)
                    .unwrap()
                    .contains("path_order_relative_empty_missing_and_real_process")
            );
        };
        verify(
            &[&root.join("second"), &root.join("first")],
            root.join("second").join(name),
        );
        verify(
            &[Path::new("first"), &root.join("second")],
            root.join("first").join(name),
        );
        verify(&[Path::new(""), &root.join("second")], root.join(name));
        assert!(executable_on_path("missing-bash.exe", root.as_os_str(), &root).is_none());
        fs::remove_dir_all(root).unwrap();
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }
}

#[test]
fn bash_wrapper_uses_declared_executable_and_runs() {
    let mut command = path_tools::bash_command();
    let name = if cfg!(windows) { "bash.exe" } else { "bash" };
    let expected = path_tools::which_on_path(name).expect("declared Bash prerequisite");
    assert!(expected.is_absolute());
    #[cfg(windows)]
    assert_eq!(command.get_program(), expected.as_os_str());
    #[cfg(not(windows))]
    assert_eq!(command.get_program(), "bash");
    let output = command.arg("--version").output().expect("execute declared Bash");
    assert!(output.status.success());
    assert!(String::from_utf8(output.stdout).unwrap().contains("GNU bash"));
}
