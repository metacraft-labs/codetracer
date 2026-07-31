---
title: Cairo (StarkNet)
order: 111
---
## Cairo (StarkNet)

CodeTracer supports tracing Cairo programs and StarkNet smart contracts. The recorder consumes execution traces from the Cairo VM and maps them to Cairo source code via Sierra debug info.

### Prerequisites

- **Cairo compiler** (`cairo-compile`, `cairo-run`) or **Scarb** build tool
- **snforge** (for StarkNet contract testing)
- **codetracer-cairo-recorder** binary installed or built from source

### Recording a Standalone Cairo Program

1. Write a Cairo program:

   ```cairo
   fn main() {
       let a: felt252 = 10;
       let b: felt252 = 32;
       let sum_val = a + b;
       let doubled = sum_val * 2;
       let final_result = doubled + a;
       println!("Result: {}", final_result);
   }
   ```

2. Record the trace:

   ```bash
   codetracer-cairo-recorder record program.cairo -o ./ct-traces/
   ```

### Recording a StarkNet Contract Test

1. Set up a Scarb project with `snforge` tests, then record a test trace:

   ```bash
   codetracer-cairo-recorder trace-starknet trace.json -o ./ct-traces/
   ```

   Where `trace.json` is the execution trace output from `snforge test --trace`.

### Replaying an On-Chain Transaction

```bash
codetracer-cairo-recorder replay \
    --tx-hash 0x04a3c... \
    --rpc-url https://starknet-mainnet.public.blastapi.io \
    --source-dir ./src/ \
    -o ./ct-traces/
```

### Viewing the Trace

```bash
ct replay --trace-folder ./ct-traces/
```

### Key Flags

| Flag                      | Description                                           |
| ------------------------- | ----------------------------------------------------- |
| `record <file>`           | Record a standalone `.cairo` program                  |
| `trace-starknet <trace>`  | Convert an snforge trace JSON to CodeTracer format    |
| `replay --tx-hash <HASH>` | Replay an on-chain StarkNet transaction               |
| `--rpc-url <URL>`         | StarkNet JSON-RPC endpoint                            |
| `--source-dir <PATH>`     | Directory with contract source code                   |
| `-o, --out-dir <DIR>`     | Output directory (default: `./ct-traces/`)            |
| `-f, --format <FMT>`      | Output format: `binary` or `json` (default: `binary`) |
