//! Daemon configuration.
//!
//! Configuration values are resolved in order of decreasing priority:
//!
//! 1. **Environment variables** — `CODETRACER_DAEMON_TTL`, `CODETRACER_MAX_SESSIONS`,
//!    `CODETRACER_DAEMON_SOCKET`, `CODETRACER_DAEMON_LOG`, `CODETRACER_DAEMON_CONFIG`.
//! 2. **Config file** — A simple `KEY=VALUE` file (one per line, `#` comments).
//!    The default location is `~/.codetracer/daemon.conf`, overridable via
//!    `CODETRACER_DAEMON_CONFIG`.
//! 3. **Built-in defaults** — 300 s TTL, 10 max sessions.
//!
//! The config file format is intentionally kept simple so that we do not
//! need a YAML or TOML parsing dependency.
//!
//! Example config file:
//! ```text
//! # TTL in seconds for idle sessions.
//! default_ttl = 120
//!
//! # Maximum number of concurrent trace sessions.
//! max_sessions = 5
//! ```

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

// ---------------------------------------------------------------------------
// Environment variable names
// ---------------------------------------------------------------------------

/// TTL (in seconds) for idle sessions.
const ENV_TTL: &str = "CODETRACER_DAEMON_TTL";
/// Maximum number of concurrent trace sessions the daemon will allow.
const ENV_MAX_SESSIONS: &str = "CODETRACER_MAX_SESSIONS";
/// Override for the daemon's Unix socket path.
const ENV_SOCKET: &str = "CODETRACER_DAEMON_SOCKET";
/// Override for the daemon log file path.
const ENV_LOG: &str = "CODETRACER_DAEMON_LOG";
/// Path to an alternative config file.
const ENV_CONFIG: &str = "CODETRACER_DAEMON_CONFIG";

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

/// Default idle-session TTL: 5 minutes.
const DEFAULT_TTL_SECS: u64 = 300;
/// Default maximum number of concurrent sessions.
const DEFAULT_MAX_SESSIONS: usize = 10;

// ---------------------------------------------------------------------------
// DaemonConfig
// ---------------------------------------------------------------------------

/// Runtime configuration for the backend-manager daemon.
///
/// Constructed once at daemon startup via [`DaemonConfig::load`] and then
/// threaded through the daemon's subsystems (session manager, logging, etc.).
#[derive(Debug, Clone)]
pub struct DaemonConfig {
    /// How long an idle session is kept alive before being evicted.
    pub default_ttl: Duration,
    /// Maximum number of concurrently loaded trace sessions.
    pub max_sessions: usize,
    /// Optional override for the daemon's Unix socket path.
    /// When `None`, the daemon uses the well-known default from [`crate::paths`].
    pub socket_path: Option<PathBuf>,
    /// Optional override for the daemon log file path.
    pub log_file: Option<PathBuf>,
}

impl Default for DaemonConfig {
    fn default() -> Self {
        Self {
            default_ttl: Duration::from_secs(DEFAULT_TTL_SECS),
            max_sessions: DEFAULT_MAX_SESSIONS,
            socket_path: None,
            log_file: None,
        }
    }
}

impl DaemonConfig {
    /// Loads configuration by merging (in priority order) environment variables,
    /// the config file, and built-in defaults.
    ///
    /// Errors are logged but never fatal — a bad value in the config file simply
    /// causes the corresponding field to fall back to its default.
    pub fn load() -> Self {
        let mut cfg = Self::default();

        // --- Layer 1: config file (lowest priority of the two overrides) ---
        let config_path = std::env::var(ENV_CONFIG)
            .map(PathBuf::from)
            .ok()
            .or_else(default_config_path);

        if let Some(path) = config_path
            && path.exists()
        {
            match std::fs::read_to_string(&path) {
                Ok(contents) => {
                    let kv = parse_config_file(&contents);
                    apply_config_map(&mut cfg, &kv);
                }
                Err(e) => {
                    log::warn!("Cannot read config file {}: {e}", path.display());
                }
            }
        }

        // --- Layer 2: environment variables (highest priority) ---
        if let Ok(val) = std::env::var(ENV_TTL) {
            match val.parse::<u64>() {
                Ok(secs) => cfg.default_ttl = Duration::from_secs(secs),
                Err(e) => log::warn!("{ENV_TTL} has invalid value '{val}': {e}"),
            }
        }

        if let Ok(val) = std::env::var(ENV_MAX_SESSIONS) {
            match val.parse::<usize>() {
                Ok(0) => log::warn!("{ENV_MAX_SESSIONS} must be > 0, ignoring"),
                Ok(n) => cfg.max_sessions = n,
                Err(e) => log::warn!("{ENV_MAX_SESSIONS} has invalid value '{val}': {e}"),
            }
        }

        if let Ok(val) = std::env::var(ENV_SOCKET) {
            cfg.socket_path = Some(PathBuf::from(val));
        }

        if let Ok(val) = std::env::var(ENV_LOG) {
            cfg.log_file = Some(PathBuf::from(val));
        }

        cfg
    }
}

// ---------------------------------------------------------------------------
// Config file parsing helpers
// ---------------------------------------------------------------------------

/// Returns `~/.codetracer/daemon.conf` if `$HOME` is set.
fn default_config_path() -> Option<PathBuf> {
    std::env::var("HOME")
        .ok()
        .map(|home| PathBuf::from(home).join(".codetracer").join("daemon.conf"))
}

/// Parses a simple `KEY = VALUE` config file.
///
/// - Lines starting with `#` (after optional whitespace) are comments.
/// - Empty lines are ignored.
/// - Keys and values are trimmed of surrounding whitespace.
fn parse_config_file(contents: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    for line in contents.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if let Some((key, value)) = trimmed.split_once('=') {
            map.insert(key.trim().to_string(), value.trim().to_string());
        }
    }
    map
}

/// Applies key-value pairs from a config file to a `DaemonConfig`.
fn apply_config_map(cfg: &mut DaemonConfig, kv: &HashMap<String, String>) {
    if let Some(val) = kv.get("default_ttl") {
        match val.parse::<u64>() {
            Ok(secs) => cfg.default_ttl = Duration::from_secs(secs),
            Err(e) => log::warn!("config: default_ttl '{val}' is not a valid number: {e}"),
        }
    }

    if let Some(val) = kv.get("max_sessions") {
        match val.parse::<usize>() {
            Ok(0) => log::warn!("config: max_sessions must be > 0"),
            Ok(n) => cfg.max_sessions = n,
            Err(e) => log::warn!("config: max_sessions '{val}' is not a valid number: {e}"),
        }
    }

    if let Some(val) = kv.get("socket_path") {
        cfg.socket_path = Some(PathBuf::from(val));
    }

    if let Some(val) = kv.get("log_file") {
        cfg.log_file = Some(PathBuf::from(val));
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let cfg = DaemonConfig::default();
        assert_eq!(cfg.default_ttl, Duration::from_secs(300));
        assert_eq!(cfg.max_sessions, 10);
        assert!(cfg.socket_path.is_none());
        assert!(cfg.log_file.is_none());
    }

    #[test]
    fn test_parse_config_file_basic() {
        let contents = r#"
# Comment line
default_ttl = 120
max_sessions = 5

# Another comment
socket_path = /tmp/test.sock
"#;
        let kv = parse_config_file(contents);
        assert_eq!(kv.get("default_ttl").unwrap(), "120");
        assert_eq!(kv.get("max_sessions").unwrap(), "5");
        assert_eq!(kv.get("socket_path").unwrap(), "/tmp/test.sock");
    }

    #[test]
    fn test_parse_config_file_empty() {
        let kv = parse_config_file("");
        assert!(kv.is_empty());
    }

    #[test]
    fn test_parse_config_file_comments_only() {
        let contents = "# just a comment\n  # indented comment\n";
        let kv = parse_config_file(contents);
        assert!(kv.is_empty());
    }

    #[test]
    fn test_apply_config_map() {
        let mut cfg = DaemonConfig::default();
        let mut kv = HashMap::new();
        kv.insert("default_ttl".to_string(), "60".to_string());
        kv.insert("max_sessions".to_string(), "3".to_string());

        apply_config_map(&mut cfg, &kv);

        assert_eq!(cfg.default_ttl, Duration::from_secs(60));
        assert_eq!(cfg.max_sessions, 3);
    }

    #[test]
    fn test_apply_config_map_invalid_ttl_ignored() {
        let mut cfg = DaemonConfig::default();
        let mut kv = HashMap::new();
        kv.insert("default_ttl".to_string(), "not_a_number".to_string());

        apply_config_map(&mut cfg, &kv);

        // Should remain at default.
        assert_eq!(cfg.default_ttl, Duration::from_secs(300));
    }

    #[test]
    fn test_apply_config_map_zero_sessions_ignored() {
        let mut cfg = DaemonConfig::default();
        let mut kv = HashMap::new();
        kv.insert("max_sessions".to_string(), "0".to_string());

        apply_config_map(&mut cfg, &kv);

        // Should remain at default.
        assert_eq!(cfg.max_sessions, 10);
    }
}
