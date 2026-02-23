use log::{error, info, warn};
use serde_json::json;
use std::error::Error;
use std::io::{BufReader, Read, Write};
use std::process::Child;
use std::process::Command;
use tokio::sync::mpsc;

#[cfg(unix)]
use std::os::unix::net::UnixStream;

#[cfg(windows)]
use std::ffi::OsStr;
#[cfg(windows)]
use std::os::windows::ffi::OsStrExt;
#[cfg(windows)]
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
#[cfg(windows)]
use std::ptr::null_mut;
#[cfg(windows)]
use windows_sys::Win32::Foundation::{
    GetLastError, ERROR_NO_DATA, ERROR_PIPE_CONNECTED, ERROR_PIPE_LISTENING,
    ERROR_PIPE_NOT_CONNECTED, INVALID_HANDLE_VALUE,
};
#[cfg(windows)]
use windows_sys::Win32::Storage::FileSystem::{FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_DUPLEX};
#[cfg(windows)]
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, SetNamedPipeHandleState, PIPE_NOWAIT, PIPE_READMODE_BYTE,
    PIPE_TYPE_BYTE, PIPE_WAIT,
};

//mod paths;
#[cfg(unix)]
use crate::paths::CODETRACER_PATHS;

const DAP_SOCKET_NAME: &str = "ct_dap_socket";

#[cfg(unix)]
type DapReaderStream = UnixStream;
#[cfg(unix)]
type DapWriterStream = UnixStream;
#[cfg(windows)]
type DapReaderStream = std::fs::File;
#[cfg(windows)]
type DapWriterStream = std::fs::File;
#[cfg(not(any(unix, windows)))]
type DapReaderStream = std::io::Cursor<Vec<u8>>;
#[cfg(not(any(unix, windows)))]
type DapWriterStream = std::io::Sink;

pub struct DapClient {
    child: Child,
    reader: BufReader<DapReaderStream>,
    writer: DapWriterStream,
    seq: i64,
}

fn endpoint_instance_name(base_name: &str, pid: usize) -> String {
    format!("{base_name}_{pid}")
}

#[cfg(unix)]
fn unix_socket_path(tmp_path: &std::path::Path, pid: usize) -> std::path::PathBuf {
    tmp_path.join(endpoint_instance_name(DAP_SOCKET_NAME, pid))
}

#[cfg(windows)]
fn windows_named_pipe_path(pid: usize) -> String {
    format!(r"\\.\pipe\{}", endpoint_instance_name(DAP_SOCKET_NAME, pid))
}

#[cfg(windows)]
fn create_windows_named_pipe_listener(pipe_path: &str) -> Result<OwnedHandle, Box<dyn Error>> {
    let pipe_path_wide: Vec<u16> = OsStr::new(pipe_path)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();

    unsafe {
        let handle = CreateNamedPipeW(
            pipe_path_wide.as_ptr(),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT,
            1,
            64 * 1024,
            64 * 1024,
            0,
            null_mut(),
        );

        if handle == INVALID_HANDLE_VALUE {
            let err = GetLastError();
            return Err(format!(
                "failed creating Windows named pipe listener '{pipe_path}' (error code {err}); verify endpoint path and that no stale first-instance listener exists"
            )
            .into());
        }

        Ok(OwnedHandle::from_raw_handle(handle as *mut _))
    }
}

#[cfg(all(test, windows))]
mod windows_transport_tests {
    use super::*;
    use serde_json::json;
    use std::fs::{self, OpenOptions};
    use std::io::{self, BufRead, BufReader, Read, Write};
    use std::path::{Path, PathBuf};
    use std::process::Child;
    use std::sync::{LazyLock, Mutex};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    static START_TEST_MUTEX: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

    fn unique_test_pipe_path(prefix: &str) -> String {
        // Keep test endpoints isolated so tests can run in parallel without
        // colliding on FILE_FLAG_FIRST_PIPE_INSTANCE semantics.
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_nanos();
        format!(r"\\.\pipe\{prefix}_{}_{}", std::process::id(), nonce)
    }

    fn unique_test_file_path(prefix: &str, extension: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "{prefix}_{}_{}.{}",
            std::process::id(),
            nonce,
            extension
        ))
    }

    fn write_dap_message(
        writer: &mut dyn Write,
        msg: &serde_json::Value,
    ) -> Result<(), Box<dyn Error>> {
        let payload = serde_json::to_vec(msg)?;
        write!(writer, "Content-Length: {}\r\n\r\n", payload.len())?;
        writer.write_all(&payload)?;
        writer.flush()?;
        Ok(())
    }

    fn read_dap_message(reader: &mut BufReader<std::fs::File>) -> Result<serde_json::Value, Box<dyn Error>> {
        let mut content_length: Option<usize> = None;
        loop {
            let mut line = String::new();
            let bytes = reader.read_line(&mut line)?;
            if bytes == 0 {
                return Err("unexpected EOF while reading DAP headers".into());
            }
            if line == "\r\n" {
                break;
            }

            if let Some(value) = line.strip_prefix("Content-Length:") {
                content_length = Some(value.trim().parse()?);
            }
        }

        let len = content_length.ok_or("missing Content-Length header in DAP frame")?;
        let mut payload = vec![0u8; len];
        reader.read_exact(&mut payload)?;
        Ok(serde_json::from_slice(&payload)?)
    }

    fn wait_for_child_exit(child: &mut Child, timeout: Duration) -> io::Result<std::process::ExitStatus> {
        let start = std::time::Instant::now();
        loop {
            if let Some(status) = child.try_wait()? {
                return Ok(status);
            }
            if start.elapsed() > timeout {
                let _ = child.kill();
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "mock backend did not exit before timeout",
                ));
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    fn create_mock_backend_wrapper_script(script_path: &Path, test_exe: &Path) {
        let script = format!(
            "@echo off\r\n\"{}\" --ignored dap_mock_backend_driver --nocapture -- %1\r\nexit /b %ERRORLEVEL%\r\n",
            test_exe.display()
        );
        fs::write(script_path, script).expect("failed to write mock-backend wrapper script");
    }

    fn open_named_pipe_with_retry_config(
        pipe_path: &str,
        max_retries: usize,
        retry_delay_ms: u64,
    ) -> Result<std::fs::File, Box<dyn Error>> {
        for attempt in 0..max_retries {
            match OpenOptions::new().read(true).write(true).open(pipe_path) {
                Ok(file) => return Ok(file),
                Err(err) if attempt + 1 < max_retries => {
                    let _ = err;
                    std::thread::sleep(Duration::from_millis(retry_delay_ms));
                }
                Err(err) => {
                    return Err(format!(
                        "mock backend failed to connect to named pipe '{pipe_path}' after {} retries: {err}",
                        max_retries
                    )
                    .into());
                }
            }
        }
        Err("unreachable retry loop for named-pipe connect".into())
    }

    fn open_named_pipe_with_retry(pipe_path: &str) -> Result<std::fs::File, Box<dyn Error>> {
        open_named_pipe_with_retry_config(pipe_path, 120, 50)
    }

    fn run_mock_backend_handshake(pipe_path: &str) -> Result<(), Box<dyn Error>> {
        let stream = open_named_pipe_with_retry(pipe_path)?;
        let mut reader = BufReader::new(stream.try_clone()?);
        let mut writer = stream;

        let initialize_request = read_dap_message(&mut reader)?;
        if initialize_request.get("type").and_then(|v| v.as_str()) != Some("request")
            || initialize_request.get("command").and_then(|v| v.as_str()) != Some("initialize")
        {
            return Err(format!(
                "expected initialize request, received: {initialize_request}"
            )
            .into());
        }

        let initialize_seq = initialize_request
            .get("seq")
            .and_then(|v| v.as_i64())
            .ok_or("initialize request missing integer seq")?;
        write_dap_message(
            &mut writer,
            &json!({
                "seq": 1,
                "type": "response",
                "request_seq": initialize_seq,
                "command": "initialize",
                "success": true,
                "body": {}
            }),
        )?;

        let launch_request = read_dap_message(&mut reader)?;
        if launch_request.get("type").and_then(|v| v.as_str()) != Some("request")
            || launch_request.get("command").and_then(|v| v.as_str()) != Some("launch")
        {
            return Err(format!("expected launch request, received: {launch_request}").into());
        }

        let launch_seq = launch_request
            .get("seq")
            .and_then(|v| v.as_i64())
            .ok_or("launch request missing integer seq")?;
        // Emit initialized before launch response so launch() follows its
        // initialized-event path and sends configurationDone.
        write_dap_message(
            &mut writer,
            &json!({
                "seq": 2,
                "type": "event",
                "event": "initialized",
                "body": {}
            }),
        )?;
        write_dap_message(
            &mut writer,
            &json!({
                "seq": 3,
                "type": "response",
                "request_seq": launch_seq,
                "command": "launch",
                "success": true,
                "body": {}
            }),
        )?;

        let configuration_done_request = read_dap_message(&mut reader)?;
        if configuration_done_request.get("type").and_then(|v| v.as_str()) != Some("request")
            || configuration_done_request.get("kind").and_then(|v| v.as_str())
                != Some("configurationDone")
        {
            return Err(format!(
                "expected configurationDone request kind, received: {configuration_done_request}"
            )
            .into());
        }

        let configuration_done_seq = configuration_done_request
            .get("seq")
            .and_then(|v| v.as_i64())
            .ok_or("configurationDone request missing integer seq")?;
        write_dap_message(
            &mut writer,
            &json!({
                "seq": 4,
                "type": "response",
                "request_seq": configuration_done_seq,
                "command": "configurationDone",
                "success": true,
                "body": {}
            }),
        )?;

        Ok(())
    }

    fn run_start_initialize_launch_session(server_bin: &str) {
        let mut client = DapClient::start(server_bin).expect("DAP client should start");
        client
            .initialize()
            .expect("initialize request should succeed against mock backend");
        client
            .launch(r"C:\tmp\trace", r"C:\tmp\program")
            .expect("launch request should succeed and trigger configurationDone send");

        let status = wait_for_child_exit(&mut client.child, Duration::from_secs(10))
            .expect("mock backend process should exit");
        assert!(
            status.success(),
            "mock backend exited unsuccessfully with status: {status}"
        );
    }

    #[test]
    fn windows_named_pipe_path_uses_expected_namespace_and_name() {
        let pid = 4242usize;
        assert_eq!(
            windows_named_pipe_path(pid),
            r"\\.\pipe\ct_dap_socket_4242"
        );
        assert_eq!(endpoint_instance_name("ct_dap_socket", pid), "ct_dap_socket_4242");
    }

    #[test]
    fn windows_named_pipe_listener_accepts_client_connection() {
        let pipe_path = unique_test_pipe_path("ct_dap_socket_test_handshake");
        let listener = create_windows_named_pipe_listener(&pipe_path)
            .expect("listener should be created for valid Windows named-pipe path");

        let client_pipe_path = pipe_path.clone();
        let client = std::thread::spawn(move || {
            let mut stream = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(&client_pipe_path)
                .expect("client should connect to test named pipe");
            stream
                .write_all(b"ping")
                .expect("client write should succeed");
            stream
        });

        let mut server_stream = accept_windows_named_pipe_client(listener, &pipe_path)
            .expect("listener should accept client connect");
        let mut received = [0u8; 4];
        server_stream
            .read_exact(&mut received)
            .expect("server should read client payload after connect");
        assert_eq!(&received, b"ping");

        let _ = client.join().expect("client thread should finish cleanly");
    }

    #[test]
    fn windows_named_pipe_listener_rejects_invalid_endpoint_name() {
        let err = create_windows_named_pipe_listener("ct_dap_socket_missing_namespace")
            .expect_err("invalid endpoint should not create a named-pipe listener");
        let err_text = err.to_string();
        assert!(
            err_text.contains("failed creating Windows named pipe listener"),
            "unexpected error: {err_text}"
        );
    }

    #[test]
    fn windows_named_pipe_start_initialize_launch_sends_configuration_done() {
        let _start_lock = START_TEST_MUTEX
            .lock()
            .expect("start-test mutex should not be poisoned");
        let test_exe = std::env::current_exe().expect("current test executable path should exist");
        let wrapper_script = unique_test_file_path("ct_dap_mock_backend", "cmd");
        create_mock_backend_wrapper_script(&wrapper_script, &test_exe);

        run_start_initialize_launch_session(path_to_arg(&wrapper_script));
        let _ = fs::remove_file(&wrapper_script);
    }

    #[test]
    fn windows_named_pipe_start_reconnect_after_clean_teardown_succeeds() {
        let _start_lock = START_TEST_MUTEX
            .lock()
            .expect("start-test mutex should not be poisoned");
        let test_exe = std::env::current_exe().expect("current test executable path should exist");
        let wrapper_script = unique_test_file_path("ct_dap_mock_backend_reconnect", "cmd");
        create_mock_backend_wrapper_script(&wrapper_script, &test_exe);

        // DapClient::start uses a PID-based endpoint name pattern. This verifies
        // that after a clean session teardown the same process can start a new
        // session and handshake successfully again.
        run_start_initialize_launch_session(path_to_arg(&wrapper_script));
        run_start_initialize_launch_session(path_to_arg(&wrapper_script));

        let _ = fs::remove_file(&wrapper_script);
    }

    #[test]
    fn windows_named_pipe_start_reports_spawn_error_for_missing_backend_binary() {
        let _start_lock = START_TEST_MUTEX
            .lock()
            .expect("start-test mutex should not be poisoned");
        let missing_backend =
            unique_test_file_path("ct_dap_missing_backend_binary", "exe");
        let err = match DapClient::start(path_to_arg(&missing_backend)) {
            Ok(_) => panic!("missing backend binary should fail before transport startup"),
            Err(err) => err,
        };
        let err_text = err.to_string();
        assert!(
            err_text.contains("failed to spawn DAP backend"),
            "unexpected error: {err_text}"
        );
    }

    #[test]
    fn windows_named_pipe_accept_times_out_without_client_connection() {
        let pipe_path = unique_test_pipe_path("ct_dap_socket_test_timeout");
        let listener = create_windows_named_pipe_listener(&pipe_path)
            .expect("listener should be created for timeout test");
        let err = accept_windows_named_pipe_client_with_retry(listener, &pipe_path, 3, 10)
            .expect_err("accept should time out when no client connects");
        let err_text = err.to_string();
        assert!(
            err_text.contains("timed out waiting for backend to connect"),
            "unexpected timeout error: {err_text}"
        );
    }

    #[test]
    fn windows_named_pipe_single_instance_rejects_second_client_while_first_active() {
        let pipe_path = unique_test_pipe_path("ct_dap_socket_single_instance");
        let listener = create_windows_named_pipe_listener(&pipe_path)
            .expect("listener should be created for single-instance test");

        let (accepted_tx, accepted_rx) = std::sync::mpsc::channel::<()>();
        let server_pipe_path = pipe_path.clone();
        let server = std::thread::spawn(move || {
            let mut server_stream = accept_windows_named_pipe_client(listener, &server_pipe_path)
                .expect("server should accept first client");
            accepted_tx
                .send(())
                .expect("server should signal accepted client");
            let mut ping = [0u8; 1];
            server_stream
                .read_exact(&mut ping)
                .expect("server should read test ping byte");
            // Keep the single available instance occupied so a second client
            // cannot connect until this first connection drops.
            std::thread::sleep(Duration::from_millis(250));
        });

        let mut first_client = open_named_pipe_with_retry(&pipe_path)
            .expect("first client should connect to single pipe instance");
        accepted_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("server should accept first client quickly");
        first_client
            .write_all(&[0x1])
            .expect("first client should write ping to keep connection active");

        let err = open_named_pipe_with_retry_config(&pipe_path, 6, 20)
            .expect_err("second client connect should fail while first is active");
        let err_text = err.to_string();
        assert!(
            err_text.contains("after 6 retries"),
            "unexpected second-client connect error: {err_text}"
        );

        drop(first_client);
        server
            .join()
            .expect("server thread should complete without panic");
    }

    fn path_to_arg(path: &Path) -> &str {
        path.as_os_str()
            .to_str()
            .expect("wrapper path should be valid UTF-8 for Command::new")
    }

    #[test]
    #[ignore]
    fn dap_mock_backend_driver() {
        let pipe_path = std::env::args()
            .find(|arg| arg.starts_with(r"\\.\pipe\"))
            .unwrap_or_else(|| {
                panic!(
                    "expected named-pipe path argument in mock backend driver args: {:?}",
                    std::env::args().collect::<Vec<_>>()
                )
            });

        run_mock_backend_handshake(&pipe_path).expect("mock backend handshake should succeed");
    }
}

#[cfg(windows)]
fn accept_windows_named_pipe_client(
    listener: OwnedHandle,
    pipe_path: &str,
) -> Result<std::fs::File, Box<dyn Error>> {
    accept_windows_named_pipe_client_with_retry(listener, pipe_path, 100, 50)
}

#[cfg(windows)]
fn accept_windows_named_pipe_client_with_retry(
    listener: OwnedHandle,
    pipe_path: &str,
    max_retries: usize,
    retry_delay_ms: u64,
) -> Result<std::fs::File, Box<dyn Error>> {

    let raw_handle = listener.as_raw_handle();
    let mut retries = 0;
    loop {
        unsafe {
            if ConnectNamedPipe(raw_handle as _, null_mut()) != 0 {
                break;
            }
            let err = GetLastError();
            if err == ERROR_PIPE_CONNECTED {
                break;
            }

            if matches!(
                err,
                ERROR_PIPE_LISTENING | ERROR_NO_DATA | ERROR_PIPE_NOT_CONNECTED
            ) && retries < max_retries
            {
                retries += 1;
                std::thread::sleep(std::time::Duration::from_millis(retry_delay_ms));
                continue;
            }

            if matches!(
                err,
                ERROR_PIPE_LISTENING | ERROR_NO_DATA | ERROR_PIPE_NOT_CONNECTED
            ) {
                return Err(format!(
                    "timed out waiting for backend to connect to Windows named pipe '{pipe_path}' after {} ms",
                    max_retries * retry_delay_ms as usize
                )
                .into());
            }

            return Err(format!(
                "failed accepting backend connection on Windows named pipe '{pipe_path}' (error code {err})"
            )
            .into());
        }
    }

    unsafe {
        let mode = PIPE_READMODE_BYTE | PIPE_WAIT;
        if SetNamedPipeHandleState(raw_handle as _, &mode, null_mut(), null_mut()) == 0 {
            let err = GetLastError();
            return Err(format!(
                "backend connected to Windows named pipe '{pipe_path}', but failed to switch pipe to blocking byte mode (error code {err})"
            )
            .into());
        }
    }

    Ok(std::fs::File::from(listener))
}

impl DapClient {
    pub fn start(server_bin: &str) -> Result<Self, Box<dyn Error>> {
        #[cfg(unix)]
        {
            let pid = std::process::id() as usize;
            let tmp_path = { CODETRACER_PATHS.lock()?.tmp_path.clone() };
            let socket_path = unix_socket_path(&tmp_path, pid);
            let _ = std::fs::remove_file(&socket_path);

            let child = if server_bin.ends_with("dlv") {
                Command::new(server_bin)
                    .arg("dap")
                    .arg("-l")
                    .arg(format!("unix:{}", socket_path.display()))
                    .spawn()?
            } else {
                // if server_bin.ends_with("db-backend") {
                Command::new(server_bin).arg(&socket_path).spawn()?
            };

            // wait for server to open socket and connect
            let mut retries = 0;
            let stream = loop {
                match UnixStream::connect(&socket_path) {
                    Ok(s) => break s,
                    Err(_e) if retries < 50 => {
                        std::thread::sleep(std::time::Duration::from_millis(50));
                        retries += 1;
                        continue;
                    }
                    Err(e) => return Err(e.into()),
                }
            };
            let reader_stream = stream.try_clone()?;

            return Ok(Self {
                child,
                reader: BufReader::new(reader_stream),
                writer: stream,
                seq: 1,
            });
        }

        #[cfg(windows)]
        {
            let pid = std::process::id() as usize;
            let pipe_path = windows_named_pipe_path(pid);
            let listener = create_windows_named_pipe_listener(&pipe_path)?;
            let child = if server_bin.ends_with("dlv") {
                return Err("launching dlv with Windows named-pipe transport is not yet supported; use db-backend endpoint mode".into());
            } else {
                Command::new(server_bin)
                    .arg(&pipe_path)
                    .spawn()
                    .map_err(|e| format!("failed to spawn DAP backend '{server_bin}' with endpoint '{pipe_path}': {e}"))?
            };

            let stream = accept_windows_named_pipe_client(listener, &pipe_path)?;
            let reader_stream = stream.try_clone().map_err(|e| {
                format!("connected Windows named pipe '{pipe_path}', but failed to clone stream handle: {e}")
            })?;

            return Ok(Self {
                child,
                reader: BufReader::new(reader_stream),
                writer: stream,
                seq: 1,
            });
        }

        #[cfg(not(any(unix, windows)))]
        {
            let pid = std::process::id() as usize;
            let endpoint_hint = endpoint_instance_name(DAP_SOCKET_NAME, pid);
            let _ = server_bin;
            Err(format!("DAP transport is unsupported on this platform; expected endpoint name hint: {endpoint_hint}").into())
        }
    }

    /// Send an initialize request to the DAP server. The server is expected to
    /// respond with a successful response before other requests are issued.
    pub fn initialize(&mut self) -> Result<(), Box<dyn Error>> {
        let seq = self.seq;
        self.seq += 1;
        let req = json!({
            "seq": seq,
            "type": "request",
            "command": "initialize",
            "arguments": {}
        });
        self.send_message(&req)?;
        let resp = self.read_message()?;
        if resp.get("type").and_then(|v| v.as_str()) == Some("response")
            && resp.get("command").and_then(|v| v.as_str()) == Some("initialize")
            && resp.get("success").and_then(|v| v.as_bool()) == Some(true)
        {
            // let resp_event = self.read_message()?;
            // if resp_event.get("type").and_then(|v| v.as_str()) == Some("event")
            // && resp_event.get("event").and_then(|v| v.as_str()) == Some("initialized")
            // {
            // Ok(())
            // } else {
            // error!("client: DAP: initialize request didn't receive initialized event; resp_event: {:?}", resp_event);
            // Err("DAP: initialize request failed: didn't receive initialized event".into())
            // }
            Ok(())
        } else {
            error!("client: DAP: initialize request failed: resp: {:?}", resp,);
            Err("DAP: initialize request failed".into())
        }
    }

    /// Send a launch request to the DAP server with the current process id and
    /// the path to the trace directory as custom fields.
    pub fn launch(&mut self, trace_path: &str, program: &str) -> Result<(), Box<dyn Error>> {
        let seq = self.seq;
        self.seq += 1;
        let pid = std::process::id();
        let mut initialized = false;
        let req = json!({
            "seq": seq,
            "type": "request",
            "command": "launch",
            "arguments": {
                "pid": pid,
                "tracePath": trace_path,
                "program": program,
            }
        });
        self.send_message(&req)?;
        loop {
            let resp = self.read_message()?;
            if resp.get("type").and_then(|v| v.as_str()) == Some("response")
                && resp.get("command").and_then(|v| v.as_str()) == Some("launch")
                && resp.get("success").and_then(|v| v.as_bool()) == Some(true)
            {
                break;
            } else {
                // TODO: check if initialized: if so, store in a field, to know that
                // it's safe to send breakpoints/other configuration
                // TODO: if db-backend: so after end of `launch` we immediately send
                // configuration-done so it can start and we receive stopped/location etc
                if resp.get("type").and_then(|v| v.as_str()) == Some("event")
                    && resp.get("event").and_then(|v| v.as_str()) == Some("initialized")
                {
                    initialized = true;
                }
                warn!(
                    "client: DAP: launch request expects response: resp: {:?}",
                    resp
                );
            }
        }
        if initialized {
            self.send_configuration_done()?;
        }
        Ok(())
    }

    fn send_configuration_done(&mut self) -> Result<(), Box<dyn Error>> {
        let req = json!({
            "seq": self.seq,
            "type": "request",
            "kind": "configurationDone",
            "arguments": {},
        });
        self.seq += 1;
        self.send_message(&req)?;
        Ok(())
    }

    fn send_message(&mut self, msg: &serde_json::Value) -> Result<(), Box<dyn Error>> {
        let data = serde_json::to_string(msg)?;
        let header = format!("Content-Length: {}\r\n\r\n", data.len());
        info!("client: DAP: ->: {}{}", header, data);
        self.writer.write_all(header.as_bytes())?;
        self.writer.write_all(data.as_bytes())?;
        self.writer.flush()?;
        Ok(())
    }

    fn read_message(&mut self) -> Result<serde_json::Value, Box<dyn Error>> {
        let mut header = Vec::new();
        let mut buf = [0u8; 1];
        while !header.ends_with(b"\r\n\r\n") {
            self.reader.read_exact(&mut buf)?;
            header.push(buf[0]);
        }
        let header_str = String::from_utf8(header)?;
        let len_line = header_str
            .lines()
            .find(|l| l.starts_with("Content-Length:"))
            .ok_or("missing content length")?;
        let len: usize = len_line["Content-Length:".len()..].trim().parse()?;
        let mut data = vec![0u8; len];
        self.reader.read_exact(&mut data)?;
        info!("client: DAP: <-: {}", String::from_utf8(data.clone())?);
        Ok(serde_json::from_slice(&data)?)
    }

    pub fn request_source(&mut self, path: &str) -> Result<String, Box<dyn Error>> {
        let seq = self.seq;
        self.seq += 1;
        let req = json!({
            "seq": seq,
            "type": "request",
            "command": "source",
            "arguments": {
                "source": {"path": path},
                "sourceReference": 0
            }
        });
        self.send_message(&req)?;
        let resp = self.read_message()?;
        if resp.get("type").and_then(|v| v.as_str()) == Some("response")
            && resp.get("command").and_then(|v| v.as_str()) == Some("source")
        {
            if let Some(content) = resp
                .get("body")
                .and_then(|b| b.get("content"))
                .and_then(|c| c.as_str())
            {
                return Ok(content.to_string());
            }
        }
        Err("unexpected response".into())
    }

    pub fn track(self, tx: mpsc::Sender<serde_json::Value>) {
        std::thread::spawn(move || {
            let mut client = self;
            loop {
                match client.read_message() {
                    Ok(msg) => {
                        if tx.blocking_send(msg).is_err() {
                            break;
                        }
                    }
                    Err(e) => {
                        error!("client: DAP: read error: {:?}", e);
                        break;
                    }
                }
            }
        });
    }
}
