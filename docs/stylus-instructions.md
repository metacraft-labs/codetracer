# Introduction

This document is intended as a usage guide for CodeTracer's new (rust) WASM/stylus tracing capabilities.

# 1. Download CodeTracer
Please refer to the main [README](https://github.com/metacraft-labs/codetracer).

# 2. Generate EVM trace

> If you want to trace a program compiled to WASM, that is not Stylus contract, you can skip this section

## 2.1. Install tools and dependencies
  * Install [Rustup](https://rustup.rs/)
  * Install [Foundry](https://getfoundry.sh/)
  * Install [Cargo Sylus CLI](https://github.com/OffchainLabs/cargo-stylus)

> [!TIP]
> You can run `nix develop 'github:metacraft-labs/nix-blockchain-development?ref=stylus-tools#stylus'` to start a devshell containing all the required tools.

## 2.2. Run Nitro Devnode
Official documentation: [https://docs.arbitrum.io/run-arbitrum-node/run-nitro-dev-node](https://docs.arbitrum.io/run-arbitrum-node/run-nitro-dev-node)

> [!TIP]
> If you are using the devshell from the previous step, you can start the devnode using `run-nitro-devnode`.

## 2.3. Build the contract
1. Go to the root directory of the stylus contract
```sh
cargo stylus new ct-stylus-test
cd ct-stylus-test
```
> [!TIP]
> The following instructions assume, that an unchanged version of the code, generated from the above command is used.

2. Add the target to the rust toolchain
```sh
rustup override set 1.81
rustup target add wasm32-unknown-unknown --toolchain 1.81
```

3. Build and verify that contract can be deployed
```sh
cargo stylus check
# Note: the provided values are default for the devnode
cargo stylus deploy \
  --endpoint='http://localhost:8547' \
  --private-key="0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659" \
  --estimate-gas
```

4. Generate WASM file with debuginfo
```sh
cargo build --target=wasm32-unknown-unknown
```

## 2.3 Deploy the contract to the devnode
```sh
cargo stylus deploy \
  --endpoint='http://localhost:8547' \
  --private-key="0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659"
```
The `deployed code at address` from the output will be used to call the contract (you can assign it to `$DEPLOYED_CONTRACT_ADDRESS`).

> [!WARNING]
Make sure that the WASM file with debug info and the deployed contract are built from the same source code

## 2.4 Send a transaction to the contract
```sh
cast send --rpc-url 'http://localhost:8547' --private-key 0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659 \
  $DEPLOYED_CONTRACT_ADDRESS "increment()"
```
The `transactionHash` from the output will be used to create EVM trace for the transaction (you can assign it to `$TRANSACTION_HASH`).

## 2.5 Create EVM trace
```sh
cargo stylus trace --endpoint='http://localhost:8547' --use-native-tracer \
  --tx $TRANSACTION_HASH > evm_trace.json
```

  
# 3. Run CodeTracer with WASM file and EVM trace
```sh
# Omit the --stylus-trace argument if you are tracing a non-stylus program.
ct record target/wasm32-unknown-unknown/debug/stylus_hello_world.wasm --stylus-trace=<full path to evm_trace.json>
ct replay stylus_hello_world.wasm
```
