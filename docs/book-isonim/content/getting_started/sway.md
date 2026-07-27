---
title: Sway (FuelVM)
order: 16
---
## Sway (FuelVM)

CodeTracer supports tracing Sway smart contracts on the Fuel blockchain. The recorder captures per-instruction execution state from FuelVM and maps it back to Sway source code.

### Prerequisites

- **Fuel toolchain** (`forc`, `fuel-core`) for building and running contracts
- **codetracer-fuel-recorder** binary installed or built from source

### Recording a Trace

1. Create or navigate to a Sway project (must contain `Forc.toml`):

   ```bash
   forc new my_contract
   cd my_contract
   ```

2. Record the trace:

   ```bash
   codetracer-fuel-recorder record . -o ./ct-traces/
   ```

   Or from a pre-compiled bytecode file:

   ```bash
   codetracer-fuel-recorder record --bytecode out/debug/my_contract.bin -o ./ct-traces/
   ```

3. With an ABI file for variable enrichment:

   ```bash
   codetracer-fuel-recorder record . --abi out/debug/my_contract-abi.json -o ./ct-traces/
   ```

### Replaying an On-Chain Transaction

To debug a transaction from a Fuel node:

```bash
codetracer-fuel-recorder replay \
    --tx-id 0xabc123... \
    --rpc-url http://localhost:4000/v1/graphql \
    --source-dir ./out/debug/ \
    -o ./ct-traces/
```

### Viewing the Trace

```bash
ct replay --trace-folder ./ct-traces/
```

### Key Flags

| Flag                   | Description                                                              |
| ---------------------- | ------------------------------------------------------------------------ |
| `record [PROJECT_DIR]` | Record from a Sway project (must contain `Forc.toml`)                    |
| `--bytecode <FILE>`    | Raw FuelVM bytecode file                                                 |
| `--abi <FILE>`         | Sway ABI JSON for variable enrichment                                    |
| `replay --tx-id <ID>`  | Replay an on-chain transaction (hex with `0x` prefix)                    |
| `--rpc-url <URL>`      | fuel-core GraphQL endpoint (default: `http://localhost:4000/v1/graphql`) |
| `--source-dir <PATH>`  | Directory with forc build output                                         |
| `-o, --out-dir <DIR>`  | Output directory (default: `./ct-traces/`)                               |
| `-f, --format <FMT>`   | Output format: `binary` or `json` (default: `binary`)                    |
