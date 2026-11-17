## source_revisions_across_recordings_test.nim
##
## A RECORDING THAT REPLACES ANOTHER IN A TAB SHOWS ITS OWN SOURCE.
##
## The editor service keeps the text a file had when a recording ran, keyed
## by path, source generation and digest, so that saving a file while its
## recording is open does not swap the recording's source for the new text
## (`renderer.reloadOpenFileFromDisk` stores the open tab's text under the
## current stop before the disk changes). A fresh recording's stops carry
## generation 0 and no digest, so that key is the same for a stop in
## `main.py` in every recording of `main.py`.
##
## Ctrl+R saves the edited file and records it again into the same tab. The
## new recording's first stop found the OLD recording's text under its key
## and `ui/editor.applySourceRevisionForLocation` put it back into the
## editor, over the new source the tab had just loaded: the program ran the
## new code and the editor showed the old.
##
## `EditorService.forgetSourceRevisions` is what `ui_js.onTraceLoaded` calls
## with the replaced and the loaded recording's output folders. This suite
## drives the cache through its real API in the order the product does.
##
## Lane: `renderer-dom` (imports `utils.nim`, a renderer module).

import std/[unittest, jsffi]

import ../types
import ../utils
import ../lib/jslib

const ExpectedChecks = 6
var checks = 0
var failedChecks = 0
template ck(cond: untyped) =
  inc checks
  if not (cond):
    inc failedChecks
  check cond

template scenario(name: string; body: untyped) =
  block:
    let failedBefore = failedChecks
    body
    echo(if failedChecks == failedBefore: "  [OK] " else: "  [FAILED] ", name)

proc newEditorService(): EditorService =
  EditorService(
    open: JsAssoc[cstring, TabInfo]{},
    sourceRevisionCache: JsAssoc[cstring, cstring]{},
    pendingDiskSourceByPath: JsAssoc[cstring, cstring]{})

proc stopIn(path: cstring; line: int): types.Location =
  ## A stop of a fresh recording: no source generation, no digest.
  types.Location(path: path, highLevelPath: path, line: line,
                 highLevelLine: line)

const
  mainPy = cstring"/work/project/main.py"
  oldText = cstring"print('first')\n"
  newText = cstring"print('re-recorded marker')\n"

scenario "a re-recording does not inherit the replaced recording's source":
  let editor = newEditorService()
  # Saving while the first recording is open keeps its text for its stop.
  editor.cacheSourceRevision(stopIn(mainPy, 1), oldText)
  ck editor.hasSourceRevision(stopIn(mainPy, 1))
  editor.pendingDiskSourceByPath[mainPy] = newText
  # Ctrl+R: the new recording loads into the same tab.
  editor.forgetSourceRevisions(cstring"/traces/trace-1", cstring"/traces/trace-2")
  # Its first stop has the same key; nothing may answer it with the old text.
  ck not editor.hasSourceRevision(stopIn(mainPy, 1))
  ck editor.sourceRevisionSource(stopIn(mainPy, 1)) == cstring""
  ck not editor.pendingDiskSourceByPath.hasKey(mainPy)

scenario "reloading the same recording keeps the source it ran":
  let editor = newEditorService()
  editor.cacheSourceRevision(stopIn(mainPy, 1), oldText)
  editor.forgetSourceRevisions(cstring"/traces/trace-1", cstring"/traces/trace-1")
  ck editor.hasSourceRevision(stopIn(mainPy, 1))
  ck editor.sourceRevisionSource(stopIn(mainPy, 1)) == oldText

if checks != ExpectedChecks:
  echo "  [FAILED] every check ran: expected ", ExpectedChecks, ", ran ", checks
  inc failedChecks
echo "CHECKS: ", checks
if failedChecks > 0:
  {.emit: "process.exitCode = 1;".}
