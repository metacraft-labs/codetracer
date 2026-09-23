## edit_arm.nim — PLAT-44: the GPUI editor WRITES the editing core.
##
## PLAT-34 left GPUI reading the one editing core and unable to write it,
## because the renderer delivered no key (`PLAT21-VG1`) and had no element
## focus (`PLAT21-VG3`). PLAT-38 closed both. This module is what consumes
## them: one open `EditingDocument` — the same value the terminal's
## `EditBuffer` holds — and ONE route from a GPUI keystroke into it:
##
##   GPUI `keystroke.key` + modifiers
##     → `gpui_keys.canonicalKeyOfGpui`           (the product's key names)
##     → `editing_core.applyKey(editScopeOf(doc))` (the call the terminal makes)
##
## There is no second dispatch. The scope is `editing_core.editScopeOf`, the
## rule the terminal's `edit_binding.editingScope` also calls, so the two
## front-ends cannot disagree about whether a printable key is text.
##
## ## SAVING IS A HOST INTENT
##
## The core names `save` as an intent the host performs
## (`operations.HostIntentKind.hiSave`). Vim and Kakoune bind it to `Ctrl+s`;
## the product default binds nothing, so an unclaimed `Ctrl+s` is the product
## default's save. Either way the WRITE is this module's, through the same
## project writer the terminal's `:w` uses (`tui/host/edit_host
## .writeProjectFile` — a filesystem helper with no terminal in it).
##
## ## READ-ONLY IS STILL REFUSED
##
## Nothing here reaches `commitChange` or edits `doc.state.doc`: every change
## goes through `applyKey`, which is where the transaction filters run. A
## document whose filters refuse a change stays unchanged, and
## `test_gpui_edit_arm.nim` asserts that from this arm (PLAT-34 took the other
## route once, and a read-only buffer accepted a keystroke).

import codetracer_embed

import ../../view_vocabulary/editor_surface
import ./leaves   # `GpuiMedium`
import ../../tui/host/edit_host
import ./gpui_keys

export gpui_keys

type
  GpuiEditArm* = ref object
    root*: string
      ## The project directory.
    path*: string
      ## The open file, relative to `root`.
    doc*: EditingDocument
    loadedText*: string
      ## The bytes last read from or written to disk; the buffer is dirty when
      ## it differs.
    status*: string
      ## The last thing the arm has to say — `wrote <path>`, a save failure,
      ## an unrecognised key. Drawn as the surface's notice.
    keys*: int
      ## Keystrokes that decoded to a canonical name and reached the core.
    changes*: int
      ## Of those, how many changed the document.
    saves*: int
    viewportTop*: int
      ## The first line the pane shows. Follows the caret with the minimal
      ## scroll every front-end uses (`editing_core.followedViewportTop`);
      ## until this field existed the GPUI pane always showed line 1, so a
      ## caret moved below the fold edited text nobody could see.
    viewportRows*: int
      ## The pane's height in rows, set by the host from its window size.

  GpuiKeyResult* = object
    name*: string
      ## The canonical name, or "" when the keystroke has none.
    outcome*: EditingOutcome
    saved*: bool

const
  SaveKey* = "Ctrl+s"
  SaveOperation* = "save"

proc newGpuiEditArm*(root, path, text: string;
                     model = kmProductDefault): GpuiEditArm =
  GpuiEditArm(root: root, path: path,
              doc: initEditingDocument(path, text, model),
              loadedText: text, status: "", viewportTop: 1,
              viewportRows: DefaultViewportRows)

proc text*(arm: GpuiEditArm): string = arm.doc.state.doc

proc isDirty*(arm: GpuiEditArm): bool = arm.text != arm.loadedText

proc save*(arm: GpuiEditArm): bool =
  ## Write the buffer through the project writer. `status` says what happened.
  try:
    writeProjectFile(arm.root, arm.path, arm.text)
    arm.loadedText = arm.text
    inc arm.saves
    arm.status = "wrote " & arm.path
    true
  except CatchableError as e:
    arm.status = "could not write " & arm.path & ": " & e.msg
    false

proc applyCanonicalKey*(arm: GpuiEditArm; name: string;
                        nowMs: int64): GpuiKeyResult =
  ## One canonical key into the core — THE route, whichever front-end the key
  ## came from. Exported so a headless run can drive the same path.
  result.name = name
  if name.len == 0:
    result.outcome = eoIgnored
    return
  inc arm.keys
  let applied = arm.doc.applyKey(editScopeOf(arm.doc), name, nowMs)
  result.outcome = applied.outcome
  if applied.outcome == eoChanged:
    inc arm.changes
  arm.viewportTop = followedViewportTop(arm.viewportTop, caretLine(arm.doc),
                                        arm.viewportRows)
  if SaveOperation in applied.operations or
     (name == SaveKey and applied.outcome == eoIgnored):
    result.saved = arm.save()

proc applyGpuiKey*(arm: GpuiEditArm; key: string; modifiers: openArray[string];
                   nowMs: int64): GpuiKeyResult =
  ## One GPUI keystroke: decoded, then `applyCanonicalKey`.
  let name = canonicalKeyOfGpui(key, modifiers)
  if name.len == 0:
    arm.status = "no key name for GPUI keystroke '" & key & "'"
    return GpuiKeyResult(name: "", outcome: eoIgnored)
  arm.applyCanonicalKey(name, nowMs)

proc surfaceOf*(arm: GpuiEditArm; viewportHeight: int): EditorSurface =
  ## The editor surface for the CURRENT document — writable, so no read-only
  ## notice — with the caret shown, scrolled to keep it visible. `status`,
  ## when set, is the notice.
  arm.viewportRows = viewportHeight
  arm.viewportTop = followedViewportTop(arm.viewportTop, caretLine(arm.doc),
                                        viewportHeight)
  result = editorSurfaceForDocument(
    d = arm.doc, medium = GpuiMedium, mutableHere = true,
    viewportTop = arm.viewportTop, viewportHeight = viewportHeight,
    showCaret = true)
  if arm.status.len > 0 and result.notice.len == 0:
    result.notice = arm.status
