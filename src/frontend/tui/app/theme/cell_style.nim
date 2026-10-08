## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/theme/cell_style.nim — what one cell carries, before and after the
## colour tier is decided.
##
## Moved here from `app/views/styled_row.nim` (which re-exports it, so every
## view reads it where it always did) because the ROLE fields below name
## `app/theme/roles.SemanticRole`, and `app/theme/palette.nim` — which a view's
## row encoder needs — resolves them. Neither may import a view.
##
## ## Two halves, one object
##
## A VIEW fills `role` and `surface` and never a colour: `role` is what the
## text means (a keyword, a muted caption, the active tab's label), `surface` is
## what the cell sits on (a pane body, the editor, the execution line). The
## attribute booleans may be set by a view too, for an attribute that is not a
## colour decision (a frame-viewer cursor's `reverse`, a placeholder's
## `italic`); they are OR-ed with the role's.
##
## `app/theme/degradation.degradeRows` then RESOLVES the roles onto the
## negotiated tier and hands the compositor `fg`/`bg` spellings (`#rrggbb`,
## `indexed:N`, an ANSI name, or "" for the terminal default) with the roles
## cleared. `fg`/`bg` set by a view are LITERAL colours that are content rather
## than chrome — the frame viewer's pixels — and are projected mechanically.

import std/strutils

import ./roles

export roles

type
  CellStyle* = object
    ## Everything one cell can carry that both tiers can observe.
    ##
    ## A value with `==` derived, because the row encoder groups adjacent cells
    ## by style equality and a hand-written comparison would be one more thing
    ## to keep true.
    role*: SemanticRole
      ## What the text in this cell MEANS. `srNone` for none.
    surface*: SemanticRole
      ## What this cell sits on. `srNone` means "not decided by the painter";
      ## the shell fills every cell of a pane body, the editor, a tab strip, the
      ## header and the status line with their surface role before any pane
      ## paints (`StyledGrid.fillSurface`), and a paint that names no surface
      ## keeps the one already there.
    fg*: string
      ## A LITERAL foreground — content, not chrome — or, after
      ## `degradeRows`, the resolved one. "" for the terminal default.
    bg*: string
    bold*: bool
    italic*: bool
    underline*: bool
    reverse*: bool

const DefaultCellStyle* = CellStyle()
  ## No role, no surface, the terminal's own colours and no attributes.

func isDefault*(s: CellStyle): bool =
  ## Whether this style asks the renderer for nothing at all.
  s == DefaultCellStyle

func attrNames*(s: CellStyle): seq[string] =
  ## The boolean attributes set on `s`, as the style names
  ## `compositor.styleFor` reads, in declaration order.
  result = @[]
  if s.bold: result.add "bold"
  if s.italic: result.add "italic"
  if s.underline: result.add "underline"
  if s.reverse: result.add "reverse"

func describe*(s: CellStyle): string =
  ## One line for a failure message. Never used to make a decision.
  var parts: seq[string] = @[]
  if s.role != srNone: parts.add "role=" & $s.role
  if s.surface != srNone: parts.add "surface=" & $s.surface
  parts.add "fg=" & (if s.fg.len > 0: s.fg else: "default")
  parts.add "bg=" & (if s.bg.len > 0: s.bg else: "default")
  let attrs = s.attrNames()
  parts.add "attrs={" & attrs.join(",") & "}"
  parts.join(" ")

func hasOwnBackground*(s: CellStyle): bool =
  ## Whether the cell paints a background of ITS OWN — a badge, a tag, a
  ## highlight — rather than sitting on its region's surface. A cursor's row
  ## highlight is applied only where this is false, so the one badge a row
  ## exists to show is never painted over.
  s.bg.len > 0 or spec(s.role).hasBg or
    (s.surface != srNone and not spec(s.surface).baseSurface)

func withSurface*(s: CellStyle; surface: SemanticRole): CellStyle =
  ## `s` on another surface. The execution line's highlight is applied this
  ## way — over the gutter's and the syntax highlighter's own roles — so "the
  ## current line is highlighted" does not throw away "this token is a string
  ## literal".
  result = s
  result.surface = surface

func withBackground*(s: CellStyle; surface: SemanticRole): CellStyle =
  ## The spelling CTUI-5's call sites use; a background is now a SURFACE role.
  withSurface(s, surface)
