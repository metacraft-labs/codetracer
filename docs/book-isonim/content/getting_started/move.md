---
title: Move (Sui / Aptos)
order: 14
---
## Move (Sui / Aptos)

CodeTracer supports tracing Move smart contracts on both Sui and Aptos. The recorder captures per-instruction execution state from the Move VM and maps it back to Move source code.

### Prerequisites

- **Sui CLI** (`sui`) or **Aptos CLI** (`aptos`) for building and deploying
- **codetracer-move-recorder** binary installed or built from source

### Recording from a Trace File

The Move recorder converts execution trace files (produced by the instrumented Move VM) to CodeTracer format:

```bash
codetracer-move-recorder record trace.json -o ./ct-traces/
```

For compressed traces:

```bash
codetracer-move-recorder record trace.json.zst -o ./ct-traces/
```

Optionally provide the Move source file for enhanced source mapping:

```bash
codetracer-move-recorder record trace.json -s sources/my_module.move -o ./ct-traces/
```

### Replaying a Sui Transaction

```bash
codetracer-move-recorder replay \
    --digest <TRANSACTION_DIGEST> \
    --rpc-url https://fullnode.mainnet.sui.io:443 \
    --source-dir ./sources/ \
    -o ./ct-traces/
```

For local development:

```bash
codetracer-move-recorder replay \
    --digest <DIGEST> \
    --rpc-url http://localhost:9000 \
    --source-dir ./sources/ \
    -o ./ct-traces/
```

### Replaying an Aptos Transaction

```bash
codetracer-move-recorder aptosreplay \
    --txn-version 123456789 \
    --node-url https://fullnode.mainnet.aptoslabs.com/v1 \
    --source-dir ./sources/ \
    -o ./ct-traces/
```

### Viewing the Trace

```bash
ct replay --trace-folder ./ct-traces/
```

### Key Flags

| Flag                            | Description                                                           |
| ------------------------------- | --------------------------------------------------------------------- |
| `record <trace>`                | Convert a Move trace file (`.json` or `.json.zst`)                    |
| `-s, --source <FILE>`           | Move source file for enhanced mapping                                 |
| `replay --digest <DIGEST>`      | Replay a Sui transaction by digest                                    |
| `--rpc-url <URL>`               | Sui RPC endpoint (default: `http://localhost:9000`)                   |
| `aptosreplay --txn-version <N>` | Replay an Aptos transaction by ledger version                         |
| `--node-url <URL>`              | Aptos REST API (default: `https://fullnode.mainnet.aptoslabs.com/v1`) |
| `--source-dir <PATH>`           | Directory with Move source files                                      |
| `--profile-gas`                 | Run gas profiling (Aptos, default: `true`)                            |
| `-o, --out-dir <DIR>`           | Output directory (default: `./ct-traces/`)                            |
| `-f, --format <FMT>`            | Output format: `binary` or `json` (default: `binary`)                 |
