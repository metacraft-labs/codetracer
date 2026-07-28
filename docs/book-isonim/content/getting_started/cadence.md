---
title: Cadence (Flow)
order: 113
---
## Cadence (Flow)

CodeTracer supports tracing Cadence smart contracts on the Flow blockchain. The recorder instruments the Cadence interpreter's `OnStatement` hook to capture per-statement execution state, producing structured trace data.

### Prerequisites

- **Flow CLI** (`flow`) v2.x+ for running the emulator and tests
- **Go toolchain** (Go 1.22+) for building the Go tracer helper
- **codetracer-flow-recorder** binary installed or built from source

### Recording a Trace

1. Write a Cadence contract:

   ```cadence
   access(all) contract FlowTest {
       access(all) fun compute(): Int {
           let a: Int = 10
           let b: Int = 32
           let sumVal: Int = a + b
           let doubled: Int = sumVal * 2
           let finalResult: Int = doubled + a
           return finalResult
       }
   }
   ```

2. Record the trace:

   ```bash
   codetracer-flow-recorder record FlowTest.cdc -o ./ct-traces/
   ```

   The recorder will:
   - Parse the Cadence source
   - Configure the interpreter with an `OnStatement` callback
   - Execute the program, capturing source location, variable state, and call stack at every statement
   - Convert the execution trace to CodeTracer's format

### Replaying an On-Chain Transaction

To debug a Flow transaction from mainnet or testnet:

```bash
codetracer-flow-recorder replay \
    --tx-hash abc123...def \
    --access-node access.mainnet.nodes.onflow.org:9000 \
    --source-dir ./cadence/contracts/ \
    -o ./ct-traces/
```

The replayer uses the Flow emulator's fork mode to recreate historical state and re-execute the transaction with tracing enabled. Cadence contracts are stored as source code on-chain, so source is always available via the Access API.

### Viewing the Trace

```bash
ct replay --trace-folder ./ct-traces/
```

### Key Flags

| Flag                      | Description                                           |
| ------------------------- | ----------------------------------------------------- |
| `record <file>`           | Record a Cadence source file (`.cdc`)                 |
| `replay --tx-hash <HASH>` | Replay an on-chain Flow transaction                   |
| `--access-node <URL>`     | Flow Access Node gRPC endpoint                        |
| `--source-dir <PATH>`     | Directory with Cadence source files                   |
| `-o, --out-dir <DIR>`     | Output directory (default: `./ct-traces/`)            |
| `-f, --format <FMT>`      | Output format: `binary` or `json` (default: `binary`) |

### Resource Tracking

Cadence uses a resource-oriented programming model where resources cannot be copied, only moved (`<-`). The trace captures resource lifecycle events (creation, moves, destruction), visible in the variable pane with resource type and UUID.
