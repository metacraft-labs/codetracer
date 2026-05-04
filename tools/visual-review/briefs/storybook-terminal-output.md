# Terminal Output Story Visual Brief

## What You're Reviewing

This is the CodeTracer Terminal Output panel rendered in Storybook through the
real IsoNim Terminal Output view.

Shared project brief: `../project-visual-brief.md`

## Screen

- Route: Storybook iframe story `codetracer-panels--terminal-output`
- Capture id: `storybook-terminal-output`
- Viewport: laptop, 1440x900

## Seeded State

The fixture shows a Noir replay that has printed three terminal lines. The
middle line is the active replay position.

## Expected Visible Content

- Dark CodeTracer app background and app font styling.
- Terminal output panel with CodeTracer terminal row styling.
- Three terminal lines including "CodeTracer replay started",
  "noir-space-ship", and a warning line.
- Active/past/future terminal fragments should be visually distinguishable.

## Must Not Show

- Generic browser serif fonts.
- White Storybook or Bootstrap default panel background.
- A tiny unstyled text block floating in empty space.
- Missing app CSS or broken icon/resource requests.

## What to Evaluate

Check whether app styles are actually applied, whether the panel sits in a
CodeTracer-like shell context, and whether spacing, typography, contrast, and
visual hierarchy look like the real app.

## How to Report

Keep under 200 words. Lead with an overall impression, list specific visual
issues, then give the top two fixes. Include a 1-10 rating.
