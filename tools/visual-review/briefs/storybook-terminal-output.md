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

The fixture shows the Noir space-ship replay terminal transcript from the
Karax terminal-visible reference. All lines are ahead of the current replay
position, matching the reference state.

## Expected Visible Content

- Dark CodeTracer app background and app font styling.
- Terminal output panel with CodeTracer terminal row styling.
- Dense terminal output including "Positive Test Case", shield status rows,
  and the final "shields will not hold as expected" line.
- Future terminal fragments should use the same dimmed terminal row styling as
  the Karax reference.

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
