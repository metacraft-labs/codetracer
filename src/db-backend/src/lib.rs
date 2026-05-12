#![allow(clippy::uninlined_format_args)]
#![allow(clippy::expect_used)]
#![allow(dead_code)]
// use std::ffi::{c_char, CStr, CString};
// use std::slice;

// use codetracer_trace_types::EventLogKind;

#[cfg(feature = "browser-transport")]
use wasm_bindgen::prelude::wasm_bindgen;

#[cfg(feature = "browser-transport")]
use wasm_bindgen::JsValue;

#[cfg(feature = "browser-transport")]
use crate::dap::setup_onmessage_callback;

#[cfg(feature = "browser-transport")]
pub mod c_compat;

#[cfg(feature = "browser-transport")]
pub mod vfs;

pub mod calltrace;

#[cfg(feature = "io-transport")]
pub mod core;

pub mod ctfs_trace_reader;
pub mod dap;
pub mod dap_error;
pub mod dap_handler;
pub mod dap_server;
pub mod dap_types;
pub mod db;
pub mod diff;
pub mod distinct_vec;
#[cfg(not(target_arch = "wasm32"))]
pub mod emulator_ffi;
pub mod event_db;
pub mod expr_loader;
pub mod flow_preloader;
pub mod in_memory_trace_reader;
pub mod lang;
pub mod macro_sourcemap;
pub mod nim_mangling;
pub mod paths;
pub mod program_search_tool;
pub mod query;
pub mod recreator_session;
pub mod replay;
pub mod step_lines_loader;
pub mod task;
pub mod trace_processor;
pub mod trace_reader;
pub mod tracepoint_interpreter;
pub mod transport;
pub mod transport_endpoint;
pub mod value;

#[cfg(feature = "browser-transport")]
#[wasm_bindgen(start)]
pub fn _start() {
    console_error_panic_hook::set_once();

    wasm_logger::init(wasm_logger::Config::default());
}

/// Write a file into the in-memory VFS so that trace data is accessible to the
/// DAP server before any requests arrive.  Called from JavaScript after the WASM
/// module is initialised but before `wasm_start`.
///
/// `path` is a virtual path. For CTFS-only loading, this is typically the
/// path to a single `.ct` container (e.g. `"recording.ct"`) — there are no
/// loose sidecar files (`trace_metadata.json`, `trace.bin`, etc.) anymore.
/// `data` is the raw file content as a byte slice.
#[cfg(feature = "browser-transport")]
#[wasm_bindgen]
pub fn vfs_write_file(path: &str, data: &[u8]) -> Result<(), JsValue> {
    vfs::vfs_write(path, data.to_vec());
    Ok(())
}

/// Returns `true` when a file exists at `path` inside the in-memory VFS.
/// Useful for JavaScript to verify that trace data was loaded successfully.
#[cfg(feature = "browser-transport")]
#[wasm_bindgen]
pub fn vfs_file_exists(path: &str) -> bool {
    vfs::vfs_exists(path)
}

/// Attempt to load a trace from the in-memory VFS.
///
/// JavaScript should first push all trace files into the VFS via
/// [`vfs_write_file`], then call this function to verify that the data can
/// be parsed.  Returns `true` when the trace is successfully loaded as a
/// CTFS container, `false` otherwise.
///
/// `trace_folder` is the virtual path of the `.ct` container (or a prefix
/// containing one).  Legacy sidecar layouts (`trace_metadata.json` +
/// `trace.bin`/`trace.json`) are no longer supported — only CTFS.
#[cfg(feature = "browser-transport")]
#[wasm_bindgen]
pub fn load_trace_from_vfs(trace_folder: &str) -> bool {
    use log::{error, info};

    info!("load_trace_from_vfs: folder={trace_folder:?}");

    // The CTFS-only loader expects either the .ct container path itself or
    // a folder prefix containing one. setup_from_vfs handles both cases by
    // probing for the CTFS magic.
    let (sender, _receiver) = std::sync::mpsc::channel();
    match dap_server::setup_from_vfs(
        trace_folder,
        trace_folder,
        None, // raw_diff_index
        None, // restore_location
        sender,
        false, // for_launch — skip run_to_entry for validation
        "vfs-validation",
    ) {
        Ok(_handler) => {
            info!("load_trace_from_vfs: successfully loaded trace from VFS");
            true
        }
        Err(e) => {
            error!("load_trace_from_vfs: failed to load trace: {e}");
            false
        }
    }
}

#[cfg(feature = "browser-transport")]
#[wasm_bindgen]
pub fn wasm_start() -> Result<(), JsValue> {
    // Spawn the worker that runs the DAP server logic.

    use wasm_bindgen::{JsCast, JsValue};
    use web_sys::js_sys;
    web_sys::console::log_1(&"wasm worker started".into());

    setup_onmessage_callback().map_err(|e| JsValue::from_str(&format!("{e}")))?;

    let global = js_sys::global();

    let scope: web_sys::DedicatedWorkerGlobalScope = global
        .dyn_into()
        .map_err(|_| wasm_bindgen::JsValue::from_str("Not running inside a DedicatedWorkerGlobalScope"))?;

    scope.post_message(&JsValue::from_str("ready")).unwrap();

    Ok(())
}
