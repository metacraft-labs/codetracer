use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::PathBuf;

use super::navigation::Location;

/// Launch request arguments matching db-backend's dap::LaunchRequestArguments.
#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct LaunchRequestArguments {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    #[serde(rename = "traceFolder", skip_serializing_if = "Option::is_none")]
    pub trace_folder: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_file: Option<PathBuf>,
    #[serde(rename = "rawDiffIndex", skip_serializing_if = "Option::is_none")]
    pub raw_diff_index: Option<String>,
    #[serde(rename = "ctRRWorkerExe", skip_serializing_if = "Option::is_none")]
    pub ct_rr_worker_exe: Option<PathBuf>,
    #[serde(rename = "restoreLocation", skip_serializing_if = "Option::is_none")]
    pub restore_location: Option<Location>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(rename = "noDebug", skip_serializing_if = "Option::is_none")]
    pub no_debug: Option<bool>,
    #[serde(rename = "__restart", skip_serializing_if = "Option::is_none")]
    pub restart: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request: Option<String>,
    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    pub typ: Option<String>,
    #[serde(rename = "__sessionId", skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}

impl Default for LaunchRequestArguments {
    fn default() -> Self {
        LaunchRequestArguments {
            program: None,
            trace_folder: None,
            trace_file: None,
            raw_diff_index: None,
            ct_rr_worker_exe: None,
            restore_location: None,
            pid: None,
            cwd: None,
            no_debug: None,
            restart: None,
            name: None,
            request: None,
            typ: None,
            session_id: None,
        }
    }
}

/// Capabilities returned by the initialize response.
#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
pub struct Capabilities {
    #[serde(rename = "supportsLoadedSourcesRequest", skip_serializing_if = "Option::is_none")]
    pub supports_loaded_sources_request: Option<bool>,
    #[serde(rename = "supportsStepBack", skip_serializing_if = "Option::is_none")]
    pub supports_step_back: Option<bool>,
    #[serde(rename = "supportsConfigurationDoneRequest", skip_serializing_if = "Option::is_none")]
    pub supports_configuration_done_request: Option<bool>,
    #[serde(rename = "supportsDisassembleRequest", skip_serializing_if = "Option::is_none")]
    pub supports_disassemble_request: Option<bool>,
    #[serde(rename = "supportsLogPoints", skip_serializing_if = "Option::is_none")]
    pub supports_log_points: Option<bool>,
    #[serde(rename = "supportsRestartRequest", skip_serializing_if = "Option::is_none")]
    pub supports_restart_request: Option<bool>,
}
