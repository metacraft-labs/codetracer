## What a context-expansion boundary offers, as data (UD-2).
##
## DeepReview-GUI.md §4.2 requires the two controls — "Expand surrounding
## context above a visible region / Expand surrounding context below a visible
## region" — and the owner's description of this milestone adds a context menu
## on the boundary offering "more lines" and "the whole file in this
## direction", each direction independently.
##
## The *gesture* is Monaco's: the vendored monaco-editor 0.54.0 already draws a
## drag handle at each edge of a collapsed unchanged region and binds
## ``mousedown`` / ``mousemove`` / ``mouseup`` to ``showMoreAbove`` /
## ``showMoreBelow`` (measured against the shipped bundle,
## ``min/vs/editor.api-i0YVFWkl.js``).  What it does not have is a menu, a
## keyboard path or an accessible name, and those are what this module
## describes.
##
## It is data rather than DOM so the amounts and the wording are decided — and
## asserted — where they are reasoned about, and so the JavaScript layer in
## ``ui/diff_expansion.nim`` is only a translation of each command into one
## call on Monaco's unchanged region.  Nothing here imports Monaco, the DOM or
## a signal.

import ./vcs_vm

const
  DiffExpandStep* = ContextExpandStep
    ## Lines one press of a boundary reveals.
    ##
    ## Deliberately the SAME constant the pre-UD-2 expand control advanced by,
    ## and the one this tab hands Monaco as ``hideUnchangedRegionsRevealLineCount``
    ## — so a click, a keypress and the menu's first item all move by the same
    ## amount, and there is exactly one place to change it.

  DiffExpandLargeStep* = 50
    ## The menu's second offer, for a reader who wants a screenful rather than
    ## a few lines but not the whole file.  Five presses' worth: large enough
    ## to be worth a separate item, small enough that it is still "more
    ## context" rather than "open the file".

type
  DiffExpandDirection* = enum
    ## Which edge of a collapsed region a gesture acts on.
    ##
    ## Named for the direction the revealed lines appear in, which is also how
    ## Monaco names its two handles ("Click or drag to show more above" /
    ## "… below") and how VS Code's diff reads.
    dedAbove
    dedBelow

  DiffExpandCommand* = object
    ## One offer of the boundary's context menu.
    label*: string
    direction*: DiffExpandDirection
    lines*: int
      ## How many lines the command reveals.  For ``wholeFile`` this is every
      ## line still hidden in that direction, so a host can pass it straight to
      ## ``showMoreAbove`` / ``showMoreBelow`` without a second rule.
    wholeFile*: bool
      ## "…and the whole file in this direction" — the owner's second menu
      ## item.  It is a flag as well as a count so a caller can name it
      ## differently (and so a test can tell "reveal 137" from "reveal
      ## everything, which happens to be 137").

proc directionWord*(direction: DiffExpandDirection): string {.noSideEffect.} =
  case direction
  of dedAbove: "above"
  of dedBelow: "below"

proc expansionMenuCommands*(direction: DiffExpandDirection;
                            hiddenLines: int): seq[DiffExpandCommand]
                            {.noSideEffect.} =
  ## The menu for one boundary, given how many lines it is still hiding.
  ##
  ## An offer is made only when it would reveal something the *next* offer does
  ## not already cover: with 30 lines hidden, "Expand 50 lines" and "Expand all
  ## 30 lines" are two names for one action, and a menu that lies about what it
  ## does is worse than a shorter menu.  With nothing hidden there is no menu
  ## at all — the same rule the pre-UD-2 control followed when it stopped
  ## rendering itself once expansion was exhausted.
  result = @[]
  if hiddenLines <= 0:
    return
  let word = directionWord(direction)
  if hiddenLines > DiffExpandStep:
    result.add(DiffExpandCommand(
      label: "Expand " & $DiffExpandStep & " lines " & word,
      direction: direction, lines: DiffExpandStep))
  if hiddenLines > DiffExpandLargeStep:
    result.add(DiffExpandCommand(
      label: "Expand " & $DiffExpandLargeStep & " lines " & word,
      direction: direction, lines: DiffExpandLargeStep))
  result.add(DiffExpandCommand(
    label: "Expand all " & $hiddenLines & " lines " & word,
    direction: direction, lines: hiddenLines, wholeFile: true))

proc expansionActionLabel*(direction: DiffExpandDirection): string
    {.noSideEffect.} =
  ## The accessible name of the boundary's drag handle.
  ##
  ## A drag-only control excludes people outright, so the handle is a focusable
  ## button and this is what a screen reader announces when it reaches one.  It
  ## names the amount a plain press reveals and the modifier that takes the
  ## rest, because those are the two things a reader cannot discover by looking
  ## at a 4-pixel bar.
  "Show " & $DiffExpandStep & " more lines " & directionWord(direction) &
    " (Enter); all remaining lines " & directionWord(direction) &
    " (Shift+Enter); more choices (Shift+F10)"

proc expansionBoundaryTitle*(direction: DiffExpandDirection;
                             hiddenLines: int): string {.noSideEffect.} =
  ## The hover tooltip.  Monaco's own is "Click or drag to show more above",
  ## which says how but not how much; this keeps the gesture and adds the
  ## amount, because "how many lines am I hiding" is the question a reader
  ## actually has at a collapsed boundary.
  let word = directionWord(direction)
  if hiddenLines <= 0:
    return "Show more lines " & word
  "Click or drag to show more " & word & " — " & $hiddenLines &
    " line" & (if hiddenLines == 1: "" else: "s") & " hidden"
