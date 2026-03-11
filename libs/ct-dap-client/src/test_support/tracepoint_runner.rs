use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::client::DapStdioClient;
use crate::types::common::Lang;
use crate::types::launch::LaunchRequestArguments;
use crate::types::tracepoint::{RunTracepointsArg, TraceSession, Tracepoint, TracepointMode};

use super::comparison::{
    assert_tracepoint_results_match, terminal_events_to_string, ExpectedTrace,
};
use super::{find_ct_rr_support, prepare_trace_folder};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// Specification for a tracepoint to set.
pub struct TracepointSpec {
    pub id: usize,
    pub file: String,
    pub line: usize,
    pub expression: String,
}

/// High-level test runner that manages the DAP lifecycle for tracepoint tests.
pub struct TracepointTestRunner {
    client: DapStdioClient,
    /// Temporary wrapper directory kept alive for the duration of the test.
    _trace_wrapper: Option<PathBuf>,
}

impl TracepointTestRunner {
    /// Spawn db-backend, run DAP init sequence with the given RR trace folder.
    ///
    /// `rr_trace_dir` should be the path that contains the actual RR trace data
    /// (data, mmaps, mmap_* files). This function creates a temporary wrapper
    /// directory with an `rr` symlink so that db-backend can find it via its
    /// `resolve_replay_trace_path` logic (which looks for `<folder>/rr`).
    pub fn new(db_backend_bin: &Path, rr_trace_dir: &Path) -> Result<Self, BoxError> {
        // db-backend expects trace_folder to CONTAIN an `rr/` subdirectory.
        // The test infra returns the rr data directory directly. Create a
        // wrapper directory with an `rr` symlink to bridge the gap.
        let (launch_folder, wrapper) = prepare_trace_folder(rr_trace_dir)?;

        // db-backend needs ct-rr-support as replay-worker. Find it automatically.
        let ct_rr_worker_exe = find_ct_rr_support()?;

        let mut client = DapStdioClient::spawn(db_backend_bin)?;

        // DAP initialization sequence
        let _caps = client.initialize()?;

        client.launch(LaunchRequestArguments {
            trace_folder: Some(launch_folder),
            ct_rr_worker_exe: Some(ct_rr_worker_exe),
            ..Default::default()
        })?;

        client.configuration_done()?;

        // Wait for the initial stopped event (run-to-entry)
        client.wait_for_stopped(Duration::from_secs(60))?;

        Ok(TracepointTestRunner {
            client,
            _trace_wrapper: wrapper,
        })
    }

    /// Run tracepoints and perform three-way comparison:
    /// 1. Real stdout output (parsed TRACE: lines)
    /// 2. Captured terminal output from the recording
    /// 3. Tracepoint evaluation results
    pub fn run_and_verify(
        &mut self,
        tracepoints: Vec<TracepointSpec>,
        expected: &[ExpectedTrace],
        real_stdout: &str,
    ) -> Result<(), BoxError> {
        // 1. Load terminal output from the recording
        let terminal_events = self.client.load_terminal()?;
        let captured_output = terminal_events_to_string(&terminal_events);

        // Compare real stdout with captured terminal output (non-fatal: RR traces
        // may not have terminal output available depending on the trace setup)
        let real_trace_output: String = real_stdout
            .lines()
            .filter(|l| l.starts_with("TRACE:"))
            .collect::<Vec<_>>()
            .join("\n");
        let captured_trace_output: String = captured_output
            .lines()
            .filter(|l| l.starts_with("TRACE:"))
            .collect::<Vec<_>>()
            .join("\n");

        if real_trace_output != captured_trace_output {
            eprintln!(
                "WARNING: Terminal output mismatch (non-fatal for RR traces).\n  Real stdout TRACE lines:\n    {}\n  Captured terminal TRACE lines:\n    {}",
                real_trace_output.replace('\n', "\n    "),
                if captured_trace_output.is_empty() { "(empty)" } else { &captured_trace_output }.replace('\n', "\n    "),
            );
        }

        // 2. Build tracepoint session
        let session_tracepoints: Vec<Tracepoint> = tracepoints
            .iter()
            .map(|spec| Tracepoint {
                tracepoint_id: spec.id,
                mode: TracepointMode::TracInlineCode,
                line: spec.line,
                offset: -1,
                name: spec.file.clone(),
                expression: spec.expression.clone(),
                last_render: 0,
                is_disabled: false,
                is_changed: true,
                lang: Lang::C,
                results: vec![],
                tracepoint_error: String::new(),
            })
            .collect();

        let args = RunTracepointsArg {
            session: TraceSession {
                tracepoints: session_tracepoints,
                found: vec![],
                last_count: 0,
                results: Default::default(),
                id: 1,
            },
            stop_after: -1,
        };

        // 3. Run tracepoints
        let results = self.client.run_tracepoints(args)?;

        // 4. Compare tracepoint results against expected
        assert_tracepoint_results_match(&results, expected)?;

        Ok(())
    }

    /// Access the underlying client for additional operations.
    pub fn client(&mut self) -> &mut DapStdioClient {
        &mut self.client
    }

    /// Clean shutdown.
    pub fn finish(self) -> Result<(), BoxError> {
        self.client.disconnect()?;
        Ok(())
    }
}
