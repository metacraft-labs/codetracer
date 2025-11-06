use std::env;
use std::path::PathBuf;
use std::sync::{LazyLock, Mutex};

pub struct Paths {
    pub tmp_path: PathBuf,
}

impl Default for Paths {
    fn default() -> Self {
        let tmpdir: PathBuf = if cfg!(target_os = "macos") {
            PathBuf::from(env::var("HOME").unwrap_or("/".to_string()))
                .join("Library/Caches/com.codetracer.CodeTracer/")
        } else {
            env::temp_dir().join("codetracer/")
        };
        Self {
            tmp_path: PathBuf::from(&tmpdir),
        }
    }
}

pub static CODETRACER_PATHS: LazyLock<Mutex<Paths>> =
    LazyLock::new(|| Mutex::new(Paths::default()));
