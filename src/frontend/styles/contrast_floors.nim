## contrast_floors.nim — the contrast floors every native front-end's chrome
## is graded against, defined once (the terminal's roles and GPUI's chrome
## both read them; neither front-end may import the other).

const
  TabGroundContrastFloor* = 1.4
    ## PLAT-68: the least WCAG contrast ratio between the selected tab's
    ## ground and the other tabs' on one strip — the focused strip's
    ## included — so the selected tab is told apart by its ground and not by
    ## its weight alone. The focused strip's measure: ui/surface/primary/
    ## default against ui/border/secondary, 1.51:1 (Dark) and 1.83:1
    ## (Light).
