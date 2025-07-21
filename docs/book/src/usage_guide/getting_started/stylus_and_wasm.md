## Stylus / WASM

The implementation is based on a [wazero]() WASM interpreter patch and can be used for various WASM languages.
Testing has been done using Sylus contracts and small rust-based WASM programs.

### Steps to record / replay a Stylus program

Adjust the steps below for your use case or run the exact steps to launch the demo program which is included with the repo.

1. **Run a local devnode**

   ```bash
   nix develop 'github:metacraft-labs/nix-blockchain-development?ref=stylus-tools#stylus'
   ```

   Inside the shell start the dev node:

   ```bash
   run-nitro-devnode
   ```

2. **Deploy the demo contract**

   Open a new terminal, navigate to the directory of your program and let CodeTracer deploy the smart contract.

   ```bash
   cd ui-tests/programs/stylus_fund_tracker
   ct arb deploy
   ```
   After this step, CodeTracer will return the deployed smart contract address.

3. **Send transactions**

   After CodeTracer has deployed the smart contract each transaction to it will be recorded.

   To make the cast commands more readable we first export some of the arguments.
   In another terminal enter the Stylus development shell and set up the environment variables:

   ```bash
   nix develop 'github:metacraft-labs/nix-blockchain-development?ref=stylus-tools#stylus'

   export PK=0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659
   export RPC_URL=http://localhost:8547
   export CONTRACT_ADDR=<deployed smart contract address>
   ```

   Make sure to replace `<deployed smart contract address>` with the address from the previous step 

   

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