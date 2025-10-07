#![allow(dead_code)]
// use std::ffi::{c_char, CStr, CString};
// use std::slice;

// use runtime_tracing::EventLogKind;

#[cfg(feature = "browser-transport")]
use wasm_bindgen::prelude::wasm_bindgen;

#[cfg(feature = "browser-transport")]
use wasm_bindgen::JsValue;

#[cfg(feature = "browser-transport")]
use crate::dap::setup_onmessage_callback;

#[cfg(feature = "browser-transport")]
pub mod c_compat;

pub mod calltrace;

#[cfg(feature = "io-transport")]
pub mod core;

pub mod dap;
pub mod dap_error;
pub mod dap_server;
pub mod dap_types;
pub mod db;
pub mod distinct_vec;
pub mod event_db;
pub mod expr_loader;
pub mod flow_preloader;
pub mod handler;
pub mod lang;
pub mod paths;
pub mod program_search_tool;
pub mod step_lines_loader;
pub mod task;
pub mod trace_processor;
pub mod tracepoint_interpreter;
pub mod transport;
pub mod value;

#[cfg(feature = "browser-transport")]
#[wasm_bindgen(start)]
pub fn _start() {
    console_error_panic_hook::set_once();

    wasm_logger::init(wasm_logger::Config::default());
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
