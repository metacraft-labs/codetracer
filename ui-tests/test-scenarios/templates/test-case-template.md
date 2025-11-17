# Test Case Template

Copy this template into the appropriate suite file and fill in the details.

```
## <ID> <Title>

- Suite: <component/program/platform>
- Type: <functional | regression | smoke | long-run>
- Platform: <Electron | Web> (Browser: <Chrome/Chromium | Firefox | Safari>)
- Operating Systems: <Fedora | NixOS | Ubuntu | macOS>
- Program: <program-agnostic | noir_space_ship | ruby_space_ship>
- Preconditions:
  - <environment setup, flags, fixtures>
  - Launch CodeTracer using the <program> program.

### Steps and Expected Results
1. <Step 1> — <Expected result 1>
2. <Step 2> — <Expected result 2>
3. <Continue as needed>

### Notes
- <links to automated test IDs or TODOs for automation>
- <logging/telemetry to capture if applicable>
```
