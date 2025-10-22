use std::env;
use std::path::PathBuf;
use std::sync::{LazyLock, Mutex};

pub struct Paths {
    pub tmp_path: PathBuf,
}

impl Default for Paths {
    fn default() -> Self {
        let raw_tmp = if cfg!(target_os = "macos") {
            PathBuf::from(env::var("HOME").unwrap_or("/".to_string()))
                .join("Library/Caches/com.codetracer.CodeTracer/")
        } else {
            env::temp_dir()
        };

        #[cfg(unix)]
        let sanitized_tmp = {
            const MAX_TMP_LEN: usize = 64;
            let raw_tmp_str = raw_tmp.to_string_lossy();
            if raw_tmp_str.len() > MAX_TMP_LEN {
                PathBuf::from("/tmp")
            } else {
                raw_tmp.clone()
            }
        };

        #[cfg(not(unix))]
        let sanitized_tmp = raw_tmp.clone();

        let tmpdir: PathBuf = if cfg!(target_os = "macos") {
            sanitized_tmp
        } else {
            sanitized_tmp.join("codetracer/")
        };
        Self {
            tmp_path: PathBuf::from(&tmpdir),
        }
    }
}

pub static CODETRACER_PATHS: LazyLock<Mutex<Paths>> =
    LazyLock::new(|| Mutex::new(Paths::default()));
