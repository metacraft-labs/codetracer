importScripts('./pkg/db_backend.js');

const {FibonacciEval} = wasm_bindgen;

async function init_wasm_in_worker() {

    // Load the Wasm file by awaiting the Promise returned by `wasm_bindgen`.
    await wasm_bindgen('./pkg/db_backend_bg.wasm');

    // Call the Rust export via the namespace
    await wasm_bindgen.wasm_start();
};

init_wasm_in_worker();
