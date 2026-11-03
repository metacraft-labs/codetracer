# Agent Harbor Front-End Views

The `agent-harbor-*` views of `tools/visual-review/capture-storybook.mjs` are
reviewed against **the private design brief** for CodeTracer as an Agent
Harbor front-end, together with its parity inventory (whose `INV-…` ids the
views, viewmodels and stories cite). Neither is published: both describe the
Agent Harbor WebUI in detail. A reviewer with access is given the brief's path;
`CODETRACER_AGENT_HARBOR_BRIEF=<path>` makes the capture tool record that path
in its reports instead of this file's.

What the brief fixes, in short:

- every view is captured at the `panel` (760 × 640), `sidebar` (360 × 900) and
  `laptop` (1440 × 900) sizes, in the `dark` and `light` themes, at
  CodeTracer's one generated density (Compact);
- the `agent-harbor-ref-*` views are existing CodeTracer panels (Agent
  Activity, Test Results, VCS, the session tab strip, the status shell); each
  new view is compared with them for typography, spacing, colour, density,
  iconography and interaction cues;
- colours, sizes and fonts come only from the design-system roles CodeTracer's
  existing panels use.

```bash
node tools/visual-review/capture-storybook.mjs --view agent-harbor-fleet-snapshot \
  [--out <dir>] [--size panel|sidebar|laptop] [--theme dark|light] [--no-build]
```

Images of stories built over captured data are private too: pass `--out` to
a private location rather than committing them.
