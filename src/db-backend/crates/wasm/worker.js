importScripts('./pkg/db-backend.js');

(async () => {
  // Initialize wasm (path to the .wasm produced by wasm-bindgen)
  await wasm_bindgen('./pkg/db-backend_bg.wasm');
  // Hand control to Rust, which sets up onmessage and postMessage
  wasm_bindgen.run_worker();
})();
