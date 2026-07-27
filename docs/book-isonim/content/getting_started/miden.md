---
title: Miden
order: 7
---
## Miden

CodeTracer supports tracing Miden VM programs and smart contracts. The recorder captures per-instruction execution state from the Miden VM (a STARK-based zero-knowledge virtual machine) and maps it back to MASM source code.

### Prerequisites

- **Miden toolchain** for writing and compiling MASM programs
- **codetracer-miden-recorder** binary installed or built from source

### Recording a Standalone Program

1. Write a MASM program:

   ```masm
   # flow_test.masm
   begin
       push.10       # a = 10
       push.32       # b = 32
       add           # sum_val = 42
       dup           # keep sum_val
       push.2
       mul           # doubled = 84
       swap
       push.10
       add           # final_result = 94 (but actually doubled + a)
   end
   ```

2. Record the trace:

   ```bash
   codetracer-miden-recorder record flow_test.masm -o ./ct-traces/
   ```

### Recording a MockChain Contract

For testing contract interactions with the MockChain simulator:

```bash
codetracer-miden-recorder contract \
    --wallet-id 0x1000 \
    --faucet-id 0x2000 \
    --symbol TEST \
    --debug \
    -o ./ct-traces/
```

### Replaying an On-Chain Transaction

```bash
codetracer-miden-recorder replay \
    --node-url http://localhost:57291 \
    --account-id 0x1234abcd \
    --transaction-id 0xdeadbeef... \
    -o ./ct-traces/
```

### Viewing the Trace

```bash
ct replay --trace-folder ./ct-traces/
```

### Key Flags

| Flag                       | Description                                              |
| -------------------------- | -------------------------------------------------------- |
| `record <PROGRAM>`         | Record a MASM source file (`.masm`) or package (`.masp`) |
| `contract`                 | Record a MockChain contract simulation                   |
| `--wallet-id <ID>`         | Account ID for wallet (hex, default: `0x1000`)           |
| `--faucet-id <ID>`         | Account ID for faucet (hex, default: `0x2000`)           |
| `--symbol <SYM>`           | Faucet token symbol (default: `TEST`)                    |
| `replay --node-url <URL>`  | Miden node RPC endpoint                                  |
| `--account-id <ID>`        | Account ID (hex)                                         |
| `--transaction-id <ID>`    | Transaction ID (hex)                                     |
| `--captured-inputs <FILE>` | Path to captured TransactionInputs JSON                  |
| `-o, --out-dir <DIR>`      | Output directory (default: `./ct-traces/`)               |
| `-f, --format <FMT>`       | Output format: `binary` or `json` (default: `binary`)    |
