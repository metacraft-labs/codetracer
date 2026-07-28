---
title: PolkaVM (ink!)
order: 117
---
## PolkaVM (ink!)

CodeTracer supports tracing programs running on PolkaVM, Polkadot's RISC-V based virtual machine. The recorder uses PolkaVM's built-in step tracing and LineProgram debug info for source-level mapping.

### Prerequisites

- **Rust toolchain** with `riscv32em-unknown-none-elf` target for compiling PolkaVM programs
- **ink!** framework (v6+) for smart contracts
- **codetracer-polkavm-recorder** binary installed or built from source

### Recording a PolkaVM Program

```bash
codetracer-polkavm-recorder record program.polkavm -o ./ct-traces/
```

### Recording an ink! Contract

1. Build your ink! contract:

   ```bash
   cd my_ink_contract
   cargo contract build
   ```

2. Record a contract message execution:

   ```bash
   codetracer-polkavm-recorder trace-ink \
       --contract target/ink/my_contract.contract \
       --constructor new \
       --message get \
       -o ./ct-traces/
   ```

3. With message arguments:

   ```bash
   codetracer-polkavm-recorder trace-ink \
       --contract target/ink/my_contract.contract \
       --message flip \
       --arg 0x01 \
       -o ./ct-traces/
   ```

### Replaying an On-Chain Contract

To debug a contract call on a Substrate chain:

```bash
codetracer-polkavm-recorder replay \
    --address 5GrwvaEF5... \
    --selector get \
    --endpoint ws://127.0.0.1:9944 \
    --source-dir ./src/ \
    -o ./ct-traces/
```

### Viewing the Trace

```bash
ct replay --trace-folder ./ct-traces/
```

### Key Flags

| Flag                          | Description                                             |
| ----------------------------- | ------------------------------------------------------- |
| `record <program>`            | Record a PolkaVM program blob (`.polkavm`)              |
| `trace-ink --contract <PATH>` | Record an ink! contract execution                       |
| `--constructor <NAME>`        | Constructor to call (e.g., `new`, `default`)            |
| `--message <NAME>`            | ink! message name (e.g., `flip`, `get`)                 |
| `--arg <VALUE>`               | Message arguments (repeatable, hex-encoded SCALE)       |
| `replay --address <ADDR>`     | On-chain contract address (SS58 or hex)                 |
| `--selector <NAME>`           | ink! message selector name                              |
| `--endpoint <URL>`            | Substrate RPC endpoint (default: `ws://127.0.0.1:9944`) |
| `--block <HASH>`              | Block hash for state fetch (latest if omitted)          |
| `--source-dir <PATH>`         | Contract source directory                               |
| `-o, --out-dir <DIR>`         | Output directory (default: `./ct-traces/`)              |
| `-f, --format <FMT>`          | Output format: `binary` or `json` (default: `binary`)   |
