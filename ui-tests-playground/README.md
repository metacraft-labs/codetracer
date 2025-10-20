# UI Tests Playground

This directory is a sandbox for prototyping ideas before they graduate into the `ui-tests-v3/` rebuild. Expect the code here to be volatile—use it to spike concepts, evaluate tooling, and document findings before hardening them for the next-generation framework.

Documentation:

- `docs/debugging.md` – quick tips for troubleshooting experiments.
- `docs/extending-the-suite.md` – conventions for adding or organising playground spikes.
- `docs/coding-guidelines.md` – minimal standards to keep prototypes readable.
- `docs/specifications.md` – lightweight notes capturing hypotheses and desired outcomes.
- `docs/development-plan.md` – short-lived task lists for active experiments.
- `docs/progress.md` – running log of insights worth upstreaming.

References:

- `ui-tests/` – the stable Playwright-based suite currently powering CodeTracer UI tests.
- `ui-tests-v3/` – the structured rebuild that will eventually replace the legacy suite.
- `/home/franz/code/repos/Puppeteer` – legacy Selenium/Puppeteer project providing APIs and helpers to port.

When a playground spike proves useful, migrate the polished pieces into `ui-tests-v3/` and record the outcome in both progress logs.
