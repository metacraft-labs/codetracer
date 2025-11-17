# Platform and Environment Matrix

Use this matrix to mark where each test case must run. Platform tags should be copied into the test case metadata so CI can schedule the right jobs.

- **Operating systems:** Fedora, NixOS, Ubuntu, macOS (Intel/Apple Silicon where applicable).
- **Application targets:** Electron desktop build; Web build.
- **Browsers (Web only):** Chrome/Chromium, Firefox, Safari.

| Platform | OS | Browser | Notes |
| --- | --- | --- | --- |
| Electron | Fedora, NixOS, Ubuntu, macOS | n/a | Covers desktop packaging, window management, and Electron-specific IPC. |
| Web | Fedora, NixOS, Ubuntu, macOS | Chrome/Chromium | Primary automation target; stable channel preferred. |
| Web | Fedora, NixOS, Ubuntu, macOS | Firefox | Ensures non-Chromium engine compatibility. |
| Web | macOS | Safari | Critical for macOS users; run at least in smoke/regression. |

**Execution guidance**

- **Smoke:** Minimal happy-path checks per platform before merges. Run on Fedora/Chromium for Web and Fedora for Electron as the default fast path.
- **Regression:** Full component and program suites across Fedora, Ubuntu, and macOS; include Chrome/Chromium and Firefox; add Safari for Web where available.
- **Long-run/rotation:** Periodic runs on NixOS and browsers not in the daily matrix to catch drift.
