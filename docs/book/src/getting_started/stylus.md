## Getting Started with Stylus

This guide will walk you through tracing an Arbitrum Stylus smart contract with CodeTracer. The process involves deploying a contract and then sending transactions to it, which CodeTracer will automatically record.

The implementation is based on a `wazero` WASM interpreter and has been tested with Stylus contracts. You can find more information on `wazero` [here](https://wazero.io/).

### Prerequisites

*   **Rust `wasm32` Target:** You must have the `wasm32-unknown-unknown` target installed for Rust. You can add it by running:
    ```bash
    rustup target add wasm32-unknown-unknown
    ```
*   **Three Terminal Windows:** You will need three separate terminals to run all the necessary components.

### Environment Setup

To follow this guide, you need a local Arbitrum development node and Foundry's `cast` tool. We provide instructions for two setups: a Nix-based environment (recommended for Linux) and a manual setup for macOS.

<details>
<summary><b>Option 1: Nix-based Setup (Recommended for Linux)</b></summary>

This is the easiest way to get started if you have Nix installed.

In your **first terminal**, launch the Stylus development environment. This command will download all the necessary tools.

```bash
nix develop 'github:metacraft-labs/nix-blockchain-development?ref=stylus-tools#stylus'
```

Once inside the new shell, start the local Arbitrum node:

```bash
run-nitro-devnode
```

You should see it producing blocks. Keep this terminal running.

For sending transactions in Step 2, you will also use this Nix shell in your **third terminal** to get access to the `cast` command-line tool.

</details>

<details>
<summary><b>Option 2: Manual Setup (macOS)</b></summary>

If you are on macOS or do not use Nix, follow these steps.

**1. Install Foundry**

Install `foundryup` by following the instructions at https://getfoundry.sh. This will provide the `cast` command-line tool.

**2. Install Stylus**

Run the following command to install the Stylus CLI:
```bash
cargo install cargo-stylus
```
> [!IMPORTANT]
> Make sure `cargo` is from a `rustup` installation, not from Homebrew. If you installed Rust via Homebrew, this step might fail.

**3. Run the Local Devnode**

In your **first terminal**, clone and run the `nitro-devnode`:
```bash
git clone https://github.com/OffchainLabs/nitro-devnode.git
cd nitro-devnode
./run-dev-node.sh
```
You should see it producing blocks. Keep this terminal running.

</details>

### Step 1: Deploy the Demo Contract

This step is the same for both setups.

In your **second terminal**, navigate to the directory of the example program and use CodeTracer to deploy the smart contract. The `ct arb deploy` command handles this for you.

```bash
# Navigate to the example contract
cd ui-tests/programs/stylus_fund_tracker

# Deploy it to the local devnode
ct arb deploy
```

After a moment, CodeTracer will print the deployed smart contract address. **Copy this address**, as you will need it in the next step.

### Step 2: Send Transactions

In your **third terminal**, you will use the `cast` tool to send transactions.

-   **Nix users:** Enter the Stylus development shell first:
    ```bash
    nix develop 'github:metacraft-labs/nix-blockchain-development?ref=stylus-tools#stylus'
    ```
-   **macOS users:** The `cast` command should be available in your PATH if you installed Foundry correctly.

Next, set up some environment variables to make the commands easier to read. **Paste the contract address you copied from the previous step.**

```bash
# The private key for the pre-funded devnet account
export PK=0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659

# The RPC URL for the local devnode
export RPC_URL=http://localhost:8547

# The address of your deployed contract
export CONTRACT_ADDR="<paste-your-contract-address-here>"
```

Now you can use `cast send` to call functions on your contract. These transactions will be automatically recorded by CodeTracer.

Let's send a few funding transactions and then trigger a custom event:

```bash
# Fund with 9
cast send --rpc-url "$RPC_URL" --private-key "$PK" "$CONTRACT_ADDR" "fund(uint256)" 9

# Fund with 6
cast send --rpc-url "$RPC_URL" --private-key "$PK" "$CONTRACT_ADDR" "fund(uint256)" 6

# Fund with 11
cast send --rpc-url "$RPC_URL" --private-key "$PK" "$CONTRACT_ADDR" "fund(uint256)" 11

# Trigger the largeIncomes function
cast send --rpc-url "$RPC_URL" --private-key "$PK" "$CONTRACT_ADDR" "largeIncomes(uint256)" 7
```

### Step 3: Explore the Recorded Traces

Go back to your **second terminal** (where you ran `ct arb deploy`). Now, run the CodeTracer explorer:

```bash
ct arb explorer
```

A window will open displaying the recent transactions. Select any transaction to view its full execution trace in CodeTracer.