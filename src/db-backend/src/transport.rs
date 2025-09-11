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
    use super::*;
    use std::io::Write;

    // Blanket impl: any `Write` is a DapTransport
    impl<T: Write> DapTransport for T {
        fn send(&mut self, msg: &DapMessage) -> Result<(), DapError> {
            let bytes = serialize_to_bytes(msg)?;
            self.write_all(&bytes).map_err(|e| DapError::Io(e.to_string()))
        }
    }
}

//
// Implementation 2: Browser Worker (enabled with `--features browser-transport`)
//
#[cfg(feature = "browser-transport")]
mod browser_transport {
    use super::*;
    use wasm_bindgen::JsCast;
    use wasm_bindgen::JsValue;
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
                .map_err(|_| DapError::Js("Not running inside DedicatedWorkerGlobalScope".into()))?;
            Ok(Self { scope })
        }
    }

    impl DapTransport for BrowserTransport {
        fn send(&mut self, msg: &DapMessage) -> Result<(), DapError> {
            // Decide how you want to pass across the worker boundary:
            // 1) Send bytes (e.g., Uint8Array)
            let bytes = serialize_to_bytes(msg)?;
            let array = js_sys::Uint8Array::from(bytes.as_slice());
            self.scope
                .post_message(&JsValue::from(array))
                .map_err(|e| DapError::Js(format!("{e:?}")))?;

            // 2) OR send as string (simpler, but pick one path)
            // self.scope
            //     .post_message(&JsValue::from_str(&msg.payload))
            //     .map_err(|e| DapError::Js(format!("{e:?}")))?;

            Ok(())
        }
    }

    // Re-export for callers
    pub use BrowserTransport as WorkerTransport;
}

#[cfg(feature = "browser-transport")]
pub use browser_transport::WorkerTransport;
