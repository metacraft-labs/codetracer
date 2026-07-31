---
title: Solana
order: 115
---
## Solana

CodeTracer supports tracing Solana programs (smart contracts) written in Rust. The recorder captures per-instruction register state from the SBF (Solana Bytecode Format) virtual machine and maps it back to Rust source code via DWARF debug info.

### Prerequisites

- **Solana CLI** and **Anchor** framework for building programs
- **codetracer-solana-recorder** binary installed or built from source

### Recording a Trace

1. Build your Solana program with debug info:

   ```bash
   cd my-solana-program
   anchor build
   ```

2. Record from a pre-generated register trace:

   ```bash
   codetracer-solana-recorder record target/deploy/my_program.so \
       --regs trace.regs \
       --elf target/deploy/my_program.so \
       -o ./ct-traces/
   ```

3. Or with an Anchor IDL for account data decoding:

   ```bash
   codetracer-solana-recorder record target/deploy/my_program.so \
       --regs trace.regs \
       --idl target/idl/my_program.json \
       -o ./ct-traces/
   ```

### Replaying an On-Chain Transaction

To debug a transaction from mainnet, devnet, or a local validator:

```bash
codetracer-solana-recorder replay \
    --signature 5abc123...xyz \
    --rpc-url https://api.mainnet-beta.solana.com \
    --program-dir target/deploy/ \
    -o ./ct-traces/
```

For local development with `solana-test-validator`:

```bash
codetracer-solana-recorder replay \
    --signature 5abc123...xyz \
    --rpc-url http://localhost:8899 \
    --program-dir target/deploy/ \
    -o ./ct-traces/
```

### Viewing the Trace

```bash
ct replay --trace-folder ./ct-traces/
```

### Key Flags

| Flag                       | Description                                                     |
| -------------------------- | --------------------------------------------------------------- |
| `record <ELF>`             | Record from a compiled `.so` ELF file                           |
| `--regs <FILE>`            | Pre-generated register trace file (`.regs` binary)              |
| `--elf <PATH>`             | Unstripped ELF for DWARF source mapping                         |
| `--idl <FILE>`             | Anchor IDL JSON for account data decoding                       |
| `replay --signature <SIG>` | Replay a transaction by its base-58 signature                   |
| `--rpc-url <URL>`          | Solana JSON-RPC endpoint (default: `http://localhost:8899`)     |
| `--program-dir <PATH>`     | Directory with compiled `.so` files (default: `target/deploy/`) |
| `-o, --out-dir <DIR>`      | Output directory (default: `./ct-traces/`)                      |
| `-f, --format <FMT>`       | Output format: `binary` or `json` (default: `binary`)           |
