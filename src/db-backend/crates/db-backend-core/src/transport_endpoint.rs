use std::path::{Path, PathBuf};

/// Cross-platform DAP transport endpoint descriptor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DapEndpoint {
    UnixSocket(PathBuf),
    WindowsNamedPipe(String),
    Stdio,
}

/// Derive a stable endpoint instance name from a base name and process id.
pub fn endpoint_instance_name(base_name: &str, pid: usize) -> String {
    format!("{base_name}_{pid}")
}

/// Build a Unix domain socket path from a socket directory and endpoint metadata.
pub fn unix_socket_path_for_pid(
    socket_dir: &Path,
    base_name: &str,
    pid: usize,
    extension: Option<&str>,
) -> PathBuf {
    let mut endpoint_name = endpoint_instance_name(base_name, pid);
    if let Some(ext) = extension.filter(|ext| !ext.is_empty()) {
        endpoint_name.push('.');
        endpoint_name.push_str(ext);
    }
    socket_dir.join(endpoint_name)
}

/// Build a full Windows named-pipe path for a given endpoint base and pid.
///
/// This is string-only groundwork; actual pipe runtime hookup is handled elsewhere.
pub fn windows_named_pipe_path_for_pid(base_name: &str, pid: usize) -> String {
    let raw_name = endpoint_instance_name(base_name, pid);
    let sanitized = sanitize_windows_pipe_name(&raw_name);
    format!(r"\\.\pipe\{sanitized}")
}

fn sanitize_windows_pipe_name(raw_name: &str) -> String {
    let mut sanitized = String::with_capacity(raw_name.len());
    for ch in raw_name.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.') {
            sanitized.push(ch);
        } else {
            sanitized.push('_');
        }
    }

    if sanitized.is_empty() {
        "ct_dap_pipe".to_string()
    } else {
        sanitized
    }
}

#[cfg(test)]
mod tests {
    use super::{endpoint_instance_name, unix_socket_path_for_pid, windows_named_pipe_path_for_pid, DapEndpoint};
    use std::path::Path;

    #[test]
    fn endpoint_instance_name_is_base_plus_pid() {
        assert_eq!(endpoint_instance_name("ct_dap_socket", 4242), "ct_dap_socket_4242");
    }

    #[test]
    fn unix_socket_path_uses_extension_when_present() {
        let path = unix_socket_path_for_pid(Path::new("/tmp"), "ct_dap_socket", 42, Some("sock"));
        assert_eq!(path, Path::new("/tmp").join("ct_dap_socket_42.sock"));
    }

    #[test]
    fn unix_socket_path_skips_extension_when_missing() {
        let path = unix_socket_path_for_pid(Path::new("/tmp"), "ct_dap_socket", 42, None);
        assert_eq!(path, Path::new("/tmp").join("ct_dap_socket_42"));
    }

    #[test]
    fn windows_named_pipe_path_sanitizes_unsupported_chars() {
        let path = windows_named_pipe_path_for_pid("ct dap/socket", 42);
        assert_eq!(path, r"\\.\pipe\ct_dap_socket_42");
    }

    #[test]
    fn endpoint_enum_preserves_payload() {
        let endpoint = DapEndpoint::WindowsNamedPipe(r"\\.\pipe\ct_dap_socket_12".to_string());
        assert_eq!(endpoint, DapEndpoint::WindowsNamedPipe(r"\\.\pipe\ct_dap_socket_12".to_string()));
    }
}
