## PLAT-44 — PLAT-34's thirty pinned operation sequences, driven through the
## SHIPPED GPUI binary as WRITES, from keys.
##
## Run (needs `just build-gpui`):
##   nim c -r --path:src/frontend/viewmodel src/frontend/gpui/tests/test_plat44_sequences.nim
##
## PLAT-34's corpus (`generators/operation_sequence_corpus.nim`) names
## OPERATIONS, not keys: it was written for the core's named-operation door.
## A keystroke route to each sequence is therefore FOUND rather than written:
##
##   1. Under each model in turn, every step is matched against the model's own
##      bindings — a binding whose operation and arguments are the step's — and
##      `insert-text` against the typed characters. A candidate is ACCEPTED only
##      if applying its keys to the current state produces exactly the state
##      the named operation produces from the same state (document and
##      selection). So the translation is verified, step by step, against the
##      corpus's own meaning; nothing is assumed about what a key does.
##   2. The caret is placed at the sequence's landmark with arrow keys from the
##      top of the document (arrows are bound in all three models), and the
##      reference is taken from WHERE THE ARROWS LANDED, so the sequence runs
##      from the same state on both routes.
##   3. The keys — arrangement, steps, `Ctrl+s` — are typed into
##      `codetracer-gpui --edit --edit-keys=…` (GPUI's own spellings, through
##      the shim's focus dispatch) and the FILE ON DISK must equal the
##      in-process document; the render plan's caret row must be the
##      in-process caret line.
##
## A sequence with no key route under any model is REPORTED BY NAME with the
## step that has none, and the reachable count is pinned — the milestone's
## "thirty" is a claim about the corpus, and which of the thirty a key can
## reach is a measurement about the keymaps (§34: assert the realised set).
##
## No mocks: the real core, the shipped binary, the real shim, real files.

import std/[json, os, osproc, sets, streams, strtabs, strutils, tables,
            tempfiles, unittest]

import codetracer_embed
import ./plat44_translation

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

proc gpuiSpec(name: string): string =
  ## A canonical key name as `--edit-keys` spells a GPUI keystroke.
  const named = {"Esc": "escape", "Enter": "enter", "Backspace": "backspace",
                 "Tab": "tab", "Space": "space", "Delete": "delete",
                 "Home": "home", "End": "end", "PageUp": "pageup",
                 "PageDown": "pagedown", "Up": "up", "Down": "down",
                 "Left": "left", "Right": "right"}.toTable
  var parts = name.split('+')
  if name.endsWith("++"): parts = name[0 ..< name.len - 2].split('+') & @["+"]
  if name == "+": parts = @["+"]
  var mods: seq[string] = @[]
  for m in parts[0 ..< parts.len - 1]:
    case m
    of "Ctrl": mods.add "control"
    of "Alt": mods.add "alt"
    of "Shift": mods.add "shift"
    else: discard
  var base = parts[^1]
  if base == ",": base = "comma"   # `--edit-keys`' own spelling of the key
  elif named.hasKey(base): base = named[base]
  elif base.len == 1 and base[0] in 'A'..'Z':
    mods.add "shift"
    base = $base[0].toLowerAscii
  (if mods.len > 0: mods.join("-") & "-" else: "") & base

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = repo.parentDir / "isonim-gpui/rust/target/debug"

proc runBinary(project, state: string; specs: seq[string]): (int, string) =
  let p = startProcess(bin,
    args = @["--edit", "--report-plan", "--width=1600", "--height=1200",
             "--edit-keys=" & specs.join(","), project],
    env = newStringTable({"LD_LIBRARY_PATH": shimDir,
                          "CODETRACER_TUI_LAYOUT_DIR": state}),
    options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  (rc, output)

proc caretRowOf(plan: string): int =
  ## The line number of the row the plan marks as the inspection cursor (the
  ## caret), read from the gutter text; -1 when none.
  result = -1
  proc walk(n: JsonNode; r: var int) =
    let a = n{"attributes"}
    if not a.isNil and a{"data-ct-pointer"}.getStr == "eptInspection":
      r = a{"data-ct-row"}.getStr.parseInt
    for c in n{"children"}.getElems: walk(c, r)
  try:
    walk(parseJson(plan), result)
  except CatchableError:
    discard

const
  ReachableSequences = 23
    ## MEASURED 2026-09-23: how many of the thirty a key route reaches. Pinned
    ## so a keymap change that opens or closes a route moves a number here.
    ##
    ## 24 -> 23 on 2026-09-24, and it is this pin doing its job: 3619f2666
    ## rebound Vim's and Kakoune's `o` / `O` from `insert-blank-line-below` /
    ## `-above` to the new `open-line-below` / `-above` (open a line AND enter
    ## insert mode), and filed `insert-blank-line-*` as having no chord. That
    ## closed the only route to `edit-blank-line-below`, which is now the
    ## seventh unreachable sequence (no key for `insert-blank-line-below`).
    ## The window record was re-typed against the new keymap the same day.
    ## The six that no key reaches, each reported with the first step the
    ## FIRST model tried (the product default) has no key for:
    ## `move-subword-forward`, `split-line`, `add-cursor-below`,
    ## `toggle-breakpoint`, `toggle-tracepoint`, `toggle-flow-overlay`. The
    ## last three are debugger-surface operations with no editing-keymap
    ## binding in any model; the first two have no binding in any model; and
    ## `multi-cursor-insert` is reached step by step by no single model.

let docs = scenarioDocs()
let seqs = operationSequences()

suite "PLAT-44: the thirty, as keys":

  test "the corpus is PLAT-34's thirty, over the eighteen documents":
    ck seqs.len == OperationSequenceCardinality
    ck docs.len == 18

  test "which of the thirty a key reaches is measured, and pinned":
    var reachable = 0
    var unreachable: seq[string] = @[]
    for s in seqs:
      let t = translateAny(s, docs[s.docIndex])
      if t.ok: inc reachable
      else: unreachable.add s.id & " (no key for `" & t.missing & "`)"
    echo "  reachable: ", reachable, " of ", seqs.len
    for u in unreachable: echo "  unreachable: ", u
    ck reachable == ReachableSequences
    ck reachable + unreachable.len == OperationSequenceCardinality

  for s in seqs:
    let t = translateAny(s, docs[s.docIndex])
    if not t.ok: continue
    test "typed into the binary and saved: " & s.id & " (" & $t.model & ")":
      let d = docs[s.docIndex]
      var expected = initEditingDocument(ProjectFile, d.text, t.model)
      var now = 0'i64
      expected.applyAll(t.arrange & t.keys, now)
      let dir = createTempDir("plat44-", "-seq")
      try:
        let project = dir / "project"
        let state = dir / "state"
        createDir(project)
        createDir(state)
        writeFile(project / ProjectFile, d.text)
        writeFile(state / "keymap", $t.model & "\n")
        var specs: seq[string] = @[]
        for k in t.arrange & t.keys: specs.add gpuiSpec(k)
        # Leave any insert mode (Esc changes no text), then save.
        if t.model != kmProductDefault: specs.add "escape"
        specs.add "control-s"
        let (rc, plan) = runBinary(project, state, specs)
        checkpoint("rc " & $rc & " keys " & specs.join(","))
        ck rc == 0
        ck readFile(project / ProjectFile) == expected.state.doc
        ck caretRowOf(plan) == caretLine(expected)
      finally:
        removeDir(dir)

suite "PLAT-44 sequences — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
