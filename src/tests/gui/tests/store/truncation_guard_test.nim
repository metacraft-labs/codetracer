## truncation_guard_test.nim
##
## Headless tests for `file_conflicts.classifyWrite` — the rule that stops a
## save emptying a stored file that nobody emptied.
##
## Reported: *"when I enter a debug sesion and hit the Stop button, the contents
## of some files become empty. What's worse is that this seems to be persisted
## even after I refresh the tab. It's cleared only when I clear the browser data
## for the web-site (e.g. when I launch a fresh incognito session)."*
##
## The durable half is a two-step. `renderer.dispatchSaveEffect` reads the file
## from `tab.monacoEditor.getValue()`; a mode transition destroys the editor's
## pane and another rebuilds it, so the instance answering may be one that never
## held the file, and it answers `""`. That empty string was written through to
## OPFS, and the next load read it back. Clearing site data appears to fix it
## only because it re-seeds the bundled template — nothing is recovered.
##
## WHY THIS IS NOT A LENGTH HEURISTIC. Emptying a file is a legitimate action; a
## rule that forbade writing an empty file would be a new defect, and one the
## user would report as "I cannot clear a file". The guard is provenance the
## wipe cannot forge: Monaco's `getVersionId()` starts at 1 for a model nobody
## has modified and rises on every edit. A user who deleted a file's contents
## made at least one edit doing it. A model that was constructed empty and never
## typed into has made none, and no arrangement of panes can give it one.
##
## THE CONTROL-DATA RUN. The pre-fix behaviour — write whatever you are given —
## is carried rather than deleted:
##
##     nim c -r -d:ctSaveWritesAnything \
##       --path:src src/tests/gui/tests/store/truncation_guard_test.nim
##
## Nothing in the product defines that symbol.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/store/truncation_guard_test.nim

import std/[strutils, unittest]

import ../../../../frontend/file_conflicts

suite "truncation is not a save unless somebody truncated it":

  test "THE WIPE: an empty payload from a buffer that was never edited":
    # The reported defect. A rebuilt editor's model is empty and has version 1,
    # because nothing has ever modified it. There is no user action behind this
    # emptiness, and writing it through destroys work durably.
    check classifyWrite(BufferProvenance(
      contentLength: 0, editsSinceLoad: UneditedModelVersion)) ==
      tvRefuseUnproven

  test "A USER WHO CLEARED A FILE IS STILL ALLOWED TO":
    # The other half, and the reason this cannot be a rule about length.
    # Select-all-and-delete is one edit, so the version id has moved off 1 —
    # which is exactly the evidence a rebuilt buffer cannot produce.
    check classifyWrite(BufferProvenance(
      contentLength: 0, editsSinceLoad: UneditedModelVersion + 1)) == tvWrite

  test "a buffer that could not be asked may not truncate":
    # `dispatchSaveEffect` reports `-1` when the model cannot be reached, and a
    # host that receives a message with no `bufferEdits` field reads the same.
    # Unproven is unproven: a save path that has not been taught to answer this
    # question must not be able to delete a file by omission.
    check classifyWrite(BufferProvenance(
      contentLength: 0, editsSinceLoad: -1)) == tvRefuseUnproven

  test "non-empty content is never refused, however little the buffer can prove":
    # THE GUARD MUST NOT BECOME A SECOND WAY TO LOSE WORK. Everything the user
    # actually typed is written, whatever the provenance says — the rule is
    # about emptiness alone, and a refusal on any other axis would be a save
    # path that silently drops edits.
    for edits in [-1, 0, UneditedModelVersion, UneditedModelVersion + 1, 9999]:
      for length in [1, 2, 4096]:
        check classifyWrite(BufferProvenance(
          contentLength: length, editsSinceLoad: edits)) == tvWrite

  test "the refusal names the file and says the stored copy is untouched":
    # A refusal the user cannot understand is a bug report. It has to say which
    # file, that nothing was lost, and how to empty the file if that was
    # genuinely the intent — otherwise the guard reads as the product refusing
    # to save.
    let sentence = refusalSentence("src/main.nr")
    check "src/main.nr" in sentence
    check "unchanged" in sentence
    check "empty" in sentence
