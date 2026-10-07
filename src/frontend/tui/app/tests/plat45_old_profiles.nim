## plat45_old_profiles.nim — PLAT-45's risk mitigation, kept as a FIXTURE.
##
## "Compact terminals get a worse layout than today's hand-tuned one. The fold
## order is data: if the folded compact result is worse than §3.2's current
## compact profile, the order changes, not the rule. The old three profiles
## are kept as test fixtures to compare against."
##
## These are the three trees `app/layout/profile.profileLayout` returned before
## PLAT-45 made the terminal's default a fold of the shared arrangement —
## copied verbatim from that function as it stood on `agents` at 8e7ec9cdb. They
## are not product code and nothing in `app/` imports them; the comparison
## suite (`test_plat45_fold.nim`) reads them to put the old and the new answers
## side by side at the three sizes the old §3.2 named.

import headless_app/layout_model

type
  OldProfile* = enum
    opCompact = "compact"
    opStandard = "standard"
    opUltraWide = "ultra-wide"

const OldProfileSizes*: array[OldProfile, (int, int)] = [
  (80, 24), (120, 40), (200, 50)]
  ## The size each old profile was the answer for, one per §3.2 row.

proc oldProfileLayout*(profile: OldProfile): LayoutNode =
  ## PLAT-51: the Timeline strip these trees placed is the Terminal Output
  ## here — the Timeline panel is removed from every product, and the
  ## trees are kept for their SHAPES (a strip under columns, a tab stack).
  case profile
  of opCompact:
    column([
      row([
        pane(paneCalltrace, "Call Stack", weight = 30.0),
        pane(paneEditor, "Source", weight = 70.0)],
        weight = 3.0),
      stack([
        pane(paneState, "Variables"),
        pane(paneTerminalOutput, "Terminal"),
        pane(paneEventLog, "Tracepoints")],
        activeIndex = 0, weight = 1.0)])
  of opStandard:
    column([
      row([
        pane(paneCalltrace, "Call Stack", weight = 25.0),
        pane(paneEditor, "Source", weight = 50.0),
        pane(paneState, "Variables", weight = 25.0)],
        weight = 4.0),
      pane(paneTerminalOutput, "Terminal Output", weight = 1.0)])
  of opUltraWide:
    column([
      row([
        pane(paneCalltrace, "Call Stack", weight = 20.0),
        pane(paneEditor, "Source", weight = 45.0),
        pane(paneState, "Variables", weight = 20.0),
        pane(paneEventLog, "Event Log", weight = 15.0)],
        weight = 4.0),
      pane(paneTerminalOutput, "Terminal Output", weight = 1.0)])
