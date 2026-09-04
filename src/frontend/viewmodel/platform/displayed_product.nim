## What THIS running instance calls itself, for the surfaces that show the
## product's name to a user.
##
## ## The defect this module exists to close
##
## The name was a literal, in the one place that emits the served document:
##
##     <title>CodeTracer &mdash; Noir Studio</title>
##
## One deployment serves three addresses — `ide.codetracer.com/`,
## `ide.codetracer.com/noir` and `noirstudio.dev` — from one Pages project and
## one entry document, so that string is the title of all three. The
## language-neutral root therefore called itself Noir Studio, and a bookmark
## taken there carried the other product's name. There was no branch to fix,
## because there was nothing anywhere that answered "which product is this".
##
## `web_entry.productNameFor` is that answer now, and it hangs off the row that
## already decides the question (`knownLanguageEntries`). This module is the
## other half: the name has to reach `document.title`, and the two writers of
## the title are on opposite sides of a platform boundary.
##
## ## Why a pushed module-level value, and not a parameter
##
## `displayed_build_identity.nim` is the same shape for the same reason, and
## its header makes the argument in full. The short version: the product's name
## is a property of the INSTANCE, not of any session, panel or document, so
## threading it through the view models would put a constant into reactive
## graphs that can never observe it change.
##
## The specific difficulty here is that `ui_js.traceLoaded` sets the title and
## is compiled for BOTH platforms. It cannot ask the web for the answer,
## because on the desktop there is no location to ask; and it cannot hardcode
## the answer, because that is the defect. So the web arm pushes once, at the
## point it already resolved the entry, and the desktop pushes nothing.
##
## ## The default is the desktop's correct answer
##
## `neutralProductName` — "CodeTracer". An Electron build is never served from
## a language entry point and never will be, so the desktop is correct without
## writing a line, and a web arm that somehow failed to push falls back to the
## deployment's own canonical origin rather than to an empty title.

import ./web_entry

var displayed = neutralProductName

proc setDisplayedProductName*(name: string) =
  ## Called once, by the arm that resolved which entry point this is.
  ##
  ## Empty is ignored rather than stored. A caller with nothing to say must
  ## leave the neutral name in place: a blank title is not a smaller mistake
  ## than a wrong one, it is a page that names no product at all.
  if name.len > 0:
    displayed = name

proc displayedProductName*(): string =
  ## What to call the product on this instance. Never empty.
  displayed

proc sessionDocumentTitle*(program, productName: string): string =
  ## The tab's title while a recording is open, and therefore the name any
  ## bookmark of it keeps.
  ##
  ## ## What it no longer says
  ##
  ## It was `CodeTracer | Trace <recordingId>: <program>`, and every clause of
  ## that was wrong for a bookmark. The product name was a literal, so a Noir
  ## Studio session filed itself under CodeTracer. `Trace` is what this codebase
  ## calls a recording, not what a reader calls one. And `recordingId` is a
  ## UUIDv7 — 36 characters of nothing, in front of the only word the reader
  ## came for, in a field that is truncated from the right.
  ##
  ## ## Why the program leads
  ##
  ## A browser tab shows the first few characters and a bookmark list shows the
  ## first few more. Leading with the product name makes every session in the
  ## list identical until the truncation point; leading with the program makes
  ## the list readable, which is what a bookmark is for.
  ##
  ## A pure function of two strings, so the composition is testable without a
  ## DOM and without the global above.
  if program.len == 0: productName
  else: program & " — " & productName
