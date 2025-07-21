## WASM

The implementation is based on a [wazero]() WASM interpreter patch and can be used for various WASM languages.
Testing has been done using Sylus contracts and small rust-based WASM programs.

### Steps to record / replay a WASM program

Adjust the steps below for your use case or run the exact steps to launch the demo program which is included with the repo.

1. **Make sure you have a rust WASM toolchain** For example you can use the wasm32-wasip1 target, which we will use for the remainder of the guide

   1. Navigate to your WASM project directory.

   Example: ```cd codeTracer/examples/wasm_sample_atomic```
   
   2. Compile the rust source code to WASM

   Example: ```rustc --target=wasm32-wasip1 ./sample_atomic.rs -g```

   3. Use ```ct record <path to .wasm file> [<args>]``` and ```ct replay <name of .wasm file>``` (or directly ```ct run <path to .wasm file> [<args>]```)

   Example: ```ct run sample_atomic.wasm ```