# Playground Progress Log

Track insights discovered while experimenting. Move relevant entries into the V3 progress log once the work graduates.

- **2024-12-09** – Created `ui-tests-playground/` with documentation scaffolding to support rapid experimentation ahead of the V3 rebuild.
- **2024-12-09** – Added minimal console app that launches CodeTracer via Playwright, counts event log rows (`#eventLog-0-dense-table-0  tr`), prints the result, and enforces clean shutdown of all `ct`/Electron processes.
- **2024-12-09** – Extended playground runner with a `web` mode (now executed sequentially after the Electron flow): starts `ct host`, waits for localhost:5001, loads it with Playwright, counts event rows, and force-terminates host/Node processes after execution.
- **2024-12-09** – Web mode now maximizes Chromium by default, autodetects monitor layouts via `xrandr` (prefers the primary display), accepts `PLAYGROUND_WINDOW_POSITION` / `PLAYGROUND_WINDOW_SIZE` overrides, and normalises zoom to 100% to avoid blurred or cropped views.
