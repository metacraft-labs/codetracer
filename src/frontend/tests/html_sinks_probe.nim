## The product half of `htmlSinks.test.mjs`.
##
## Compiled with `nim js` **without** `-d:nodejs` on purpose: with that switch
## karax's `kdom` binds to an in-memory DOM emulation, and a test of what
## `innerHTML` does would then be a test of the emulation.  Without it the
## generated code reaches for the browser globals, which the `.mjs` supplies
## from jsdom — so `innerHTML`, `textContent` and HTML parsing are the real
## ones.
##
## This file adds no logic of its own.  Every entry point below is a one-line
## call into the shipped code, published on `globalThis` so the `.mjs` can
## drive it.

import std/jsffi
import kdom
import ../types
import ../viewmodel/views/context_menu_bridge
import ../ui/file_conflict_dialog
import ../lib/ansi_html

proc setGlobal(name: cstring; value: js) {.importjs: "globalThis[#] = #;".}

# --- site 1: the file-conflict dialog ---------------------------------------

proc probeFileConflictOverlay(path: cstring): js =
  ## The shipped builder, verbatim.  Returns the element so the test can walk
  ## the DOM it actually produced rather than a string it re-parsed.
  toJs(buildFileConflictOverlay(path))

proc probeFileConflictMarkup(): cstring =
  cstring(FileConflictDialogMarkup)

# --- site 2: the context menu ------------------------------------------------

proc probeShowContextMenu(name: cstring; hint: cstring) =
  ## The shipped `showContextMenu` from `viewmodel/views/context_menu_bridge`,
  ## with one item.  It renders into `#context-menu-container`, which the test
  ## puts in the document first.
  showContextMenu(@[ContextMenuItem(name: name, hint: hint, handler: nil)], 0, 0)

# --- site 3: ansi_up ---------------------------------------------------------

proc probeAnsiToHtml(raw: cstring): cstring =
  ## The product's own converter, through the product's own constructor.
  ansiToHtml(newEscapingAnsiUp(), raw)

proc probeAnsiEscapeFlag(): bool =
  ## What `newEscapingAnsiUp` actually leaves the instance set to.
  cast[bool](newEscapingAnsiUp().escape_html.to(bool))

setGlobal(cstring"__ctFileConflictOverlay", toJs(probeFileConflictOverlay))
setGlobal(cstring"__ctFileConflictMarkup", toJs(probeFileConflictMarkup))
setGlobal(cstring"__ctShowContextMenu", toJs(probeShowContextMenu))
setGlobal(cstring"__ctAnsiToHtml", toJs(probeAnsiToHtml))
setGlobal(cstring"__ctAnsiEscapeFlag", toJs(probeAnsiEscapeFlag))
