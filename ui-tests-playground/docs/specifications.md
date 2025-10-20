# Playground Specifications & Hypotheses

Capture high-level ideas you intend to prototype in this sandbox before formalising them for `ui-tests-v3/`.

## Active Hypotheses

- **Launcher Abstractions** – Evaluate whether CodeTracer startup can be expressed through composable middleware (env patches, logging hooks).
- **Reporting Pipelines** – Prototype richer artifact gathering (screenshots, HAR files) to inform the V3 reporting design.
- **Cross-Browser Support** – Test if Playwright-based suites can target Chromium + WebKit seamlessly for CodeTracer scenarios.

Reference where each hypothesis is explored (directory names, branch info).

## Desired Outcomes

- Identify utilities from `/home/franz/code/repos/Puppeteer` that migrate cleanly and catalogue incompatible pieces.
- Produce reference implementations or pseudo-code that V3 can adopt with minimal rework.
- Document pitfalls or blockers that V3 must address explicitly.

Update this file as new ideas emerge or as existing hypotheses are validated or shelved.
