## PLAT-44 — the plan the window lane types: for each of PLAT-34's thirty
## sequences that a key reaches, the model, the document, the canonical keys
## and the document the keys must leave on disk.
##
## Run (`just plat44-sequences-plan`):
##   nim c -r --path:src/frontend/viewmodel ci/test/plat44_sequences_plan.nim
##
## The keys come from `plat44_translation.translateAny`, the SAME translation
## `test_plat44_sequences.nim` drives through the binary headlessly, and the
## expected document from applying them to the core — so the window lane and
## the headless suite cannot be about two different key routes. Writes
## `build/plat44-sequences/plan.json`; `ci/test/plat44-sequences-window.sh`
## types it.

import std/[json, os]

import codetracer_embed
import ../../src/frontend/gpui/tests/plat44_translation

const Out = "build/plat44-sequences/plan.json"

proc main() =
  let docs = scenarioDocs()
  let seqs = operationSequences()
  var entries = newJArray()
  var unreachable = newJArray()
  for s in seqs:
    let d = docs[s.docIndex]
    let t = translateAny(s, d)
    if not t.ok:
      unreachable.add %*{"id": s.id, "missing": t.missing}
      continue
    let keys = t.arrange & t.keys
    var expected = initEditingDocument(ProjectFile, d.text, t.model)
    var now = 0'i64
    expected.applyAll(keys, now)
    # What the keys WITHOUT their last one leave — so the lane's negative
    # twin can be a sequence whose last key demonstrably changes something.
    var short = initEditingDocument(ProjectFile, d.text, t.model)
    var now2 = 0'i64
    short.applyAll(keys[0 ..< keys.len - 1], now2)
    let lastKeyMatters =
      short.state.doc != expected.state.doc or
      caretLine(short) != caretLine(expected) or
      caretColumn(short) != caretColumn(expected)
    entries.add %*{
      "id": s.id,
      "model": $t.model,
      "modal": t.model != kmProductDefault,
      "doc": d.text,
      "keys": keys,
      "expected": expected.state.doc,
      "expectedCaretLine": caretLine(expected),
      "expectedCaretColumn": caretColumn(expected),
      "lastKeyMatters": lastKeyMatters,
    }
  createDir(Out.parentDir)
  writeFile(Out, (%*{"corpus": seqs.len, "sequences": entries,
                      "unreachable": unreachable}).pretty & "\n")
  echo "wrote ", Out, ": ", entries.len, " of ", seqs.len, " sequences"

main()
