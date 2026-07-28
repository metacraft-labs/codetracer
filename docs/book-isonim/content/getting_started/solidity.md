---
title: Solidity (EVM)
order: 109
---
## Solidity (EVM)

CodeTracer supports tracing Solidity smart contracts running on the Ethereum Virtual Machine. The recorder compiles your contract with `solc`, deploys it to a local Anvil node, and captures the full execution trace via `debug_traceTransaction`.

### Prerequisites

- **Solidity compiler** (`solc`) available in your PATH
- **Foundry** (`anvil`, `cast`) for local EVM execution
- **codetracer-evm-recorder** binary installed or built from source

### Recording a Trace

1. Write a Solidity contract with a `run()` function (or specify a custom entry point):

   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.0;

   contract Example {
       function run() public pure returns (uint256) {
           uint256 a = 10;
           uint256 b = 32;
           uint256 result = a + b;
           return result;
       }
   }
   ```

2. Record the trace:

   ```bash
   codetracer-evm-recorder record example.sol --trace-dir ./ct-traces/
   ```

   This will:
   - Compile `example.sol` with `solc`
   - Start a local Anvil node
   - Deploy the contract and call `run()`
   - Capture the execution trace via `debug_traceTransaction`
   - Write the trace files to `./ct-traces/`

3. To call a different function:

   ```bash
   codetracer-evm-recorder record example.sol --trace-dir ./ct-traces/ --function myFunction
   ```

### Viewing the Trace

Open the recorded trace in CodeTracer:

```bash
ct replay --trace-folder ./ct-traces/
```

### Key Flags

| Flag                | Description                       |
| ------------------- | --------------------------------- |
| `<solidity-file>`   | Path to the `.sol` source file    |
| `--trace-dir <DIR>` | Output directory for trace files  |
| `--function <NAME>` | Function to call (default: `run`) |
