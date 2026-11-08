## test_plat65_nim_tracing_vm.nim — the shared half of tracing Nim's
## compile-time code from the editor (`viewmodels/nim_tracing_vm`): what the
## caret offers, the request every route sends, the state a front-end shows,
## and where the recording opens.
##
## Spec: codetracer-pm `spec/Planned-Features/Nim-Compile-Time-Tracing-
## Milestones.md` (M6, M9–M11); `spec/GUI/Multi-Window-Tab-Management.md`
## "Which tab a replay opens in".
##
##   * THE OFFER over a real Nim module (the one the real-stack suites trace,
##     `tui/tests/fixtures/plat65_nim_project` writes the same text): a macro
##     call offers the macro action; a `static:` block's opener and body, a
##     `static(expr)` and a `{.compileTime.}` proc offer the static-block
##     action; a `const` declaration and a const section's entry offer the
##     constant action; an ORDINARY proc's line, its body and a top-level
##     statement after a static block offer neither; a `.nims` file offers
##     the evaluation; a file that is not Nim offers nothing;
##   * THE REQUEST: the LSP position is zero-based on both axes; nimsuggest
##     gets the line back 1-based and the column 0-based; the LSP command per
##     action; `nim e --trace` with its options before the file;
##   * nimsuggest's answer read (its tab-separated `Suggest`, the doc quoted);
##   * THE STATE: an offer the caret does not make is refused with the reason
##     and nothing is sent; the request names the line the compiler matches;
##     a second trace while one runs is refused; the language server's
##     refusals read as the failure they are;
##   * THE PLACEMENT: a new session tab;
##   * THE NAMES: the four operations are catalogued, bound in the CUA base
##     (`Ctrl+K T` and the construct's letter, in both modes) and listed in
##     the palette.
##
## Pure — vm-unit and vm-unit-js. No mocks: everything here is the module's
## own functions over literal text.

import std/[strutils, unittest]

import ../../viewmodels/nim_tracing_vm
import ../../viewmodels/omnibar_vm
import ../../viewmodels/omnibar_sources
import ../../editing_core
import ../../keymap/keymap_router
import ../../keymap/scope_path
import ../../keymap/operation_catalogue

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 98

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Module = """import std/macros

macro twice(body: untyped): untyped =
  result = newStmtList(body, body)

proc compute(n: int): int =
  result = 0
  for i in 1..n:
    result += i * i

const squares = compute(3)

const
  limit = 4
  cubes = compute(limit)

proc ctOnly(): int {.compileTime.} =
  result = compute(2)

static:
  var acc = 0
  for i in 0..<limit:
    acc += i
  echo "acc=", acc

echo "after"
let folded = static(compute(5))

twice:
  echo squares
"""
  Path = "/work/project/src/tracing.nim"

let lines = Module.splitLines()

proc lineOf(text: string): int =
  ## The 1-based line whose text is `text` (stripped).
  for i, l in lines:
    if l.strip == text:
      return i + 1
  raise newException(KeyError, "no line " & text)

proc offer(text: string; path = Path): set[NimTraceAction] =
  availableNimTraceActions(path, lines, lineOf(text), 1)

suite "the offer at the caret":
  test "a macro call, and any other line of code, offer the macro action":
    ck offer("twice:") == {ntaMacro}
    ck offer("echo squares") == {ntaMacro}
    ck availableNimTraceActions(Path, lines, lineOf("echo \"after\"") - 1,
                                1) == {}

  test "a static: block and a static(expr); not a compileTime proc's body":
    ck ntaStaticBlock in offer("static:")
    ck ntaStaticBlock in offer("var acc = 0")
    ck ntaStaticBlock in offer("acc += i")
    ck ntaStaticBlock in offer("let folded = static(compute(5))")
    # A compileTime proc runs when an evaluation calls it; the compiler
    # matches the evaluation, not the body.
    ck ntaStaticBlock notin offer("proc ctOnly(): int {.compileTime.} =")
    ck ntaStaticBlock notin offer("result = compute(2)")
    ck ntaConstant notin offer("static:")

  test "the line the compiler matches: a static: block's first statement":
    proc requested(action: NimTraceAction; text: string): int =
      let vm = newNimTracingVM()
      discard vm.begin(NimTraceRequest(action: action, path: Path,
                                       line: lineOf(text), column: 1), lines)
      vm.request.line
    let first = lineOf("var acc = 0")
    ck requested(ntaStaticBlock, "static:") == first
    ck requested(ntaStaticBlock, "acc += i") == first
    ck requested(ntaConstant, "cubes = compute(limit)") ==
       lineOf("cubes = compute(limit)")
    ck requested(ntaConstant, "const squares = compute(3)") ==
       lineOf("const squares = compute(3)")
    ck requested(ntaMacro, "twice:") == lineOf("twice:")

  test "a const declaration and a const section's entries":
    ck ntaConstant in offer("const squares = compute(3)")
    ck ntaConstant in offer("cubes = compute(limit)")
    ck ntaConstant in offer("limit = 4")
    ck ntaStaticBlock notin offer("const squares = compute(3)")

  test "an ordinary proc's line and body, and code after a block, offer neither":
    let plain = offer("proc compute(n: int): int =")
    ck ntaStaticBlock notin plain
    ck ntaConstant notin plain
    ck offer("result += i * i") == {ntaMacro}
    ck offer("result = 0") == {ntaMacro}
    ck offer("echo \"after\"") == {ntaMacro}
    ck offer("macro twice(body: untyped): untyped =") == {ntaMacro}

  test "a NimScript file offers its evaluation; a file that is not Nim, nothing":
    ck ntaEval in offer("echo \"after\"", "/work/project/build.nims")
    ck ntaEval notin offer("echo \"after\"")
    ck offer("static:", "/work/project/notes.txt") == {}
    ck availableNimTraceActions("", lines, 1, 1) == {}

  test "the reason an action is inert names the place":
    let why = unavailableReason(ntaStaticBlock, Path, 6)
    ck "tracing.nim:6" in why
    ck "static: block" in why
    ck "is not one" in unavailableReason(ntaEval, Path, 1)
    ck "Nim files" in unavailableReason(ntaMacro, "/a/b.py", 1)

suite "the request":
  test "the LSP position is zero-based on both axes":
    let r = NimTraceRequest(action: ntaStaticBlock, path: Path,
                            line: lineOf("static:"), column: 3)
    let at = wirePositionOf(r)
    ck at.line == lineOf("static:") - 1
    ck at.character == 2
    ck wirePositionOf(NimTraceRequest(line: 1, column: 1)) ==
       (line: 0, character: 0)

  test "nimsuggest gets the line 1-based and the column 0-based":
    let r = NimTraceRequest(action: ntaConstant, path: Path, line: 11,
                            column: 7)
    ck nimsuggestCommandOf(r) == "tracestatic " & Path & ":11:6"
    let m = NimTraceRequest(action: ntaMacro, path: Path, line: 29, column: 1)
    ck nimsuggestCommandOf(m) == "traceExpand " & Path & ":29:0"

  test "the LSP command per action":
    ck lspCommandOf(ntaMacro) == "nim/traceExpandMacro"
    ck lspCommandOf(ntaStaticBlock) == "nim/traceStaticBlock"
    ck lspCommandOf(ntaConstant) == "nim/traceStaticBlock"
    ck lspCommandOf(ntaEval) == ""

  test "nim e --trace, its options before the file":
    let r = NimTraceRequest(action: ntaEval, path: "/w/build.nims", line: 1,
                            column: 1)
    let argv = evalArgumentsOf(r, "/out/trace.ct", ["--nimcache:/c"])
    ck argv[0] == "e"
    ck "--trace:/out/trace.ct" in argv
    ck argv.find("--nimcache:/c") < argv.find("/w/build.nims")
    ck argv[^1] == "/w/build.nims"

  test "nimsuggest's answer: the doc column of the trace result":
    let answer = "> traceStatic\tskUnknown\t\t\t\t20\t0\t" &
                 "\"/tmp/cache/static_trace_20.ct\"\t0\n> \n"
    ck nimsuggestTracePath(answer) == "/tmp/cache/static_trace_20.ct"
    ck nimsuggestTracePath("traceExpand\tskUnknown\t\t\t\t3\t0\t\"\"\t0\n") == ""
    ck nimsuggestTracePath("") == ""

suite "the state a front-end shows":
  test "an action the caret does not offer is refused, with why":
    let vm = newNimTracingVM()
    let r = NimTraceRequest(action: ntaStaticBlock, path: Path,
                            line: lineOf("proc compute(n: int): int ="),
                            column: 1)
    ck not vm.begin(r, lines)
    ck vm.phase == ntpFailed
    ck vm.failure == ntfNotAvailable
    ck "static: block" in vm.message

  test "a trace runs, a second is refused, and it settles":
    let vm = newNimTracingVM()
    let r = NimTraceRequest(action: ntaStaticBlock, path: Path,
                            line: lineOf("static:"), column: 1)
    ck vm.begin(r, lines)
    ck vm.running
    # The request names the line the compiler matches, at its code.
    ck vm.request.line == lineOf("var acc = 0")
    ck vm.request.column == 3
    ck vm.message == "Tracing static block execution..."
    ck not vm.begin(r, lines)
    ck vm.message == "a Nim trace is already running"
    ck vm.running
    vm.succeed("/state/nim-traces/tracing-static-block-1")
    ck vm.phase == ntpDone
    ck vm.tracePath == "/state/nim-traces/tracing-static-block-1"

  test "the language server's refusals, read":
    proc refused(action: NimTraceAction; line: string;
                 message: string): NimTraceFailure =
      let vm = newNimTracingVM()
      discard vm.begin(NimTraceRequest(action: action, path: Path,
                                       line: lineOf(line), column: 1), lines)
      vm.refuse(message)
      ck not vm.running
      vm.failure
    ck refused(ntaMacro, "twice:",
      "No trace result at this position (not a macro call?)") == ntfNotAMacro
    ck refused(ntaConstant, "cubes = compute(limit)",
      "No trace result at this position (not a static block / const / " &
      "compileTime body?)") == ntfNotAStaticBlock
    ck refused(ntaStaticBlock, "static:",
      "nimsuggest is not available for this file") == ntfNoLanguageServer
    ck refused(ntaMacro, "twice:",
      "build.nims(3, 1) Error: undeclared identifier: 'x'") == ntfCompileError
    let vm = newNimTracingVM()
    discard vm.begin(NimTraceRequest(action: ntaMacro, path: Path,
                                     line: lineOf("twice:"), column: 1), lines)
    vm.refuse("No trace result at this position (not a macro call?)")
    ck vm.message == "No macro call found at this position."

suite "where the recording opens":
  test "a new session tab":
    ck nimTracePlacement() == topNewTab
    let req = traceOpenRequestOf("/state/nim-traces/x")
    ck req.policy == topNewTab
    ck req.tracePath == "/state/nim-traces/x"

suite "the names: catalogue, keymap, palette":
  test "the four operations are catalogued, in the editor's table":
    for a in NimTraceAction:
      ck isCatalogued(nimTraceOperationOf(a))
      ck nimTraceActionOfOperation(nimTraceOperationOf(a)) == (true, a)

  test "the CUA base binds Ctrl+K T and the construct's letter, both modes":
    let path = @[element(ekWindow, "window"), element(ekTab, "tab:1"),
                 element(ekPane, "editor"),
                 element(ekEditor, "editor:tracing.nim")]
    let delivery = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                               keyProtocol: kpKitty)
    for (letter, op) in [("m", TraceMacroOperation),
                         ("s", TraceStaticBlockOperation),
                         ("c", TraceConstantOperation),
                         ("e", TraceEvalOperation)]:
      for facts in [SessionFacts(product: pmEdit,
                                 editor: EditorFacts(mode: emInsert)),
                    SessionFacts(product: pmDebug, replayLoaded: true,
                                 editor: EditorFacts(readOnly: true,
                                                     mode: emInsert))]:
        var r = initKeymapRouter(bkCua, delivery)
        var t = 1_000'i64
        var res: EditingResolution
        for k in ["Ctrl+k", "t", letter]:
          res = r.route(facts, path, nmNormal, k, t)
          t += 10
        ck res.kind == erOperation and res.operation == op

  test "the palette lists the four, each running its operation":
    let entries = nimTraceCommands()
    ck entries.len == 4
    ck entries[0].label == "Nim: Trace Macro at Cursor"
    ck entries[3].label == "Nim: Trace NimScript Evaluation"
    for i, e in entries:
      ck parseOperationCommand(e.target) ==
         (true, nimTraceOperationOf(NimTraceAction(i)))

  test "the assertion count is the one declared":
    check countedAssertions == ExpectedAssertions
