## PLAT-44 — PLAT-34's operation sequences as KEYS: the one translation the
## headless suite (`test_plat44_sequences.nim`) and the window lane's plan
## (`ci/test/plat44_sequences_plan.nim`) both use.
##
## PLAT-34's corpus names OPERATIONS. A keystroke route to each sequence is
## FOUND: under each model in turn, every step is matched against the model's
## own bindings (and `insert-text` against the typed characters), and a
## candidate is accepted only if its keys produce exactly the state the named
## operation produces from the same state. The caret is first placed at the
## sequence's landmark with arrow keys from the top of the document.
##
## Pure over the core: no renderer, no process, no file.

import codetracer_embed
import ../../viewmodel/tests/generators/vocabulary_generator
import ../../viewmodel/tests/generators/operation_sequence_corpus

export operation_sequence_corpus, vocabulary_generator

const
  ProjectFile* = "doc.txt"

type
  Translation* = object
    ok*: bool
    model*: KeymapModel
    arrange*: seq[string]
    keys*: seq[string]
    missing*: string
      ## The first step with no key route, when not `ok`.

proc sameState*(a, b: EditingDocument): bool =
  a.state.doc == b.state.doc and a.state.selection == b.state.selection

proc typedKeys*(text: string): (bool, seq[string]) =
  ## `insert-text`'s argument as keys: printable ASCII only (the GPUI decoder
  ## names nothing else), `Space` for a space.
  result = (true, @[])
  for c in text:
    if c == ' ': result[1].add "Space"
    elif c >= '!' and c <= '~': result[1].add $c
    else: return (false, @[])

proc arrangeKeys*(d: ScenarioDoc; offset: int): seq[string] =
  ## Arrows from the top of the document to `offset`: `Down` per line, then
  ## `Right` per grapheme cluster (measured by the core's own column).
  var probe = initEditingDocument(ProjectFile, d.text)
  probe.state.selection = caretSelection(offset)
  for _ in 1 ..< caretLine(probe): result.add "Down"
  for _ in 0 ..< caretColumn(probe): result.add "Right"

proc applyAll*(d: var EditingDocument; keys: openArray[string]; now: var int64) =
  for k in keys:
    inc now
    discard d.applyKey(editScopeOf(d), k, now)

proc translate*(s: OperationSequence; d: ScenarioDoc;
               model: KeymapModel): Translation =
  result = Translation(ok: false, model: model)
  var now = 0'i64
  var cur = initEditingDocument(ProjectFile, d.text, model)
  result.arrange = arrangeKeys(d, startOffsetOf(d, s.start))
  cur.applyAll(result.arrange, now)
  let bindings = keymapOf(model).keymap.bindings
  for step in s.steps:
    var reference = cur
    inc now
    discard reference.applyNamed(step.name, step.args, now)
    var candidates: seq[seq[string]] = @[]
    if step.name == "insert-text":
      let (ok, ks) = typedKeys(step.args.text)
      if ok: candidates.add ks
    for b in bindings:
      if b.model == model and b.operation == step.name and b.args == step.args:
        candidates.add b.chords
    var found = false
    for c in candidates:
      var trial = cur
      var t = now
      trial.applyAll(c, t)
      if sameState(trial, reference):
        cur = trial
        now = t
        result.keys.add c
        found = true
        break
    if not found:
      result.missing = step.name
      return
  result.ok = true

proc translateAny*(s: OperationSequence; d: ScenarioDoc): Translation =
  for model in [kmProductDefault, kmVim, kmKakoune]:
    let t = translate(s, d, model)
    if t.ok: return t
    if result.missing.len == 0: result = t
  result.ok = false
