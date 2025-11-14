// copied from Stan's paths.rs in src/db-backend in the public codetracer repo
//   added run_dir/ct_rr_worker_socket_path (and copied to db-backend too)

use std::env;
use std::error::Error;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

pub struct Paths {
    pub tmp_path: PathBuf,
    pub client_socket_path: PathBuf,
    pub socket_path: PathBuf,
}

impl Default for Paths {
    fn default() -> Self {
        let tmpdir: PathBuf = if cfg!(target_os = "macos") {
            PathBuf::from(env::var("HOME").unwrap_or("/".to_string())).join("Library/Caches/com.codetracer.CodeTracer/")
        } else {
            env::temp_dir().join("codetracer/")
        };
        Self {
            tmp_path: PathBuf::from(&tmpdir),
            client_socket_path: PathBuf::from(&tmpdir).join("ct_client_socket"),
            socket_path: PathBuf::from(&tmpdir).join("ct_socket"),
        }
    }
}

pub static CODETRACER_PATHS: LazyLock<Mutex<Paths>> = LazyLock::new(|| Mutex::new(Paths::default()));

pub fn run_dir_for(tmp_path: &Path, run_id: usize) -> Result<PathBuf, Box<dyn Error>> {
    let run_dir = tmp_path.join(format!("run-{run_id}"));
    std::fs::create_dir_all(&run_dir)?;
    Ok(run_dir)
}

pub fn ct_rr_worker_socket_path(
    from: &str,
    worker_name: &str,
    worker_index_for_kind: usize,
    run_id: usize,
) -> Result<PathBuf, Box<dyn Error>> {
    let tmp_path: PathBuf = { CODETRACER_PATHS.lock()?.tmp_path.clone() };
    let run_dir = run_dir_for(&tmp_path, run_id)?;
    // eventually: TODO: unique index or better cleanup
    //  if worker with the same name started/restarted multiple times
    //  by the same backend instance
    Ok(run_dir.join(format!(
        "ct_rr_support_{worker_name}_{worker_index_for_kind}_from_{from}.sock"
    )))

    // TODO: decide if we need to check/eventually remove or the unique run folder/paths are enough:
    //
    // if std::fs::metadata(&receiving_socket_path).is_ok() {
    // let _ = std::fs::remove_file(&receiving_socket_path); // try to remove if existing: ignore error
    // }
}
