use std::{path::PathBuf, str::FromStr};

use crate::{Lang, RecordOptions};

pub fn run_record(options: RecordOptions) {
    let lang = options.lang.or_else(|| detect_language(&options.program));
    println!("{:#?}", lang);
}

fn detect_language(program: &str) -> Option<Lang> {
    let path = match PathBuf::from_str(program) {
        Ok(x) => x,
        _ => return None,
    };

    if path.is_dir() {
        if let Some(x) = detect_language_folder(&path) {
            return Some(x);
        }
    } else {
        if let Some(x) = detect_language_file(&path) {
            return Some(x);
        }
    };

    None
}

fn detect_language_folder(path: &PathBuf) -> Option<Lang> {
    let nargo_path = path.join("Nargo.toml");

    if nargo_path.is_file() {
        Some(Lang::Noir)
    } else {
        None
    }
}

fn detect_language_file(path: &PathBuf) -> Option<Lang> {
    let extension = if let Some(ext_raw) = path.extension()
        && let Some(ext) = ext_raw.to_str()
    {
        ext.to_string().to_lowercase()
    } else {
        return None;
    };

    match extension.as_str() {
        "py" => Some(Lang::Python),
        "rb" => Some(Lang::Ruby),
        "nr" => Some(Lang::Noir),
        "small" => Some(Lang::Small),
        "wasm" => Some(Lang::Wasm),
        _ => None,
    }
}
