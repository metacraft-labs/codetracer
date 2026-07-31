---
title: Recorder CLI Reference
order: 104
---
## Recorder CLI Reference

Each supported blockchain language has its own recorder binary that produces trace files in CodeTracer's format. This page provides a comprehensive reference for all recorder CLIs.

All recorders share common conventions:

- Output directory: `-o, --out-dir <DIR>` (default: `./ct-traces/`)
- Output format: `-f, --format <FMT>` (`binary` or `json`, default: `binary`)
- Version: `version` subcommand
- Output files: `trace.bin` (or `trace.json`), `trace_metadata.json`, `trace_paths.json`

After recording, open the trace with `ct replay --trace-folder <DIR>`.

---

### codetracer-evm-recorder

Traces Solidity smart contracts on the EVM.

```
codetracer-evm-recorder record <solidity-file> [options]
```

| Flag                | Description                       |
| ------------------- | --------------------------------- |
| `<solidity-file>`   | Path to the `.sol` source file    |
| `--trace-dir <DIR>` | Output directory for trace files  |
| `--function <NAME>` | Function to call (default: `run`) |

---

### codetracer-circom-recorder

Traces Circom zero-knowledge circuits during witness generation.

```
codetracer-circom-recorder record <circom-file> [options]
codetracer-circom-recorder version
```

| Flag                  | Description                                          |
| --------------------- | ---------------------------------------------------- |
| `<circom-file>`       | Path to the `.circom` source file                    |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`)           |
| `-f, --format <FMT>`  | `binary` or `json` (default: `binary`)               |
| `-b, --backend <BE>`  | Witness generator: `wasm` or `cpp` (default: `wasm`) |

---

### codetracer-cairo-recorder

Traces Cairo programs and StarkNet contracts.

```
codetracer-cairo-recorder record <cairo-file> [options]
codetracer-cairo-recorder trace-starknet <trace-file> [options]
codetracer-cairo-recorder replay [options]
codetracer-cairo-recorder version
```

**record** — Record a standalone Cairo program.

| Flag                  | Description                                |
| --------------------- | ------------------------------------------ |
| `<cairo-file>`        | Path to the `.cairo` source file           |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`) |
| `-f, --format <FMT>`  | `binary` or `json` (default: `binary`)     |

**trace-starknet** — Convert an snforge trace JSON.

| Flag                  | Description                                |
| --------------------- | ------------------------------------------ |
| `<trace-file>`        | Path to snforge trace JSON                 |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`) |
| `-f, --format <FMT>`  | `binary` or `json` (default: `binary`)     |

**replay** — Replay an on-chain StarkNet transaction.

| Flag                  | Description                           |
| --------------------- | ------------------------------------- |
| `--tx-hash <HASH>`    | Transaction hash (e.g., `0x04a3c...`) |
| `--rpc-url <URL>`     | StarkNet JSON-RPC endpoint            |
| `--source-dir <PATH>` | Directory with contract source code   |

---

### codetracer-cardano-recorder

Traces Aiken smart contracts on Cardano (UPLC CEK machine).

```
codetracer-cardano-recorder record <aiken-file> [options]
codetracer-cardano-recorder replay [options]
codetracer-cardano-recorder version
```

**record** — Record an Aiken source file.

| Flag                  | Description                                |
| --------------------- | ------------------------------------------ |
| `<aiken-file>`        | Path to the `.ak` source file              |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`) |
| `-f, --format <FMT>`  | `binary` or `json` (default: `binary`)     |

**replay** — Replay an on-chain Cardano transaction.

| Flag                     | Description                                          |
| ------------------------ | ---------------------------------------------------- |
| `--tx-hash <HASH>`       | Transaction hash (64 hex characters)                 |
| `--blockfrost-key <KEY>` | Blockfrost API key (or `BLOCKFROST_API_KEY` env var) |
| `-o, --out-dir <DIR>`    | Output directory (default: `./ct-traces/`)           |
| `-f, --format <FMT>`     | `binary` or `json` (default: `binary`)               |

---

### codetracer-flow-recorder

Traces Cadence smart contracts on the Flow blockchain.

```
codetracer-flow-recorder record <cdc-file> [options]
codetracer-flow-recorder replay [options]
codetracer-flow-recorder version
```

**record** — Record a Cadence source file.

| Flag                  | Description                                |
| --------------------- | ------------------------------------------ |
| `<cdc-file>`          | Path to the `.cdc` source file             |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`) |
| `-f, --format <FMT>`  | `binary` or `json` (default: `binary`)     |

**replay** — Replay an on-chain Flow transaction.

| Flag                  | Description                                |
| --------------------- | ------------------------------------------ |
| `--tx-hash <HASH>`    | Flow transaction hash                      |
| `--access-node <URL>` | Flow Access Node gRPC endpoint             |
| `--source-dir <PATH>` | Directory with Cadence source files        |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`) |
| `-f, --format <FMT>`  | `binary` or `json` (default: `binary`)     |

---

### codetracer-solana-recorder

Traces Solana programs (SBF virtual machine).

```
codetracer-solana-recorder record <elf-file> [options]
codetracer-solana-recorder replay [options]
codetracer-solana-recorder version
```

**record** — Record from a compiled Solana program.

| Flag                  | Description                                   |
| --------------------- | --------------------------------------------- |
| `<elf-file>`          | Path to the compiled `.so` ELF file           |
| `--regs <FILE>`       | Pre-generated register trace (`.regs` binary) |
| `--elf <PATH>`        | Unstripped ELF for DWARF source mapping       |
| `--idl <FILE>`        | Anchor IDL JSON for account data decoding     |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`)    |
| `-f, --format <FMT>`  | `binary` or `json` (default: `binary`)        |

**replay** — Replay a Solana transaction.

| Flag                   | Description                                                     |
| ---------------------- | --------------------------------------------------------------- |
| `--signature <SIG>`    | Transaction signature (base-58)                                 |
| `--rpc-url <URL>`      | Solana JSON-RPC endpoint (default: `http://localhost:8899`)     |
| `--program-dir <PATH>` | Directory with compiled `.so` files (default: `target/deploy/`) |
| `-o, --out-dir <DIR>`  | Output directory (default: `./ct-traces/`)                      |
| `-f, --format <FMT>`   | `binary` or `json` (default: `binary`)                          |

---

### codetracer-move-recorder

Traces Move smart contracts on Sui and Aptos.

```
codetracer-move-recorder record <trace-file> [options]
codetracer-move-recorder replay [options]
codetracer-move-recorder aptosreplay [options]
codetracer-move-recorder version
```

**record** — Convert a Move trace file to CodeTracer format.

| Flag                  | Description                                |
| --------------------- | ------------------------------------------ |
| `<trace-file>`        | Trace file (`.json` or `.json.zst`)        |
| `-s, --source <FILE>` | Move source file                           |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`) |
| `-f, --format <FMT>`  | `binary` or `json` (default: `binary`)     |

**replay** — Replay a Sui transaction.

| Flag                  | Description                                         |
| --------------------- | --------------------------------------------------- |
| `--digest <DIGEST>`   | Sui transaction digest                              |
| `--rpc-url <URL>`     | Sui RPC endpoint (default: `http://localhost:9000`) |
| `--source-dir <PATH>` | Directory with Move source files                    |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`)          |

**aptosreplay** — Replay an Aptos transaction.

| Flag                  | Description                                                           |
| --------------------- | --------------------------------------------------------------------- |
| `--txn-version <N>`   | Transaction version (ledger version)                                  |
| `--node-url <URL>`    | Aptos REST API (default: `https://fullnode.mainnet.aptoslabs.com/v1`) |
| `--source-dir <PATH>` | Directory with Move source files                                      |
| `--profile-gas`       | Run gas profiling (default: `true`)                                   |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`)                            |

---

### codetracer-fuel-recorder

Traces Sway smart contracts on FuelVM.

```
codetracer-fuel-recorder record [project-dir] [options]
codetracer-fuel-recorder replay [options]
codetracer-fuel-recorder version
```

**record** — Record a Sway project.

| Flag                  | Description                                     |
| --------------------- | ----------------------------------------------- |
| `[project-dir]`       | Path to Sway project (must contain `Forc.toml`) |
| `--bytecode <FILE>`   | Raw FuelVM bytecode file                        |
| `--abi <FILE>`        | Sway ABI JSON for variable enrichment           |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`)      |
| `-f, --format <FMT>`  | `binary` or `json` (default: `binary`)          |

**replay** — Replay an on-chain Fuel transaction.

| Flag                  | Description                                                              |
| --------------------- | ------------------------------------------------------------------------ |
| `--tx-id <ID>`        | Transaction ID (hex with `0x` prefix)                                    |
| `--rpc-url <URL>`     | fuel-core GraphQL endpoint (default: `http://localhost:4000/v1/graphql`) |
| `--source-dir <PATH>` | Directory with forc build output                                         |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`)                               |

---

### codetracer-miden-recorder

Traces Miden VM programs and contracts.

```
codetracer-miden-recorder record <program> [options]
codetracer-miden-recorder contract [options]
codetracer-miden-recorder replay [options]
codetracer-miden-recorder version
```

**record** — Record a MASM program.

| Flag                  | Description                                        |
| --------------------- | -------------------------------------------------- |
| `<program>`           | Path to MASM source (`.masm`) or package (`.masp`) |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`)         |
| `-f, --format <FMT>`  | `binary` or `json` (default: `binary`)             |

**contract** — Record a MockChain contract simulation.

| Flag                  | Description                                    |
| --------------------- | ---------------------------------------------- |
| `--wallet-id <ID>`    | Account ID for wallet (hex, default: `0x1000`) |
| `--faucet-id <ID>`    | Account ID for faucet (hex, default: `0x2000`) |
| `--symbol <SYM>`      | Faucet token symbol (default: `TEST`)          |
| `--debug`             | Enable debug mode (default: `true`)            |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`)     |

**replay** — Replay an on-chain Miden transaction.

| Flag                       | Description                                |
| -------------------------- | ------------------------------------------ |
| `--node-url <URL>`         | Miden node RPC endpoint                    |
| `--account-id <ID>`        | Account ID (hex)                           |
| `--transaction-id <ID>`    | Transaction ID (hex)                       |
| `--captured-inputs <FILE>` | Path to captured TransactionInputs JSON    |
| `-o, --out-dir <DIR>`      | Output directory (default: `./ct-traces/`) |

---

### codetracer-polkavm-recorder

Traces PolkaVM programs and ink! smart contracts.

```
codetracer-polkavm-recorder record <program> [options]
codetracer-polkavm-recorder trace-ink [options]
codetracer-polkavm-recorder replay [options]
codetracer-polkavm-recorder version
```

**record** — Record a PolkaVM program.

| Flag                  | Description                                |
| --------------------- | ------------------------------------------ |
| `<program>`           | Path to PolkaVM program blob (`.polkavm`)  |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`) |
| `-f, --format <FMT>`  | `binary` or `json` (default: `binary`)     |

**trace-ink** — Record an ink! contract execution.

| Flag                   | Description                                       |
| ---------------------- | ------------------------------------------------- |
| `--contract <PATH>`    | ink! contract (`.polkavm` blob or `.contract`)    |
| `--constructor <NAME>` | Constructor to call (e.g., `new`, `default`)      |
| `--message <NAME>`     | ink! message name (e.g., `flip`, `get`)           |
| `--arg <VALUE>`        | Message arguments (repeatable, hex-encoded SCALE) |
| `-o, --out-dir <DIR>`  | Output directory (default: `./ct-traces/`)        |

**replay** — Replay an on-chain contract.

| Flag                  | Description                                             |
| --------------------- | ------------------------------------------------------- |
| `--address <ADDR>`    | Contract address (SS58 or hex)                          |
| `--selector <NAME>`   | ink! message selector name                              |
| `--calldata <HEX>`    | Hex-encoded calldata (default: empty)                   |
| `--endpoint <URL>`    | Substrate RPC endpoint (default: `ws://127.0.0.1:9944`) |
| `--block <HASH>`      | Block hash for state fetch (latest if omitted)          |
| `--source-dir <PATH>` | Contract source directory                               |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`)              |

---

### codetracer-leo-recorder

Traces Leo smart contracts on Aleo.

```
codetracer-leo-recorder record <leo-file> [options]
codetracer-leo-recorder replay [options]
codetracer-leo-recorder version
```

**record** — Record a Leo source file.

| Flag                  | Description                                |
| --------------------- | ------------------------------------------ |
| `<leo-file>`          | Path to the `.leo` source file             |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`) |
| `-f, --format <FMT>`  | `binary` or `json` (default: `binary`)     |

**replay** — Replay an on-chain Aleo program.

| Flag                  | Description                                                      |
| --------------------- | ---------------------------------------------------------------- |
| `--program-id <ID>`   | On-chain program ID (e.g., `credits.aleo`)                       |
| `--function <NAME>`   | Function to execute                                              |
| `--input <VALUE>`     | Input values (repeatable, e.g., `--input 10u32`)                 |
| `--endpoint <URL>`    | Aleo node REST API (default: `https://api.explorer.aleo.org/v1`) |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`)                       |

---

### codetracer-ton-recorder

Traces Tolk/FunC smart contracts on TON.

```
codetracer-ton-recorder record <tolk-file> [options]
codetracer-ton-recorder trace-sandbox [options]
codetracer-ton-recorder replay [options]
codetracer-ton-recorder version
```

**record** — Record a Tolk source file.

| Flag                  | Description                                |
| --------------------- | ------------------------------------------ |
| `<tolk-file>`         | Path to the `.tolk` source file            |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`) |
| `-f, --format <FMT>`  | `binary` or `json` (default: `binary`)     |

**trace-sandbox** — Convert `@ton/sandbox` VM log output.

| Flag                  | Description                                         |
| --------------------- | --------------------------------------------------- |
| `--vm-log <FILE>`     | Path to vm_logs_full output                         |
| `--source <FILE>`     | Path to Tolk source file (default: `contract.tolk`) |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`)          |

**replay** — Replay an on-chain TON transaction.

| Flag                  | Description                                                         |
| --------------------- | ------------------------------------------------------------------- |
| `--tx-hash <HASH>`    | Transaction hash (hex-encoded)                                      |
| `--address <ADDR>`    | Contract address                                                    |
| `--endpoint <URL>`    | Liteserver endpoint (default: `https://ton.org/global-config.json`) |
| `--source-dir <PATH>` | Contract source directory                                           |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`)                          |

---

### codetracer-js-recorder

Traces JavaScript and TypeScript programs.

```
codetracer-js-recorder record <file> [options] [-- app-args]
codetracer-js-recorder instrument <src> --out <dir> [options]
```

**record** — Record a JS/TS program.

| Flag               | Description                                      |
| ------------------ | ------------------------------------------------ |
| `<file>`           | Entry file or directory                          |
| `--out-dir <DIR>`  | Trace output directory (default: `./ct-traces/`) |
| `--format <FMT>`   | `json` or `binary` (default: `json`)             |
| `--include <GLOB>` | Include glob pattern (repeatable)                |
| `--exclude <GLOB>` | Exclude glob pattern (repeatable)                |
| `-- <args>`        | Arguments passed to the instrumented program     |

**instrument** — Instrument source files without executing.

| Flag               | Description                       |
| ------------------ | --------------------------------- |
| `<src>`            | Source file or directory          |
| `--out <DIR>`      | Output directory (required)       |
| `--source-maps`    | Emit source maps                  |
| `--include <GLOB>` | Include glob pattern (repeatable) |
| `--exclude <GLOB>` | Exclude glob pattern (repeatable) |

---

### Python Recorder

The Python recorder is a pip-installable package, not a standalone binary.

```
python -m codetracer_python_recorder [options] <script> [-- args]
python -m codetracer_python_recorder --pytest [pytest-args]
python -m codetracer_python_recorder --unittest [unittest-args]
```

Usually invoked automatically via `ct record script.py`. See the [Python Getting Started](../getting_started/python.md) guide.

| Flag                        | Description                                           |
| --------------------------- | ----------------------------------------------------- |
| `<script>`                  | Python script to trace                                |
| `-o, --out-dir <DIR>`       | Output directory (default: `./trace-out/`)            |
| `--format <FMT>`            | `binary` or `json`                                    |
| `--pytest [ARGS]`           | Run pytest with arguments                             |
| `--unittest [ARGS]`         | Run unittest with arguments                           |
| `--activation-path <PATH>`  | Gate tracing to specific path                         |
| `--trace-filter <PATH>`     | Trace filter file path (repeatable)                   |
| `--io-capture <MODE>`       | Stdout/stderr capture: `off`, `proxies`, `proxies+fd` |
| `--on-recorder-error <ACT>` | Response to errors: `abort` or `disable`              |
| `--require-trace`           | Exit 1 if no trace produced                           |
| `--keep-partial-trace`      | Preserve partial traces on failure                    |
| `--log-level <LEVEL>`       | Log verbosity (e.g., `info`, `debug`)                 |
| `--log-file <PATH>`         | Write logs to file instead of stderr                  |
| `--json-errors`             | Emit JSON error trailers on stderr                    |

---

### Ruby Recorder

The Ruby recorder is a gem installed alongside your Ruby environment.

```
codetracer-ruby-recorder <script.rb> [args]
```

Usually invoked automatically via `ct record script.rb`. See the [Ruby Getting Started](../getting_started/ruby.md) guide.
