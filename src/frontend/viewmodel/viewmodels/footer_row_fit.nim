## viewmodels/footer_row_fit.nim
##
## How the status line's own words share its row: the note (what a key just
## did), the location and the certificate label. The rule lives here, in the
## viewmodel layer, so every front-end reads one copy of it: the GPUI window
## draws its status bar with it (`gpui/window_geometry.nim` re-exports it),
## and the sessions bar (`sessions_bar_fit.statusBarBarArea`) takes only the
## room the status line's words leave, on the web and in the terminal as in
## GPUI.
##
## Pure: integers in, integers out, in the caller's unit (pixels or cells).

type FooterRowFit* = tuple[note, location, certificate: int]
  ## How wide the status bar's note, location and certificate label are
  ## drawn (`fitFooterRow`); a certificate of 0 is left out.

proc fitFooterRow*(available, noteW, locationW, locationFloorW,
                   certificateW: int): FooterRowFit =
  ## The status bar's note, its location and its certificate label share
  ## `available` pixels: the row from the note's start to the copy button,
  ## less the gap between the note and what follows it. `certificateW`
  ## includes the label's own gap, and is 0 when there is no label.
  ## `locationFloorW` is the least the location is cut to: its shortest
  ## middle cut, the file name with its line and ticks (`…/main.py:12#345`).
  ##
  ## The note keeps its words first: a note says what a key just did, and is
  ## read once. So when the row cannot hold all three whole:
  ##   1. the location gives way, cut in its middle by the shared path rule
  ##      (`cut_text_rules.pathCutCandidates`), down to its floor;
  ##   2. then the certificate label is left out, whole, while the note
  ##      needs its room;
  ##   3. only then, with the location at its floor, is the note cut.
  ## A location narrower than its floor is never widened, and nothing is
  ## ever negative. The row stays one line.
  let room = max(0, available)
  let cert = max(0, certificateW)
  if noteW + locationW + cert <= room:
    return (note: noteW, location: locationW, certificate: cert)
  let floor = min(locationW, max(0, locationFloorW))
  if noteW + floor + cert <= room:
    return (note: noteW, location: min(locationW, room - noteW - cert),
            certificate: cert)
  let location = min(room, min(locationW, max(floor, room - noteW)))
  (note: max(0, min(noteW, room - location)), location: location,
   certificate: 0)
