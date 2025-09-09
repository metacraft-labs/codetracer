importScripts('./pkg/db_backend.js');

const {FibonacciEval} = wasm_bindgen;

async function init_wasm_in_worker() {

    // Load the Wasm file by awaiting the Promise returned by `wasm_bindgen`.
    await wasm_bindgen('./pkg/db_backend_bg.wasm');

    wasm_start();

};

init_wasm_in_worker();
