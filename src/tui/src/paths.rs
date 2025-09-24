use std::env;
use std::path::PathBuf;
use std::sync::{LazyLock, Mutex};

pub struct Paths {
    pub tmp_path: PathBuf,
    pub socket_path: PathBuf,
}

impl Default for Paths {
    fn default() -> Self {
        let tmpdir: PathBuf = if cfg!(target_os = "macos") {
            PathBuf::from(env::var("HOME").unwrap_or("/".to_string())).join("Library/Caches/com.codetracer.CodeTracer/")
        } else {
            PathBuf::from(env::temp_dir()).join("codetracer/")
        };
        Self {
            tmp_path: PathBuf::from(&tmpdir),
            socket_path: PathBuf::from(&tmpdir).join("ct_socket"),
        }
    }
}

pub static CODETRACER_PATHS: LazyLock<Mutex<Paths>> = LazyLock::new(|| Mutex::new(Paths::default()));
