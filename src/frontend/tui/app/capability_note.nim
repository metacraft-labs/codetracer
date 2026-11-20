## app/capability_note.nim — when a terminal's late answer may rewrite the
## status line.
##
## The status line holds one notification. The start-up frame writes the
## capability negotiation's note there (`bg: osc11 #1e1e2e -> dark`), and a
## terminal's answer that arrives after the start-up probe's bound re-decides
## the capabilities and writes the new note. That second write used to be
## unconditional, so it replaced whatever the line said by then. The message
## it replaced could be one the user had not read yet: a refused saved layout
## (`saved layout ignored (NotJson): …`), a refused setting, a refused
## column-width store (codetracer-pm issue 2026-11-18, "A late start-up answer
## replaces the corrupt-layout note on the terminal's status line").
##
## The rule here: a late answer rewrites the line only while the line still
## shows the capability note this session wrote last (or shows nothing). Any
## other message stays, and the re-decided note remains available from
## `:terminal-info` and `--capabilities`.

import std/strutils

type
  CapabilityNoteSlot* = object
    ## The capability note this session last wrote to the status line; ""
    ## before it wrote one.
    written*: string

proc startupNote*(slot: var CapabilityNoteSlot; note, rest: string): string =
  ## The start-up frame's notification: `note`, then `rest` (already
  ## starting with its own separator, or ""). Remembers `note`.
  slot.written = note
  note & rest

proc lateNote*(slot: var CapabilityNoteSlot; current, note: string):
    tuple[write: bool; text: string] =
  ## A late answer re-decided the capabilities and `note` describes them.
  ## Whether to replace `current`, the status line's notification, and with
  ## what: only when `current` is empty or is still the note this slot wrote
  ## (with whatever the start-up frame appended).
  let ours = current.len == 0 or
             (slot.written.len > 0 and current.startsWith(slot.written))
  if not ours:
    return (false, current)
  slot.written = note
  (true, note)
