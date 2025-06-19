# ui-tests

This directory contains small Stylus programs for integration tests and examples.

## Stylus Vesting Demo

To build the vesting example, make sure the `wasm32-unknown-unknown` target is installed:

```bash
rustup target add wasm32-unknown-unknown
```

Then build the contract:

```bash
cargo build --target wasm32-unknown-unknown --manifest-path ui-tests/programs/stylus_vesting/Cargo.toml
```
