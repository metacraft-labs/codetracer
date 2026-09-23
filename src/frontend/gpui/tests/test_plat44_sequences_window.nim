## PLAT-44 — PLAT-34's operation sequences TYPED INTO A REAL WINDOW, from the
## committed record.
##
## Run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_plat44_sequences_window.nim
##
## `src/tests/visual/plat44-sequences-window.json` is measured by
## `ci/test/plat44-sequences-window.sh`: each sequence a key reaches is typed
## by `wtype` into a real `codetracer-gpui --edit` window on a headless sway,
## saved, and the window ended by its sentinel. This suite reads no binary and
## no compositor; it asserts over the record, against the corpus and the
## translation it recomputes itself:
##
##   * the typed set is EXACTLY the set a key reaches — recomputed here from
##     PLAT-34's corpus with the same translation — and the unreachable rest
##     is recorded by name, so thirty is accounted for (§34b: the realised
##     set, not a count);
##   * every typed sequence left the plan's document ON DISK and the plan's
##     caret in the binary's own exit report (a motion-only sequence leaves
##     the file unchanged, so the file alone would pass it for doing nothing);
##   * every run ended on its sentinel, not the backstop;
##   * the NEGATIVE TWIN — a sequence whose last key matters, typed without
##     it — did NOT reproduce the expected state.
##
## No mocks: the record is a measurement of the shipped binary in a window.

import std/[json, os, sets, unittest]

import ./plat44_translation

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let recordPath = repo / "src/tests/visual/plat44-sequences-window.json"

proc rec(): JsonNode = parseJson(readFile(recordPath))

proc reachedExactly(r: JsonNode): bool =
  r["onDisk"].getStr == r["expected"].getStr and
    r["caretLine"].getInt == r["expectedCaretLine"].getInt and
    r["caretColumn"].getInt == r["expectedCaretColumn"].getInt

suite "PLAT-44: the thirty, typed into a window":

  test "the record is present and provenanced":
    ck fileExists(recordPath)
    ck rec()["takenAt"].getStr.len > 0
    ck rec()["host"].getStr.len > 0

  test "the typed set is exactly the set a key reaches, and thirty are accounted for":
    let docs = scenarioDocs()
    let seqs = operationSequences()
    var reachable, unreachable = initHashSet[string]()
    for s in seqs:
      if translateAny(s, docs[s.docIndex]).ok: reachable.incl s.id
      else: unreachable.incl s.id
    var typed, named = initHashSet[string]()
    for r in rec()["sequences"]: typed.incl r["id"].getStr
    for u in rec()["unreachable"]: named.incl u["id"].getStr
    ck rec()["corpus"].getInt == OperationSequenceCardinality
    ck typed == reachable
    ck named == unreachable
    ck typed.len + named.len == OperationSequenceCardinality

  for r in rec()["sequences"]:
    let id = r["id"].getStr
    test "typed, saved and read back: " & id & " (" & r["model"].getStr & ")":
      checkpoint("keys " & $r["keys"] & " | caret " & $r["caretLine"] & ":" &
                 $r["caretColumn"] & " want " & $r["expectedCaretLine"] & ":" &
                 $r["expectedCaretColumn"])
      ck r["rc"].getInt == 0
      ck not r["endedOnDeadline"].getBool
      ck r["keysApplied"].getInt >= r["keys"].len
      ck r["onDisk"].getStr == r["expected"].getStr
      ck r["caretLine"].getInt == r["expectedCaretLine"].getInt
      ck r["caretColumn"].getInt == r["expectedCaretColumn"].getInt

  test "the NEGATIVE TWIN — the last key left out — does not reproduce it":
    let t = rec()["negativeTwin"]
    ck t["dropped"].getInt == 1
    ck t["rc"].getInt == 0
    ck not reachedExactly(t)

suite "PLAT-44 sequences window — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
