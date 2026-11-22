//! ct-wasm-engine-probe — loads one module, instantiates it and calls one
//! export. Built once per engine feature, its stripped size is what that
//! engine adds to a host binary (PLAT-84 deliverable 1).
//!
//!   ct-wasm-engine-probe <module.wasm> <export>

use ct_plugin_engine::*;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let bytes = std::fs::read(&args[1]).expect("module");
    #[cfg(feature = "wasmtime")]
    let (kind, mode) = (EngineKind::Wasmtime, DeadlineMode::Epoch);
    #[cfg(all(feature = "wasmi", not(feature = "wasmtime")))]
    let (kind, mode) = (EngineKind::Wasmi, DeadlineMode::Fuel);
    let e = Engine::new(kind, mode, &EngineOptions::default()).expect("engine");
    let m = e.module(&bytes).expect("compile");
    let mut i = e
        .instantiate(&m, Limits { memory_bytes: 16 << 20 }, Box::new(|_, _, _, _| Ok(())))
        .expect("instantiate");
    let r = i.call(&args[2], &[], 1_000);
    println!("{:?} {:?}", r.status, r.results);
}
