use std::{collections::BTreeMap, env, fs, path::PathBuf};

pub fn run_list<T: clap::CommandFactory>() {
    let mut subcommands = get_external_subcommands();
    for subcommand in T::command().get_subcommands() {
        subcommands.insert(subcommand.get_name().to_string(), "(internal)".to_string());
    }
    subcommands.insert("help".to_string(), "(internal)".to_string());
    for (name, path) in subcommands {
        println!("{name} => {path}");
    }
}

fn get_external_subcommands() -> BTreeMap<String, String> {
    let mut res = BTreeMap::new();

    // The priority of the path is proportional to its index in this vec
    let mut dirs: Vec<PathBuf> = vec![];

    if let Some(paths) = env::var_os("PATH") {
        dirs.extend(env::split_paths(&paths));
        dirs.reverse();
    }

    if let Some(exe_dir) = std::env::current_exe()
        .ok()
        .and_then(|x| x.parent().map(|x| x.to_path_buf()))
    {
        dirs.push(exe_dir);
    }

    for dir in dirs {
        if let Ok(dir_entries) = fs::read_dir(dir) {
            for entry in dir_entries {
                if let Ok(entry) = entry
                    && entry.path().is_file()
                    && let Some(name) = entry.path().file_name()
                    && let Some(name) = name.to_str()
                    && name.starts_with("ct-")
                {
                    res.insert(String::from(&name[3..]), entry.path().display().to_string());
                }
            }
        }
    }

    res
}
