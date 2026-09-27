## gpui/layout_memory.nim — PLAT-45 deliverable 8, the GPUI window's half.
## **The file the GPUI product remembers its last layout in, and the only thing
## in this front-end that opens it.**
##
## Every product opens with the one shared default
## (`layout_model.sharedDefaultLayout()`); after that each is free, and each
## remembers ITS OWN last arrangement in a file that belongs to it alone:
##
##   * the desktop — its GoldenLayout config under `$XDG_CONFIG_HOME/codetracer/`;
##   * the terminal — `<state root>/tui-layout.json` (`tui/host/layout_store`);
##   * this window — `<state root>/gpui-layout.json`, BESIDE the terminal's
##     (one state root, `viewmodel/host/native_state`), and never the same file.
##
## None reads another's: a layout arranged in the terminal does not change the
## GPUI window's next start, and vice versa.
##
## ## The rules, the terminal's (PLAT-6) applied to a window
##
##   * **absent** → the shared default, and nothing to say;
##   * **readable** → that arrangement;
##   * **unreadable** (not JSON, empty, a schema or pane this build does not
##     know, or a file that will not open) → the shared default, the failure
##     REPORTED by kind, and the file LEFT ALONE — a document written by a newer
##     build must survive an older one being opened once;
##   * **a committed change** (`--layout-ops`, the window's scripted gesture
##     until PLAT-23 binds keys to layout commands) → written through, staged
##     at `<path>.new` and renamed, so a crash loses nothing;
##   * **reset** (`--reset-layout`) → the file is deleted and the shared
##     default returns. Only THIS product's file.
##
## No gesture, no document: a run that changed nothing writes nothing, so the
## shared default is never frozen into a file the user did not ask for.

import std/[json, os, strutils]

import headless_app/layout_model
import ../viewmodel/host/native_state

const
  GpuiLayoutFileName* = "gpui-layout.json"
    ## The GPUI product's document, directly under the native state root —
    ## beside the terminal's `tui-layout.json` and never the same name.

type
  GpuiRestoreStatus* = enum
    grsNoDocument = "no-document"
    grsRestored = "restored"
    grsUnreadable = "unreadable"

  GpuiLayoutRestore* = object
    status*: GpuiRestoreStatus
    layout*: Layout
      ## The arrangement to open with: the restored one, or the shared
      ## default for the other two statuses.
    path*: string
    kind*: string
      ## The failure's name for `grsUnreadable` (`NotJson`, `EmptyDocument`,
      ## `UnreadableFile`, or a `LayoutDecodeErrorKind`), else "".
    message*: string
      ## Never empty for `grsUnreadable`; the KIND first, the path last.

proc gpuiLayoutDocumentPath*(): string =
  nativeStateRoot() / GpuiLayoutFileName

proc sharedDefaultValue*(): Layout =
  ## The shared default at depth 0 — this front-end has no minimum-size
  ## contract in pixels, so it never folds (PLAT-45 deliverable 6).
  initLayout(sharedDefaultLayout().tree)

proc unreadable(path, kind, why: string): GpuiLayoutRestore =
  GpuiLayoutRestore(
    status: grsUnreadable, layout: sharedDefaultValue(), path: path,
    kind: kind,
    message: "saved layout ignored (" & kind & "): " & why &
      " — this window is on the shared default and the file was left " &
      "alone: " & path)

proc restoreGpuiLayout*(): GpuiLayoutRestore =
  ## Read the GPUI product's remembered arrangement.
  let path = gpuiLayoutDocumentPath()
  if not fileExists(path):
    return GpuiLayoutRestore(status: grsNoDocument,
                             layout: sharedDefaultValue(), path: path)
  var text = ""
  try:
    text = readFile(path)
  except CatchableError as e:
    return unreadable(path, "UnreadableFile", e.msg.splitLines()[0])
  if text.strip().len == 0:
    return unreadable(path, "EmptyDocument", "the file is empty")
  var doc: JsonNode = nil
  try:
    doc = parseJson(text)
  except CatchableError as e:
    return unreadable(path, "NotJson", e.msg.splitLines()[0])
  try:
    let layout = restoreLayoutDocument(doc)
    let problems = validate(layout, {})
    if problems.len > 0:
      return unreadable(path, $problems[0].kind,
                        "the arrangement does not validate")
    GpuiLayoutRestore(status: grsRestored, layout: layout, path: path)
  except LayoutDecodeError as e:
    unreadable(path, $e.kind, e.msg.splitLines()[0])

proc saveGpuiLayout*(layout: Layout): string =
  ## Write the arrangement through. "" on success, else a one-line message.
  writeStaged(gpuiLayoutDocumentPath(), pretty(saveLayout(layout)) & "\n")

proc saveGpuiLayoutDocument*(doc: JsonNode): string =
  ## `saveGpuiLayout` for a caller already holding the versioned document
  ## (`GpuiShell.saveWindowLayout`'s answer).
  writeStaged(gpuiLayoutDocumentPath(), pretty(doc) & "\n")

proc resetGpuiLayout*(): string =
  ## Delete THIS product's file and nothing else. "" on success (including
  ## when there was nothing to delete), else a one-line message.
  let path = gpuiLayoutDocumentPath()
  try:
    if fileExists(path):
      removeFile(path)
    ""
  except CatchableError as e:
    path & ": " & e.msg

proc paneNamed(name: string): PaneKind =
  for k in PaneKind:
    if $k == name:
      return k
  raise newException(ValueError, "'" & name & "' is not a pane")

proc edgeNamed(name: string): LayoutEdge =
  for e in LayoutEdge:
    if $e == name:
      return e
  raise newException(ValueError, "'" & name & "' is not an edge")

proc parseLayoutOps*(spec: string): seq[LayoutCommand] =
  ## `--layout-ops=<spec>`: a comma-separated list of layout commands the
  ## window applies through `GpuiShell.applyIn` — the one door every
  ## arrangement change goes through — before it is drawn:
  ##
  ##   activate:<pane>          make a tab the visible one
  ##   dock:<pane>:<edge>       auto-hide a pane to left|right|top|bottom
  ##   merge:<pane>:<beside>    move a pane into another pane's tab stack
  ##   remove:<pane>            take a pane out of the arrangement
  ##
  ## The window's scripted GESTURE, for the reason `--replay-ops` exists: no
  ## key or pointer is bound to a layout command in this front-end yet
  ## (PLAT-23's `--ui=gui` contract), and "rearrange, quit, restart" must be
  ## drivable today. Raises `ValueError` naming the bad item.
  for item in spec.split(','):
    let parts = item.strip().split(':')
    if parts.len == 0 or parts[0].len == 0:
      raise newException(ValueError, "an empty layout operation")
    case parts[0]
    of "activate":
      if parts.len != 2: raise newException(ValueError, "activate:<pane>")
      result.add cmdActivateTab(paneNamed(parts[1]))
    of "dock":
      if parts.len != 3: raise newException(ValueError, "dock:<pane>:<edge>")
      result.add cmdDock(paneNamed(parts[1]), edgeNamed(parts[2]))
    of "merge":
      if parts.len != 3: raise newException(ValueError, "merge:<pane>:<beside>")
      result.add cmdMergeIntoStack(paneNamed(parts[1]), paneNamed(parts[2]))
    of "remove":
      if parts.len != 2: raise newException(ValueError, "remove:<pane>")
      result.add cmdRemovePane(paneNamed(parts[1]))
    else:
      raise newException(ValueError, "'" & parts[0] &
        "' is not a layout operation (activate, dock, merge, remove)")
