## A measured width, read from the layout only when it may have changed.
##
## Reading an element's `clientWidth` forces the browser to finish layout
## first. The session tab bar read its width on every render to fit its tabs,
## and it renders on every `data.redraw()` (through the menu's repair cascade),
## so each redraw forced a layout of everything the redraw had just written:
## 327 ms of the renderer's time in one call-trace jump on a loaded host,
## before the new editor mounted.
##
## The width is kept between renders and read again only after something
## that can change it: a resize the caller observes, which calls
## `invalidate`. A width of 0 (the host not laid out yet) is not kept.
##
## No imports, so it compiles on both backends and is unit-tested headlessly
## (`src/tests/gui/tests/session-chrome/measured_width_test.nim`).

type
  MeasuredWidth* = object
    width: int
    valid: bool
    reads*: int
      ## How many times the layout was read: a work counter for the test.

proc invalidate*(measured: var MeasuredWidth) =
  ## Something that can change the width happened (a resize).
  measured.valid = false

proc widthOf*(measured: var MeasuredWidth; read: proc(): int): int =
  ## The width, reading it from the layout (`read`) only if it is not known.
  if not measured.valid:
    measured.width = read()
    inc measured.reads
    measured.valid = measured.width > 0
  measured.width
