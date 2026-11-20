## A terminal's late start-up answer rewrites the status line only while the
## line still shows the capability note.
##
## codetracer-pm issue 2026-11-18, "A late start-up answer replaces the
## corrupt-layout note on the terminal's status line": in CI run 44269676398
## the status line read `bg: flag -> dark` 1.09 s after start, where the
## first frame had said `saved layout ignored (NotJson): …`. The late answer
## re-decided the capabilities and wrote its note over a message the user had
## not read yet.

import std/unittest

import ../app/capability_note

const
  StartNote = "bg: default -> dark"
  LateNote = "bg: osc11 #ffffff -> light"
  LayoutRefusal = "saved layout ignored (NotJson): input(1, 6) Error: string " &
                  "literal as key expected — this session uses the default"

suite "the status line keeps a message a late answer did not write":

  test "a late answer replaces the start-up note it follows":
    var slot: CapabilityNoteSlot
    let first = slot.startupNote(StartNote, " | opening /trace …")
    check first == StartNote & " | opening /trace …"
    let (write, text) = slot.lateNote(first, LateNote)
    check write
    check text == LateNote

  test "a refused saved layout written after the start-up note stays":
    var slot: CapabilityNoteSlot
    discard slot.startupNote(StartNote, " | opening /trace …")
    # The layout store's refusal is written after the start-up frame.
    let (write, text) = slot.lateNote(LayoutRefusal, LateNote)
    check not write
    check text == LayoutRefusal

  test "a second late answer replaces the first one's note":
    var slot: CapabilityNoteSlot
    let first = slot.startupNote(StartNote, "")
    let (_, second) = slot.lateNote(first, LateNote)
    let (write, text) = slot.lateNote(second, "bg: osc11 #000000 -> dark")
    check write
    check text == "bg: osc11 #000000 -> dark"

  test "an empty line takes the note; another message does not, without a start-up note":
    # Edit mode writes no start-up note.
    var slot: CapabilityNoteSlot
    let (write, text) = slot.lateNote("", LateNote)
    check write
    check text == LateNote
    var editSlot: CapabilityNoteSlot
    let (kept, same) = editSlot.lateNote("saved 3 files", LateNote)
    check not kept
    check same == "saved 3 files"
