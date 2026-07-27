---
title: Leo (Aleo)
order: 8
---
## Leo (Aleo)

CodeTracer supports tracing Leo smart contracts on the Aleo blockchain. The recorder captures execution state from the Leo interpreter and snarkVM, mapping it back to Leo source code.

### Prerequisites

- **Leo CLI** (`leo`) for building and testing programs
- **codetracer-leo-recorder** binary installed or built from source

### Recording a Trace

1. Write a Leo program:

   ```leo
   program flow_test.aleo {
       transition compute(a: u32, b: u32) -> u32 {
           let sum_val: u32 = a + b;
           let doubled: u32 = sum_val * 2u32;
           let final_result: u32 = doubled + a;
           return final_result;
       }
   }
   ```

2. Record the trace:

   ```bash
   codetracer-leo-recorder record main.leo -o ./ct-traces/
   ```

### Replaying an On-Chain Program

To execute and trace a deployed Aleo program:

```bash
codetracer-leo-recorder replay \
    --program-id credits.aleo \
    --function transfer_public \
    --input aleo1abc...xyz \
    --input 100u64 \
    --endpoint https://api.explorer.aleo.org/v1 \
    -o ./ct-traces/
```

### Viewing the Trace

```bash
ct replay --trace-folder ./ct-traces/
```

### Key Flags

| Flag                       | Description                                                      |
| -------------------------- | ---------------------------------------------------------------- |
| `record <file>`            | Record a Leo source file (`.leo`)                                |
| `replay --program-id <ID>` | On-chain program ID (e.g., `credits.aleo`)                       |
| `--function <NAME>`        | Function to execute                                              |
| `--input <VALUE>`          | Input values (repeatable, e.g., `--input 10u32`)                 |
| `--endpoint <URL>`         | Aleo node REST API (default: `https://api.explorer.aleo.org/v1`) |
| `-o, --out-dir <DIR>`      | Output directory (default: `./ct-traces/`)                       |
| `-f, --format <FMT>`       | Output format: `binary` or `json` (default: `binary`)            |

### Note on Zero-Knowledge Execution

Leo transitions execute off-chain with zero-knowledge proving. The recorder uses the Leo interpreter for source-level tracing of transition logic, while finalize functions (which execute on-chain) are traced at the AVM instruction level.
