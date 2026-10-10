//! Where CodeTracer keeps a user's own state — the ONE Rust resolver for every
//! per-user location, and the `CODETRACER_HOME` override that relocates all of
//! them at once.
//!
//! The Nim twin is `src/common/ct_home.nim`; read its header for the full
//! table. The layout, which both sides must agree on:
//!
//! ```text
//! $CODETRACER_HOME/
//!   data/      trace index, recordings, ct-native-replay's state.db
//!   config/    origin-patterns.toml, daemon.conf, license.dat, .config.yaml
//!   state/     daemon.log, native layout state, run stores
//!   cache/     observability trace cache (traces/), mapping catalog
//!   tmp/       what used to be %TEMP%\codetracer / $TMPDIR/codetracer
//!   launcher/  the launcher's user root when CODETRACER_USER_ROOT is unset
//! ```
//!
//! When `CODETRACER_HOME` is set, every location derives from it on every OS
//! and no other variable (`HOME`, `USERPROFILE`, `XDG_*_HOME`, `TMPDIR`, …) is
//! consulted for it. When it is unset, every location resolves exactly as the
//! call site did before this crate existed: the legacy fallback is either
//! implemented here verbatim (`tmp_dir`, `config_dir`) or passed in by the
//! call site (`area_or`), so nothing moves for a user who never sets it.
//!
//! It exists for test isolation. A suite that redirects `HOME` misses
//! `USERPROFILE` on Windows, `XDG_DATA_HOME` on Linux, and so on; on
//! 2026-09-23 exactly that wrote test recordings into a developer's real trace
//! index. Children inherit `CODETRACER_HOME` through the ordinary environment,
//! so a spawned replay worker resolves the same directories as its parent.

use std::env;
use std::ffi::OsString;
use std::path::PathBuf;

/// The one variable that relocates every per-user location.
pub const CODETRACER_HOME_ENV: &str = "CODETRACER_HOME";

/// The fixed subdirectories of `$CODETRACER_HOME`. [`Area::dir_name`] spells
/// them exactly as `ct_home.nim`'s `CtHomeArea` does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Area {
    Data,
    Config,
    State,
    Cache,
    Tmp,
    Launcher,
}

impl Area {
    pub const ALL: [Area; 6] = [
        Area::Data,
        Area::Config,
        Area::State,
        Area::Cache,
        Area::Tmp,
        Area::Launcher,
    ];

    pub fn dir_name(self) -> &'static str {
        match self {
            Area::Data => "data",
            Area::Config => "config",
            Area::State => "state",
            Area::Cache => "cache",
            Area::Tmp => "tmp",
            Area::Launcher => "launcher",
        }
    }
}

fn non_empty_var(name: &str) -> Option<OsString> {
    env::var_os(name).filter(|v| !v.is_empty())
}

/// `$CODETRACER_HOME` as an absolute path, or `None` when it is unset or empty.
/// A relative value is resolved against the current directory.
pub fn codetracer_home() -> Option<PathBuf> {
    let raw = PathBuf::from(non_empty_var(CODETRACER_HOME_ENV)?);
    if raw.is_absolute() {
        Some(raw)
    } else {
        Some(env::current_dir().map(|cwd| cwd.join(&raw)).unwrap_or(raw))
    }
}

/// `$CODETRACER_HOME/<area>`, or `None` when `CODETRACER_HOME` is unset.
pub fn area(area: Area) -> Option<PathBuf> {
    codetracer_home().map(|home| home.join(area.dir_name()))
}

/// `$CODETRACER_HOME/<area>` when it is set, else whatever `legacy` returns —
/// the call site's historical resolution, unchanged.
pub fn area_or(area_: Area, legacy: impl FnOnce() -> Option<PathBuf>) -> Option<PathBuf> {
    area(area_).or_else(legacy)
}

/// What `CODETRACER_PATHS.tmp_path` has always been (sockets, per-run dirs):
/// `$CODETRACER_HOME/tmp`, else (macOS) `$HOME/Library/Caches/com.codetracer.CodeTracer/`,
/// else `std::env::temp_dir()/codetracer/`. Agrees with `ct_home.ctTmpDir`.
pub fn tmp_dir() -> PathBuf {
    if let Some(dir) = area(Area::Tmp) {
        return dir;
    }
    if cfg!(target_os = "macos") {
        PathBuf::from(env::var("HOME").unwrap_or("/".to_string()))
            .join("Library/Caches/com.codetracer.CodeTracer/")
    } else {
        env::temp_dir().join("codetracer/")
    }
}

/// The user's CodeTracer config directory: `$CODETRACER_HOME/config`, else
/// `$XDG_CONFIG_HOME/codetracer`, else `$HOME/.config/codetracer`, else `None`
/// (neither variable set — an unusual hermetic environment).
pub fn config_dir() -> Option<PathBuf> {
    area_or(Area::Config, || {
        if let Some(xdg) = non_empty_var("XDG_CONFIG_HOME") {
            return Some(PathBuf::from(xdg).join("codetracer"));
        }
        non_empty_var("HOME").map(|home| PathBuf::from(home).join(".config").join("codetracer"))
    })
}

/// Test support: give this process (and every child it spawns) a private,
/// scratch `CODETRACER_HOME`, unless it already has one. Returns the directory.
///
/// "Already has one" means `CODETRACER_HOME` is set and lies inside the OS temp
/// directory, or holds a `.codetracer-test-home` marker file — the same rule
/// as `src/frontend/test_support/state_isolation.nim`. A developer's own
/// `CODETRACER_HOME` is therefore never used by a test; a harness's is kept.
///
/// Call it at the start of a test (or from a test harness's shared setup)
/// before anything resolves a path or spawns a CodeTracer binary. It is
/// idempotent and cheap. Not for production code: it writes the process
/// environment, which is only sound while no other thread reads it.
pub fn isolate_for_tests() -> PathBuf {
    use std::sync::OnceLock;
    static ISOLATED: OnceLock<PathBuf> = OnceLock::new();
    ISOLATED
        .get_or_init(|| {
            if let Some(existing) = codetracer_home() {
                if is_test_scratch(&existing) {
                    return existing;
                }
            }
            let dir = env::temp_dir().join(format!(
                "ct-test-home-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0)
            ));
            std::fs::create_dir_all(&dir).expect("create a scratch CODETRACER_HOME");
            // Edition 2021: `set_var` is safe to call; the race it can cause
            // with a concurrent reader is the caller's to avoid (see above).
            env::set_var(CODETRACER_HOME_ENV, &dir);
            dir
        })
        .clone()
}

/// The marker file that makes a directory outside the temp dir acceptable as a
/// test `CODETRACER_HOME`.
pub const TEST_HOME_MARKER: &str = ".codetracer-test-home";

/// Whether `path` is a scratch `CODETRACER_HOME` a test may use.
pub fn is_test_scratch(path: &std::path::Path) -> bool {
    let tmp = env::temp_dir();
    let norm = |p: &std::path::Path| -> String {
        let s = p.to_string_lossy().replace('\\', "/");
        if cfg!(windows) {
            s.to_lowercase()
        } else {
            s
        }
    };
    let (p, t) = (norm(path), norm(&tmp));
    let t = t.trim_end_matches('/');
    p == t || p.starts_with(&format!("{t}/")) || path.join(TEST_HOME_MARKER).is_file()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // The environment is process-global; serialise the cases that write it.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct Restore(Vec<(&'static str, Option<OsString>)>);
    impl Drop for Restore {
        fn drop(&mut self) {
            for (k, v) in self.0.drain(..) {
                match v {
                    Some(v) => env::set_var(k, v),
                    None => env::remove_var(k),
                }
            }
        }
    }
    fn saving(keys: &[&'static str]) -> Restore {
        Restore(keys.iter().map(|k| (*k, env::var_os(k))).collect())
    }

    #[test]
    fn every_area_is_under_codetracer_home_when_it_is_set() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _r = saving(&[CODETRACER_HOME_ENV, "XDG_CONFIG_HOME", "HOME"]);
        let root = env::temp_dir().join("ct-home-crate-test-set");
        env::set_var(CODETRACER_HOME_ENV, &root);
        // Decoys: none of these may be consulted while CODETRACER_HOME is set.
        env::set_var("XDG_CONFIG_HOME", "/decoy/xdg-config");
        env::set_var("HOME", "/decoy/home");
        for a in Area::ALL {
            assert_eq!(area(a), Some(root.join(a.dir_name())), "{a:?}");
        }
        assert_eq!(tmp_dir(), root.join("tmp"));
        assert_eq!(config_dir(), Some(root.join("config")));
        assert_eq!(
            area_or(Area::Cache, || Some(PathBuf::from("/legacy"))),
            Some(root.join("cache"))
        );
    }

    #[test]
    fn unset_keeps_every_legacy_location() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _r = saving(&[CODETRACER_HOME_ENV, "XDG_CONFIG_HOME", "HOME"]);
        env::remove_var(CODETRACER_HOME_ENV);
        assert_eq!(codetracer_home(), None);
        for a in Area::ALL {
            assert_eq!(area(a), None, "{a:?}");
        }
        if !cfg!(target_os = "macos") {
            assert_eq!(tmp_dir(), env::temp_dir().join("codetracer/"));
        }
        env::set_var("XDG_CONFIG_HOME", "/x/cfg");
        assert_eq!(
            config_dir(),
            Some(PathBuf::from("/x/cfg").join("codetracer"))
        );
        env::remove_var("XDG_CONFIG_HOME");
        env::set_var("HOME", "/h");
        assert_eq!(
            config_dir(),
            Some(PathBuf::from("/h").join(".config").join("codetracer"))
        );
        assert_eq!(
            area_or(Area::Cache, || Some(PathBuf::from("/legacy"))),
            Some(PathBuf::from("/legacy"))
        );
        // An empty value is "unset", not "the current directory".
        env::set_var(CODETRACER_HOME_ENV, "");
        assert_eq!(codetracer_home(), None);
    }

    #[test]
    fn the_spellings_match_the_nim_twin() {
        // `src/common/ct_home.nim`'s `CtHomeArea` string values, read from the
        // source so a rename on either side fails here.
        let nim = include_str!("../../../src/common/ct_home.nim");
        for a in Area::ALL {
            let needle = format!("= \"{}\"", a.dir_name());
            assert!(nim.contains(&needle), "ct_home.nim lacks {needle}");
        }
        assert!(nim.contains(&format!("\"{CODETRACER_HOME_ENV}\"")));
    }

    #[test]
    fn a_developer_home_is_not_test_scratch_but_a_temp_dir_is() {
        assert!(is_test_scratch(&env::temp_dir().join("ct-x")));
        assert!(!is_test_scratch(std::path::Path::new(if cfg!(windows) {
            r"C:\Users\someone\ct-home"
        } else {
            "/home/someone/ct-home"
        })));
    }
}
