use std::{
    env,
    path::PathBuf,
    process::{self, exit},
};

pub fn run_external(args: &[String]) {
    let name = &args[0];
    let exe_name = String::from("ct-") + name;
    let args = &args[1..];

    let exe = match resolve_executable(&exe_name) {
        Some(exe) => exe,
        None => {
            println!(
                "\"{name}\" subcommand not recognised (maybe you didn't install this module?)"
            );
            exit(1)
        }
    };

    let mut command = process::Command::new(exe);
    command.args(args);

    let mut child = command.spawn().unwrap(); // TODO: handle error
    exit(child.wait().unwrap().code().unwrap()) // TODO: handle errors
}

fn resolve_executable(name: &str) -> Option<PathBuf> {
    // Check if this executable is present in the directory of the tool binary
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|x| x.parent().map(|x| x.to_path_buf()));

    if let Some(exe_dir) = exe_dir {
        let subcommand_exe = exe_dir.join(name);
        if subcommand_exe.is_file() {
            return Some(subcommand_exe);
        }
    }

    // Try to resolve through PATH
    if let Some(paths) = env::var_os("PATH") {
        for dir in env::split_paths(&paths) {
            let candidate = dir.join(name);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }

    None
}
