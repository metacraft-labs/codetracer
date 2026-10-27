## base_keymaps.nim — THE FOUR SHIPPED BASES, by name.
##
## Owns: `keymapOf(base)` — each base's whole definition, every table:
## CUA's and Emacs's data (`cua_keymap`, `emacs_keymap`), and Vim's and
## Kakoune's editor tables (PLAT-31's `vim_keymap`, `kakoune_keymap`) joined by
## the navigation table they share (`navigation_keymap`, CodeTracer-TUI.md
## §4.2).
##
## Refuses to own: any row, and resolution.
##
## Each definition is built ONCE, the first time it is asked for — at
## start-up only the selected base is, which is the front-end's cold start
## (CTUI-11's first-frame budget); a row the builder cannot read RAISES there,
## by name — a base with a bad row does not load (`base_rows.definitionOf`),
## and the base-keymap suites load all four.

import ./base_rows
import ./cua_keymap
import ./editing_keymap
import ./emacs_keymap
import ./kakoune_keymap
import ./navigation_keymap
import ./vim_keymap

proc withNavigation(def: KeymapDefinition): KeymapDefinition =
  ## A modal base's editor table, joined by §4.2's navigation table. The
  ## navigation rows are checked as a base of their own first, so a conflict
  ## among them refuses the base exactly as a data base's would.
  result = def
  let nav = definitionOf(def.model, NavigationRows & ModalSurfaceRows)
  for b in nav.keymap.bindings:
    result.keymap.bindings.add b

proc buildBase(model: BaseKeymap): KeymapDefinition =
  ## **ONE `case`, total over the enum**, so a fifth base does not compile
  ## rather than resolving to the default and looking like it works.
  case model
  of bkCua: definitionOf(bkCua, CuaRows)
  of bkEmacs: definitionOf(bkEmacs, EmacsRows)
  of bkVim: withNavigation(vimKeymap())
  of bkKakoune: withNavigation(kakouneKeymap())

var
  definitions: array[BaseKeymap, KeymapDefinition]
  built: array[BaseKeymap, bool]

proc keymapOf*(model: BaseKeymap): KeymapDefinition =
  ## The four shipped bases, by name, each built on its first request.
  if not built[model]:
    definitions[model] = buildBase(model)
    built[model] = true
  definitions[model]
