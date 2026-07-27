---
title: Circom
order: 6
---
## Circom

CodeTracer supports tracing Circom zero-knowledge circuits during witness generation. The recorder traces the witness computation and maps signal assignments back to your `.circom` source code.

### Prerequisites

- **Circom compiler** (`circom`) available in your PATH
- **Node.js** (for the WASM witness generator) or **C++ toolchain** (gcc, make, gmp) for the C++ backend
- **codetracer-circom-recorder** binary installed or built from source

### Recording a Trace

1. Write a Circom circuit:

   ```circom
   pragma circom 2.0.0;

   template FlowTest() {
       signal input a;
       signal input b;
       signal output result;

       signal sumVal;
       sumVal <== a + b;

       signal doubled;
       doubled <== sumVal * 2;

       result <== doubled + a;
   }

   component main = FlowTest();
   ```

2. Record the trace using the WASM backend (default):

   ```bash
   codetracer-circom-recorder record flow_test.circom -o ./ct-traces/
   ```

3. Or use the C++ witness generator backend for larger circuits:

   ```bash
   codetracer-circom-recorder record flow_test.circom -o ./ct-traces/ --backend cpp
   ```

   The recorder will:
   - Compile the circuit with `circom` (using `--wasm` or `--c` depending on backend)
   - Generate a source map if using the [metacraft-labs circom fork](https://github.com/metacraft-labs/circom)
   - Execute the witness generator with default inputs
   - Capture signal assignments and map them to source locations
   - Write the trace files to `./ct-traces/`

### Viewing the Trace

```bash
ct replay --trace-folder ./ct-traces/
```

### Key Flags

| Flag                  | Description                                           |
| --------------------- | ----------------------------------------------------- |
| `<circom-file>`       | Path to the `.circom` source file                     |
| `-o, --out-dir <DIR>` | Output directory (default: `./ct-traces/`)            |
| `-f, --format <FMT>`  | Output format: `binary` or `json` (default: `binary`) |
| `-b, --backend <BE>`  | Witness generator: `wasm` or `cpp` (default: `wasm`)  |

### Source Mapping

For the best debugging experience, use the [metacraft-labs circom fork](https://github.com/metacraft-labs/circom) which adds a `--srcmap` flag for precise source-level mapping. Without it, the recorder falls back to heuristic source mapping.
