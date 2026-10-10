use std::path::PathBuf;
use std::sync::{LazyLock, Mutex};

#[allow(dead_code)]
pub struct Paths {
    pub tmp_path: PathBuf,
    pub socket_path: PathBuf,
}

impl Default for Paths {
    fn default() -> Self {
        // `$CODETRACER_HOME/tmp`, else the historical per-OS location
        // (`ct_home::tmp_dir`, the twin of Nim's `paths.codetracerTmpPath`).
        let tmpdir: PathBuf = ct_home::tmp_dir();
        Self {
            tmp_path: PathBuf::from(&tmpdir),
            socket_path: PathBuf::from(&tmpdir).join("ct_socket"),
        }
    }
}

#[allow(dead_code)]
pub static CODETRACER_PATHS: LazyLock<Mutex<Paths>> =
    LazyLock::new(|| Mutex::new(Paths::default()));
