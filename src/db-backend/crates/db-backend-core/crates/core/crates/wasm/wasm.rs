use serde::{Deserialize, Serialize};
use serde_wasm_bindgen as swb;
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use web_sys::{DedicatedWorkerGlobalScope, MessageEvent};

#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Request {
    Ping,
    Add { a: i32, b: i32 },
    Fib { n: u32 },
}

#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    Pong,
    Sum { value: i32 },
    Fib { value: u64 },
    Error { message: String },
}

#[wasm_bindgen]
pub fn run_worker() {
    // We are running inside the worker thread.
    let global = js_sys::global();
    let scope: DedicatedWorkerGlobalScope = global.unchecked_into();

    let onmessage = Closure::wrap(Box::new(move |evt: MessageEvent| {
        let req: Result<Request, _> = swb::from_value(evt.data());
        let resp = match req {
            Ok(Request::Ping) => Response::Pong,
            Ok(Request::Add { a, b }) => Response::Sum { value: a + b },
            Ok(Request::Fib { n }) => Response::Fib { value: fib(n) },
            Err(e) => Response::Error {
                message: format!("bad request: {e}"),
            },
        };

        // Send back to UI
        let js = swb::to_value(&resp).expect("serialize response");
        let _ = scope.post_message(&js);
    }) as Box<dyn FnMut(MessageEvent)>);

    // Install the handler; keep the closure alive.
    scope.set_onmessage(Some(onmessage.as_ref().unchecked_ref()));

    // Memory leaks
    onmessage.forget();
}

fn fib(n: u32) -> u64 {
    // Simple (naive) example; replace with your own logic
    fn f(x: u32) -> u64 {
        match x {
            0 => 0,
            1 => 1,
            _ => f(x - 1) + f(x - 2),
        }
    }
    f(n)
}
