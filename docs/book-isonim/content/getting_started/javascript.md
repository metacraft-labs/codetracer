---
title: JavaScript / TypeScript
order: 103
---
## JavaScript / TypeScript

CodeTracer supports tracing JavaScript and TypeScript programs. The recorder instruments your source code and captures execution state at every statement.

### Prerequisites

- **Node.js** (v18+)
- **codetracer-js-recorder** installed via npm or built from source

### Recording a Trace

1. Write a JavaScript program:

   ```javascript
   function compute() {
     const a = 10;
     const b = 32;
     const sumVal = a + b;
     const doubled = sumVal * 2;
     const finalResult = doubled + a;
     return finalResult;
   }

   console.log(compute());
   ```

2. Record the trace:

   ```bash
   codetracer-js-recorder record script.js --out-dir ./ct-traces/
   ```

3. With application arguments:

   ```bash
   codetracer-js-recorder record script.js --out-dir ./ct-traces/ -- --port 3000
   ```

4. Filter which files are instrumented:

   ```bash
   codetracer-js-recorder record src/index.ts \
       --include "src/**/*.ts" \
       --exclude "node_modules/**" \
       --out-dir ./ct-traces/
   ```

### Instrumenting Without Recording

You can instrument source files separately (useful for build pipelines):

```bash
codetracer-js-recorder instrument src/ --out dist/ --source-maps
```

### Viewing the Trace

```bash
ct replay --trace-folder ./ct-traces/
```

### Key Flags

| Flag               | Description                                        |
| ------------------ | -------------------------------------------------- |
| `record <file>`    | Entry file or directory to record                  |
| `instrument <src>` | Instrument source files without executing          |
| `--out <DIR>`      | Output directory for instrumented files            |
| `--out-dir <DIR>`  | Trace output directory (default: `./ct-traces/`)   |
| `--format <FMT>`   | Trace format: `json` or `binary` (default: `json`) |
| `--include <GLOB>` | Include glob pattern (repeatable)                  |
| `--exclude <GLOB>` | Exclude glob pattern (repeatable)                  |
| `--source-maps`    | Emit source maps during instrumentation            |
| `-- <args>`        | Arguments passed to the instrumented program       |
