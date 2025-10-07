use crate::{dap::DapMessage, dap_error::DapError};

/// Unified abstraction used by your code regardless of target.
pub trait DapTransport {
    fn send(&mut self, message: &DapMessage) -> Result<(), DapError>;
}

//
// Implementation 1: I/O (enabled with `--features io-transport` or by default)
//
#[cfg(feature = "io-transport")]
mod io_transport {
    use serde::de::Error;

    use crate::dap::to_json;

    use super::*;
    use std::io::Write;

    // Blanket impl: any `Write` is a DapTransport
    impl<T: Write> DapTransport for T {
        fn send(&mut self, msg: &DapMessage) -> Result<(), DapError> {
            let json = to_json(msg)?;
            let header = format!("Content-Length: {}\r\n\r\n", json.len());
            self.write_all(header.as_bytes())
                .map_err(|e| serde_json::Error::custom(e.to_string()))?;
            self.write_all(json.as_bytes())
                .map_err(|e| serde_json::Error::custom(e.to_string()))?;
            self.flush().map_err(|e| serde_json::Error::custom(e.to_string()))?;
            log::info!("DAP -> {:?}", msg);
            Ok(())
        }
    }
}

//
// Implementation 2: Browser Worker (enabled with `--features browser-transport`)
//
#[cfg(feature = "browser-transport")]
mod browser_transport {

    use super::*;
    use serde_wasm_bindgen::to_value;
    use wasm_bindgen::JsCast;
    use web_sys::js_sys;
    use web_sys::DedicatedWorkerGlobalScope;

    /// A transport that posts messages to the worker's main thread.
    pub struct BrowserTransport {
        scope: DedicatedWorkerGlobalScope,
    }

    impl BrowserTransport {
        /// Create from `globalThis` assuming we are inside a DedicatedWorkerGlobalScope.
        pub fn new() -> Result<Self, DapError> {
            let global = js_sys::global();
            let scope: DedicatedWorkerGlobalScope = global
                .dyn_into()
                .map_err(|_| wasm_bindgen::JsValue::from_str("Not running inside a DedicatedWorkerGlobalScope"))?;
            Ok(Self { scope })
        }
    }

    impl DapTransport for BrowserTransport {
        fn send(&mut self, msg: &DapMessage) -> Result<(), DapError> {
            // 2) OR send as string (simpler, but pick one path)

            let js_val = to_value(msg).map_err(|e| wasm_bindgen::JsValue::from_str(&e.to_string()))?;
            self.scope
                .post_message(&js_val)
                .map_err(|_| wasm_bindgen::JsValue::from_str("Could not send message from worker"))?;

            Ok(())
        }
    }

    // Re-export for callers
    pub use BrowserTransport as WorkerTransport;
}

#[cfg(feature = "browser-transport")]
pub use browser_transport::WorkerTransport;
