# Default Layout Story Visual Brief

## What You're Reviewing

This is the Storybook default IsoNim app-shell layout story. It exercises
multiple real panel views together in the standalone IsoNim shell.

Shared project brief: `../project-visual-brief.md`

## Screen

- Route: Storybook iframe story `codetracer-layouts--default-debug`
- Capture id: `storybook-default-layout`
- Viewport: laptop, 1440x900

## Seeded State

The fixture includes a Karax-reference-shaped Golden Layout debugging workspace
with Filesystem, Editor, State/Scratchpad, Calltrace/Agent Activity, and Event
Log/Terminal Output stacks. Visible panels are real IsoNim views; inactive tabs
should remain present in the DOM but hidden like the Karax reference.

## Expected Visible Content

- Dark CodeTracer app styling loaded in the iframe.
- Golden Layout panel headers, grouped tabs, splitters, and content cells should
  be visible.
- Multiple real IsoNim panels should look like CodeTracer surfaces, not browser defaults.
- The layout should use the Karax shell framing: dark body, top-offset
  root-container, `#ROOT`, empty `#main`, and GoldenLayout immediately under
  `#ROOT`.

## Must Not Show

- Blank screen.
- White background or generic Storybook styling dominating the view.
- Panels clipped to unusably small fragments.
- Missing CSS resources or broken image icons.

## What to Evaluate

Evaluate shell context, spacing, panel sizing, typography, color, and whether
the surface is useful for visual parity work.

## How to Report

Keep under 200 words. Lead with an overall impression, list specific visual
issues, then give the top two fixes. Include a 1-10 rating.
