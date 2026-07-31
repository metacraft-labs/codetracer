---
title: Tolk (TON)
order: 118
---
## Tolk (TON)

CodeTracer supports tracing Tolk (and FunC) smart contracts on the TON blockchain. The recorder instruments the TVM (TON Virtual Machine) to capture per-instruction execution state and maps TVM stack operations back to Tolk source code via debug sections.

### Prerequisites

- **Tolk compiler** for compiling contracts
- **Node.js** and **@ton/sandbox** for local contract testing
- **codetracer-ton-recorder** binary installed or built from source

### Recording a Trace

1. Write a Tolk contract:

   ```tolk
   fun compute(): int {
       var a: int = 10;
       var b: int = 32;
       var sumVal: int = a + b;
       var doubled: int = sumVal * 2;
       var finalResult: int = doubled + a;
       return finalResult;
   }
   ```

2. Record the trace:

   ```bash
   codetracer-ton-recorder record contract.tolk -o ./ct-traces/
   ```

### Recording from @ton/sandbox

If you use `@ton/sandbox` for contract testing, capture the VM logs and convert them:

```bash
codetracer-ton-recorder trace-sandbox \
    --vm-log vm_logs_full.txt \
    --source contract.tolk \
    -o ./ct-traces/
```

### Replaying an On-Chain Transaction

To debug a transaction from the TON blockchain:

```bash
codetracer-ton-recorder replay \
    --tx-hash abc123...def \
    --address EQBabc...xyz \
    --endpoint https://ton.org/global-config.json \
    --source-dir ./contracts/ \
    -o ./ct-traces/
```

### Viewing the Trace

```bash
ct replay --trace-folder ./ct-traces/
```

### Key Flags

| Flag                            | Description                                                         |
| ------------------------------- | ------------------------------------------------------------------- |
| `record <file>`                 | Record a Tolk source file (`.tolk`)                                 |
| `trace-sandbox --vm-log <FILE>` | Convert `@ton/sandbox` VM log output                                |
| `--source <FILE>`               | Path to Tolk source file (default: `contract.tolk`)                 |
| `replay --tx-hash <HASH>`       | Replay a TON transaction (hex-encoded)                              |
| `--address <ADDR>`              | Contract address that executed the transaction                      |
| `--endpoint <URL>`              | Liteserver endpoint (default: `https://ton.org/global-config.json`) |
| `--source-dir <PATH>`           | Contract source directory                                           |
| `-o, --out-dir <DIR>`           | Output directory (default: `./ct-traces/`)                          |
| `-f, --format <FMT>`            | Output format: `binary` or `json` (default: `binary`)               |

### Variable Reconstruction

The TVM has no named local variables — it uses a stack-based architecture. The recorder uses heuristic stack tracking combined with the Tolk compiler's debug sections to reconstruct variable names and values at each step.
