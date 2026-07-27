---
title: Aiken (Cardano)
order: 12
---
## Aiken (Cardano)

CodeTracer supports tracing Aiken smart contracts on Cardano. The recorder steps through the UPLC (Untyped Plutus Core) CEK machine at every evaluation step and maps execution back to Aiken source code.

### Prerequisites

- **Aiken CLI** (`aiken`) v1.1.21+ for compiling contracts
- **codetracer-cardano-recorder** binary installed or built from source

### Recording a Trace

1. Create an Aiken project with a test function:

   ```aiken
   // validators/example.ak

   test test_flow() {
     let a = 10
     let b = 32
     let sum_val = a + b
     expect sum_val == 42
     let doubled = sum_val * 2
     let final_result = doubled + a
     final_result == 94
   }
   ```

2. Record the trace:

   ```bash
   codetracer-cardano-recorder record validators/example.ak -o ./ct-traces/
   ```

   The recorder will:
   - Compile the Aiken source to UPLC via `aiken build`
   - Execute the test function through the stepping CEK machine
   - Capture machine state (environment, budget, term) at every step
   - Map UPLC term indices back to Aiken source locations
   - Write the trace files to `./ct-traces/`

### Replaying an On-Chain Transaction

To debug a Cardano transaction that invoked a validator script:

```bash
codetracer-cardano-recorder replay \
    --tx-hash abc123...def456 \
    --blockfrost-key your-api-key \
    -o ./ct-traces/
```

The replayer fetches the transaction via Blockfrost, extracts the validator script and its datum/redeemer/context arguments, reconstructs the full applied UPLC program, and executes it through the stepping recorder.

:::note
On-chain scripts are flat-encoded UPLC bytecode. For source-level mapping, provide the original Aiken project source alongside the replay.
:::

### Viewing the Trace

```bash
ct replay --trace-folder ./ct-traces/
```

### Key Flags

| Flag                      | Description                                           |
| ------------------------- | ----------------------------------------------------- |
| `record <file>`           | Record an Aiken source file (`.ak`)                   |
| `replay --tx-hash <HASH>` | Replay an on-chain Cardano transaction                |
| `--blockfrost-key <KEY>`  | Blockfrost API key (or `BLOCKFROST_API_KEY` env var)  |
| `-o, --out-dir <DIR>`     | Output directory (default: `./ct-traces/`)            |
| `-f, --format <FMT>`      | Output format: `binary` or `json` (default: `binary`) |

### Execution Budget

The trace includes Cardano execution budget (CPU and memory units) at every step, visible in the CodeTracer variable pane. This helps identify which parts of your validator consume the most resources.
