## Stylus / WASM

We are adding MVP support for Stylus contracts written in Rust and using WASM.

The support is implemented in a general way, by patching the [wazero]() WASM interpreter, so
it can be used for various WASM languages/usecases, but the first iteration is a bit more tested with
the Stylus contract usecase or small example Rust-based WASM programs.

### Stylus demo

The Stylus tools allow you to deploy and interact with Arbitrum Stylus contracts locally.
Follow these steps to experiment with the demo contract shipped with CodeTracer.

1. **Run a local devnode**

   ```bash
   nix develop 'github:metacraft-labs/nix-blockchain-development?ref=stylus-tools#stylus'
   ```

   Inside the shell start the dev node:

   ```bash
   run-nitro-devnode
   ```

   > [!CAUTION]
   > The dev node runs in the foreground and hijacks the terminal.

2. **Deploy the demo contract**

   Open a new terminal, switch to the CodeTracer repository and check out the `feat/stylus-demo` branch:

   ```bash
   git checkout feat/stylus-demo
   cd ui-tests/programs/stylus_fund_tracker
   ct arb deploy
   ```

   Copy the printed smart contract address.

3. **Send transactions**

   In another terminal enter the Stylus development shell and set up the environment variables:

   ```bash
   nix develop 'github:metacraft-labs/nix-blockchain-development?ref=stylus-tools#stylus'

   export PK=0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659
   export RPC_URL=http://localhost:8547
   export CONTRACT_ADDR=<deployed contract address>
   ```

   Replace `<deployed contract address>` with the one printed in the previous step.

   Send a few funding transactions and trigger a `largeIncomes` event:

   ```bash
   cast send --rpc-url "$RPC_URL" --private-key "$PK" "$CONTRACT_ADDR" "fund(uint256)" 9  -vvvvv --priority-gas-price 0.01ether --gas-price 0.00000001ether --gas-limit 10000000
   cast send --rpc-url "$RPC_URL" --private-key "$PK" "$CONTRACT_ADDR" "fund(uint256)" 6  -vvvvv --priority-gas-price 0.01ether --gas-price 0.00000001ether --gas-limit 10000000
   cast send --rpc-url "$RPC_URL" --private-key "$PK" "$CONTRACT_ADDR" "fund(uint256)" 11 -vvvvv --priority-gas-price 0.01ether --gas-price 0.00000001ether --gas-limit 10000000
   cast send --rpc-url "$RPC_URL" --private-key "$PK" "$CONTRACT_ADDR" "largeIncomes(uint256)" 7 -vvvvv --priority-gas-price 0.01ether --gas-price 0.00000001ether --gas-limit 10000000
   ```

4. **Inspect the recorded transaction**

   Go back to the shell from step&nbsp;2 and run:

   ```bash
   ct arb explorer
   ```

   A window will open displaying the recent transactions. Select the last one to view it in CodeTracer.

### a simpler example only with Rust

```
# install rustup
# TODO: rustup add wasmi target 
# TODO: add rustc wasm command and an example rs file
ct record $TMPDIR/rust_example.wasm
ct replay rust_example.wasm
```
