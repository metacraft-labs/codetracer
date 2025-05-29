use std::path::PathBuf;
use std::sync::{ Mutex, LazyLock };
use std::env;

pub struct Paths
{
    pub tmp_path: PathBuf,
    pub client_socket_path: PathBuf,
    pub socket_path: PathBuf,
}

impl Default for Paths
{
    fn default() -> Self
    {
        let tmpdir: PathBuf = if cfg!(target_os = "macos")
        {
            PathBuf::from(env::var("HOME").unwrap_or("/".to_string())).join("Library/Caches/com.codetracer.CodeTracer/codetracer")
        }
        else
        {
            PathBuf::from(env::var("TMPDIR").unwrap_or(
                env::var("TEMPDIR").unwrap_or(
                    env::var("TMP").unwrap_or(
                        env::var("TEMP").unwrap_or(
                            "/tmp".to_string()
                        )
                    )
                )
            )).join("codetracer/codetracer")
        };
        Self {
            tmp_path: PathBuf::from(&tmpdir),
            client_socket_path: PathBuf::from(&tmpdir).join("ct_client_socket"),
            socket_path: PathBuf::from(&tmpdir).join("ct_socket"),
        }
    }   
}

pub static CODETRACER_PATHS: LazyLock<Mutex<Paths>> = LazyLock::new(|| {
    Mutex::new(Paths::default())
});
