# Build Panel Story Visual Brief

## What You're Reviewing

This is the CodeTracer Build panel rendered in Storybook through the real
IsoNim Build view.

Shared project brief: `../project-visual-brief.md`

## Screen

- Route: Storybook iframe story `codetracer-panels--build`
- Capture id: `storybook-build-panel`
- Viewport: laptop, 1440x900

## Seeded State

The fixture shows a failed `nargo test` build with stdout, stderr, and parsed
problem rows.

## Expected Visible Content

- Dark CodeTracer app background and app font styling.
- Build header/status controls styled like the app.
- Compiler output lines with error/warning colors.
- Clickable source-location styling for `src/combat.nr:42`.

## Must Not Show

- Unstyled default buttons or form controls.
- Missing CodeTracer color palette.
- Text overlapping the header controls.
- A bare list of lines with no panel structure.

## What to Evaluate

Focus on whether the app CSS is matching the real DOM, and whether the panel
looks like a real CodeTracer bottom/side panel rather than a mock.

## How to Report

Keep under 200 words. Lead with an overall impression, list specific visual
issues, then give the top two fixes. Include a 1-10 rating.
