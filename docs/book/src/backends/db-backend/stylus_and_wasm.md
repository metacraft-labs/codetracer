## Stylus / WASM

We are adding MVP support for Stylus contracts written in Rust and using WASM.

The support is implemented in a general way, by patching the [wazero]() WASM interpreter, so
it can be used for various WASM languages/usecases, but the first iteration is a bit more tested with
the Stylus contract usecase or small example Rust-based WASM programs.

### instructions for trying and example with Stylus 

TODO

### a simpler example only with Rust

```
# install rustup
# TODO: rustup add wasmi target 
# TODO: add rustc wasm command and an example rs file
ct record $TMPDIR/rust_example.wasm
ct replay rust_example.wasm
```
