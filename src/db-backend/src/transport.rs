use crate::{dap::DapMessage, dap_error::DapError};

pub type DapResult<T> = std::result::Result<T, DapError>;

/// Unified abstraction used by your code regardless of target.
pub trait DapTransport {
    fn send(&mut self, message: &DapMessage) -> DapResult<()>;
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
        fn send(&mut self, msg: &DapMessage) -> DapResult<()> {
            let json = to_json(msg)?;
            let header = format!("Content-Length: {}\r\n\r\n", json.len());
            self.write_all(header.as_bytes())
                .map_err(|e| serde_json::Error::custom(e.to_string()))?;
            self.write_all(json.as_bytes())
                .map_err(|e| serde_json::Error::custom(e.to_string()))?;
            self.flush().map_err(|e| serde_json::Error::custom(e.to_string()))?;
            log::info!("DAP -> {}", sent_message_summary(msg, &json));
            Ok(())
        }
    }

    /// How much of a sent message's JSON the log line carries.
    const LOGGED_JSON_PREFIX_BYTES: usize = 512;

    /// A bounded description of a message just sent: what it is, its size,
    /// and the start of its JSON.
    ///
    /// The log line used to be the message's full `Debug` form. Every message
    /// goes through the one sending thread, so formatting a large one — a
    /// `ct/updated-flow` and the `ct/load-flow` response for a loop-heavy
    /// function hold every step the flow walked — delayed every message queued
    /// behind it, the next move's `ct/complete-move` included: ~0.7 s per move
    /// on the program of codetracer-pm
    /// `issues/2026-10-06-a-stop-inside-a-loop-heavy-python-function-takes-thirty-seconds.md`.
    /// The replay server logs `info!` unconditionally, so the cost has to be
    /// bounded here rather than filtered.
    fn sent_message_summary(msg: &DapMessage, json: &str) -> String {
        let what = match msg {
            DapMessage::Request(request) => format!("request {} seq {}", request.command, request.base.seq),
            DapMessage::Response(response) => format!(
                "response {} to {} success {}",
                response.command, response.request_seq, response.success
            ),
            DapMessage::Event(event) => format!("event {} seq {}", event.event, event.base.seq),
        };
        let mut prefix_end = json.len().min(LOGGED_JSON_PREFIX_BYTES);
        while !json.is_char_boundary(prefix_end) {
            prefix_end -= 1;
        }
        let ellipsis = if prefix_end < json.len() { "…" } else { "" };
        format!("{what} ({} bytes): {}{ellipsis}", json.len(), &json[..prefix_end])
    }

    #[cfg(test)]
    #[allow(clippy::expect_used)]
    mod tests {
        use super::sent_message_summary;
        use crate::dap::{DapMessage, Event, ProtocolMessage};

        fn event(body: serde_json::Value) -> DapMessage {
            DapMessage::Event(Event {
                base: ProtocolMessage {
                    seq: 7,
                    type_: "event".to_string(),
                },
                event: "ct/updated-flow".to_string(),
                body,
            })
        }

        #[test]
        fn a_large_message_is_logged_as_a_bounded_line() {
            let msg = event(serde_json::json!({ "steps": "é".repeat(100_000) }));
            let json = crate::dap::to_json(&msg).expect("the event serializes");
            let line = sent_message_summary(&msg, &json);
            assert!(line.starts_with(&format!("event ct/updated-flow seq 7 ({} bytes): ", json.len())));
            assert!(line.ends_with('…'));
            assert!(
                line.len() < 1024,
                "the line must not grow with the message: {} bytes",
                line.len()
            );
        }

        #[test]
        fn a_small_message_is_logged_whole() {
            let msg = event(serde_json::json!({}));
            let json = crate::dap::to_json(&msg).expect("the event serializes");
            assert_eq!(
                sent_message_summary(&msg, &json),
                format!("event ct/updated-flow seq 7 ({} bytes): {json}", json.len())
            );
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
    use web_sys::DedicatedWorkerGlobalScope;
    use web_sys::js_sys;

    /// A transport that posts messages to the worker's main thread.
    pub struct BrowserTransport {
        scope: DedicatedWorkerGlobalScope,
    }

    impl BrowserTransport {
        /// Create from `globalThis` assuming we are inside a DedicatedWorkerGlobalScope.
        pub fn new() -> DapResult<Self> {
            let global = js_sys::global();
            let scope: DedicatedWorkerGlobalScope = global
                .dyn_into()
                .map_err(|_| wasm_bindgen::JsValue::from_str("Not running inside a DedicatedWorkerGlobalScope"))?;
            Ok(Self { scope })
        }
    }

    impl DapTransport for BrowserTransport {
        fn send(&mut self, msg: &DapMessage) -> DapResult<()> {
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
