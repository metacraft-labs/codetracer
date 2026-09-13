## project_wasm_fixtures.nim — PLAT-13. The WebAssembly ENCODER the suites use
## to build the modules they hand `project_wasm.decodeModule`.
##
## ## WHY THIS IS A MODULE AND NOT A BLOCK OF BYTES IN EACH SUITE
##
## Two suites exercise the executable tier — `project_trust_test.nim` in
## `common-units` (the sandbox, without a machine) and
## `project_executable_tier_test.nim` in `ct-cli-units` (the gate, against a
## real directory) — and both need real modules. A hex blob copied into each is
## two copies of one artefact held where no compiler looks
## (Verification-Harness-Traps §14a): the day the decoder's expectations change,
## one copy is updated and the other goes on agreeing with itself.
##
## PLAT-8 took the same decision about its exploit probes, in those words: "the
## same bytes are read by two consumers … because a second copy of an exploit is
## a second thing that can drift while each half agrees with itself, and the
## half that would drift is the one nobody runs."
##
## ## IT IS AN ENCODER, NOT A DOUBLE
##
## Nothing here stands in for a component under test. It emits the wasm 1.0
## binary format — LEB128, sections, function bodies — and the thing that reads
## it is the real decoder. The relationship is the one a serialiser has with a
## parser, which is why `common-units` can assert a round trip at all: an
## encoder that agreed with a defective decoder would produce modules a real
## toolchain rejects, and `WasmMagic`, the section ids and the opcode bytes here
## are the SPEC's numbers rather than the decoder's names for them.
##
## ## IT LIVES IN `src/common` AND NO PRODUCT MODULE IMPORTS IT
##
## Stated rather than left to be noticed. It is test-support code that two lanes
## share; `ci/test/frontend-reachability.sh` does not scan `src/common`, and
## `ci/test/test-lane-coverage.sh` claims files named `*_test.nim` and
## `test_*.nim`, neither of which this is.

import std/strutils

import ./project_wasm

type
  FixtureFunc* = object
    ## One function, as the suites describe it. `body` is raw opcode bytes
    ## WITHOUT the terminating `end` — `buildWasm` appends it, so a fixture
    ## cannot forget the byte that makes a body balanced and then be reported as
    ## an unbalanced-block refusal it did not mean to write.
    params*: int
    results*: int
    locals*: int
    body*: string
    exportName*: string
      ## Empty for a function the module keeps to itself.

func uleb*(n: int): string =
  ## Unsigned LEB128. Emits the SHORTEST encoding, which is what a real
  ## toolchain emits; the decoder's five-byte bound is exercised by
  ## `padded`, below, rather than by accident here.
  var v = n
  while true:
    var b = v and 0x7F
    v = v shr 7
    if v != 0:
      result.add char(b or 0x80)
    else:
      result.add char(b)
      break

func sleb*(n: int32): string =
  ## Signed LEB128.
  var v = int64(n)
  while true:
    var b = int(v and 0x7F)
    v = v shr 7
    let signBit = (b and 0x40) != 0
    if (v == 0 and not signBit) or (v == -1 and signBit):
      result.add char(b)
      break
    result.add char(b or 0x80)

func padded*(n: int, bytes: int): string =
  ## An unsigned LEB128 written in exactly `bytes` bytes, with redundant
  ## continuation bits. A real encoder does not emit these; a hostile module
  ## does, and the decoder's five-byte refusal is what the suite drives with it.
  for i in 0 ..< bytes - 1:
    result.add char(((n shr (7 * i)) and 0x7F) or 0x80)
  result.add char((n shr (7 * (bytes - 1))) and 0x7F)

func section*(id: int; payload: string): string =
  char(id) & uleb(payload.len) & payload

func vec*(items: openArray[string]): string =
  result = uleb(items.len)
  for i in items: result.add i

# --- opcode helpers, named after the instructions they emit -----------------

func op*(b: int): string = $char(b)
func i32Const*(v: int32): string = op(0x41) & sleb(v)
func localGet*(i: int): string = op(0x20) & uleb(i)
func localSet*(i: int): string = op(0x21) & uleb(i)
func localTee*(i: int): string = op(0x22) & uleb(i)
func i32Load*(offset = 0): string = op(0x28) & uleb(2) & uleb(offset)
func i32Load8U*(offset = 0): string = op(0x2D) & uleb(0) & uleb(offset)
func i32Store*(offset = 0): string = op(0x36) & uleb(2) & uleb(offset)
func i32Store8*(offset = 0): string = op(0x3A) & uleb(0) & uleb(offset)
func blockEmpty*(): string = op(0x02) & op(0x40)
func loopEmpty*(): string = op(0x03) & op(0x40)
func ifEmpty*(): string = op(0x04) & op(0x40)
func opElseB*(): string = op(0x05)
func opEndB*(): string = op(0x0B)
func br*(depth: int): string = op(0x0C) & uleb(depth)
func brIf*(depth: int): string = op(0x0D) & uleb(depth)
func call*(idx: int): string = op(0x10) & uleb(idx)

const
  I32Add* = "\x6A"
  I32Sub* = "\x6B"
  I32Mul* = "\x6C"
  I32DivS* = "\x6D"
  I32Eq* = "\x46"
  I32Ne* = "\x47"
  I32LtU* = "\x49"
  I32Eqz* = "\x45"
  Unreachable* = "\x00"
  Drop* = "\x1A"
  Return* = "\x0F"

func buildWasm*(funcs: openArray[FixtureFunc]; memPages = 1): string =
  ## A whole module. Sections are emitted in the spec's order, which is the
  ## order the decoder enforces.
  result = WasmMagic & "\1\0\0\0"

  var typeEntries: seq[string] = @[]
  var funcEntries: seq[string] = @[]
  var exportEntries: seq[string] = @[]
  var codeEntries: seq[string] = @[]

  for i, f in funcs:
    var t = op(0x60) & uleb(f.params)
    for _ in 0 ..< f.params: t.add op(0x7F)
    t.add uleb(f.results)
    for _ in 0 ..< f.results: t.add op(0x7F)
    typeEntries.add t
    funcEntries.add uleb(i)
    if f.exportName.len > 0:
      exportEntries.add uleb(f.exportName.len) & f.exportName & op(0x00) & uleb(i)
    var localGroups = ""
    if f.locals > 0:
      localGroups = uleb(1) & uleb(f.locals) & op(0x7F)
    else:
      localGroups = uleb(0)
    let body = localGroups & f.body & opEndB()
    codeEntries.add uleb(body.len) & body

  result.add section(1, vec(typeEntries))
  result.add section(3, vec(funcEntries))
  if memPages > 0:
    result.add section(5, vec([op(0x00) & uleb(memPages)]))
  if exportEntries.len > 0:
    result.add section(7, vec(exportEntries))
  result.add section(10, vec(codeEntries))

func storeLiteral*(at: int; text: string): string =
  ## The instructions that write `text` into linear memory at `at`, NUL
  ## terminated. Three instructions per byte, because `data` sections are
  ## refused — see `project_wasm.nim`'s header.
  for i, ch in text:
    result.add i32Const(int32(at + i)) & i32Const(int32(ord(ch))) & i32Store8()
  result.add i32Const(int32(at + text.len)) & i32Const(0) & i32Store8()

# ---------------------------------------------------------------------------
# The named fixtures both suites use
# ---------------------------------------------------------------------------

const
  ExecutionNeedle* = "EXECUTABLE-TIER-RAN-ct-plat13"
    ## THE EFFECT, AND IT OCCURS NOWHERE ELSE IN THIS REPOSITORY.
    ##
    ## A module has no imports, so it cannot create a file; the strongest
    ## observable an actual execution can leave is the bytes it computed. This
    ## string is not a constant in any module's file either — `storeLiteral`
    ## emits one `i32.store8` per character, so the needle appearing in a
    ## presentation means those instructions RETIRED, not that a buffer was
    ## copied.
    ##
    ## The suites sweep for it in the whole of what a no-grant load produces —
    ## the rendered summary, every problem's text and the raw memory — for the
    ## reason PLAT-11 swept for `PRIVATE-KEY-MATERIAL-ct-plat11`: a "safe"
    ## message is a common place for the thing you refused to come back.

func needleModule*(): string =
  ## Writes `ExecutionNeedle` at address 16 and returns 16. The visualiser ABI's
  ## shape: `(i32 ptr, i32 len) -> i32 ptr`.
  buildWasm([FixtureFunc(
    params: 2, results: 1, locals: 0,
    body: storeLiteral(16, ExecutionNeedle) & i32Const(16),
    exportName: "ct_visualise")])

func echoLengthModule*(): string =
  ## Writes the decimal length of its input and returns it. Used as the
  ## POSITIVE TWIN for "the host's bytes reached the module": a module that
  ## answers the same thing for every input would pass a needle test and fail
  ## this one.
  var body = ""
  # local 0,1 = params (ptr, len); local 2 = cursor, local 3 = value
  body.add localGet(1) & localSet(2)
  # Write two ASCII digits of len (bounded fixtures keep len < 100).
  body.add i32Const(16)
  body.add localGet(2) & i32Const(10) & I32DivS & i32Const(48) & I32Add
  body.add i32Store8()
  body.add i32Const(17)
  body.add localGet(2) & i32Const(10) & op(0x70) & i32Const(48) & I32Add
  body.add i32Store8()
  body.add i32Const(18) & i32Const(0) & i32Store8()
  body.add i32Const(16)
  buildWasm([FixtureFunc(params: 2, results: 1, locals: 2, body: body,
                         exportName: "ct_visualise")])

func nonTerminatingModule*(): string =
  ## `loop br 0 end` — §7's "a comparison that can loop". It is TOTAL for this
  ## host because the work bound is, which is the whole claim, and it is the
  ## fixture that claim is measured against.
  buildWasm([FixtureFunc(
    params: 4, results: 1, locals: 0,
    body: loopEmpty() & br(0) & opEndB() & i32Const(0),
    exportName: "ct_diff")])

func byteEqualityDiffModule*(): string =
  ## A REAL diff: compares two byte ranges and returns 0 when they are equal.
  ## `(i32 aPtr, i32 aLen, i32 bPtr, i32 bLen) -> i32`.
  var body = ""
  # if aLen != bLen: return 1
  body.add localGet(1) & localGet(3) & I32Ne
  body.add ifEmpty() & i32Const(1) & Return & opEndB()
  # local 4 = index
  body.add i32Const(0) & localSet(4)
  body.add blockEmpty()
  body.add loopEmpty()
  body.add localGet(4) & localGet(1) & I32LtU & I32Eqz & brIf(1)
  body.add localGet(0) & localGet(4) & I32Add & i32Load8U()
  body.add localGet(2) & localGet(4) & I32Add & i32Load8U()
  body.add I32Ne
  body.add ifEmpty() & i32Const(2) & Return & opEndB()
  body.add localGet(4) & i32Const(1) & I32Add & localSet(4)
  body.add br(0)
  body.add opEndB()
  body.add opEndB()
  body.add i32Const(0)
  buildWasm([FixtureFunc(params: 4, results: 1, locals: 1, body: body,
                         exportName: "ct_diff")])

func controlFlowModule*(): string =
  ## TWO functions, a `call`, an `if`/`else` and a local.
  ##
  ## It exists because the diff and visualiser fixtures between them exercise
  ## `block`, `loop`, `br`, `br_if` and `return` and NOT `call` or `else` — and
  ## an interpreter arm aimed at a construct no fixture reaches is a row in a
  ## table that looks like coverage (Verification-Harness-Traps §16).
  ##
  ##   helper(x)  = x * 3
  ##   main(a, b) = helper(a) + (if a == b then 1000 else 2000)
  let helper = FixtureFunc(params: 1, results: 1, locals: 0,
                           body: localGet(0) & i32Const(3) & I32Mul)
  var body = localGet(0) & call(0)
  body.add localGet(0) & localGet(1) & I32Eq
  body.add ifEmpty() & i32Const(1000) & localSet(2) &
           opElseB() & i32Const(2000) & localSet(2) & opEndB()
  body.add localGet(2) & I32Add
  buildWasm([helper, FixtureFunc(params: 2, results: 1, locals: 1, body: body,
                                 exportName: "ct_control")])

func importingModule*(): string =
  ## THE EXPLOIT THE SANDBOX IS ABOUT: a module that asks the host for a
  ## function. What it asks for is WASI's `fd_write`, because that is the one a
  ## real toolchain emits by default and therefore the one a project would
  ## actually ship.
  var m = WasmMagic & "\1\0\0\0"
  let ft = op(0x60) & uleb(4) & op(0x7F) & op(0x7F) & op(0x7F) & op(0x7F) &
           uleb(1) & op(0x7F)
  m.add section(1, vec([ft]))
  let imp = uleb("wasi_snapshot_preview1".len) & "wasi_snapshot_preview1" &
            uleb("fd_write".len) & "fd_write" & op(0x00) & uleb(0)
  m.add section(2, vec([imp]))
  m.add section(3, vec([uleb(0)]))
  # THE EXPORT NAMES INDEX 0, the module's OWN function, so that a decoder
  # which skipped the import section would produce a module that decodes rather
  # than one refused for an incidental index error. An exploit fixture whose
  # refusal could come from somewhere else is an exploit that proves nothing
  # about the mechanism it is aimed at (Verification-Harness-Traps §16a).
  m.add section(7, vec([uleb("ct_diff".len) & "ct_diff" & op(0x00) & uleb(0)]))
  let body = uleb(0) & i32Const(0) & opEndB()
  m.add section(10, vec([uleb(body.len) & body]))
  m

func paddedLoopModule*(pad: int): string =
  ## `loop br 0 end`, then `pad` instructions THAT NEVER RETIRE, then the
  ## return value.
  ##
  ## THE PADDING IS UNREACHABLE ON PURPOSE, and that is the whole design of the
  ## fixture. `spent` is identical at every `pad` — the loop retires the same
  ## instructions until the work bound stops it — so the ONLY quantity that
  ## moves between two runs of this module is the length of the body the
  ## interpreter's loop touches per instruction. A bound reporting a count of
  ## instructions cannot see that, which is exactly why the copy that made an
  ## instruction O(body length) survived the whole of `spent`'s test suite:
  ## the §7 fixture's body is five instructions, so its amplification factor
  ## was 1.
  var body = loopEmpty() & br(0) & opEndB()
  for _ in 0 ..< pad: body.add op(0x01)          # nop
  body.add i32Const(0)
  buildWasm([FixtureFunc(params: 4, results: 1, locals: 0, body: body,
                         exportName: "ct_diff")])

func paddedCalleeModule*(pad: int): string =
  ## The same measurement one level up: a loop that CALLS a helper whose body
  ## is long and whose executed prefix is two instructions. `spent` is
  ## identical at every `pad` (`opCall` charges the callee's params and locals,
  ## which do not move); what moves is how much a CALL costs.
  var h = localGet(0) & Return
  for _ in 0 ..< pad: h.add op(0x01)
  let helper = FixtureFunc(params: 1, results: 1, locals: 0, body: h)
  let body = loopEmpty() & i32Const(7) & call(0) & Drop & br(0) & opEndB() &
             i32Const(0)
  buildWasm([helper, FixtureFunc(params: 4, results: 1, locals: 0, body: body,
                                 exportName: "ct_diff")])

func zeroPageVisualiserModule*(): string =
  ## A WELL-FORMED, EXPORT-CARRYING visualiser that declares NO memory.
  ##
  ## It is the shape `writeBytes`' bounds check is the only thing standing in
  ## front of: the host writes its input at `ExecutableInputBase` into a memory
  ## of length zero. Without that check the arithmetic is an `IndexDefect` in
  ## the HOST, raised out of a granted, well-formed module — a sandbox whose
  ## failure mode is a Defect is not one.
  buildWasm([FixtureFunc(params: 2, results: 1, locals: 0,
                         body: i32Const(0), exportName: "ct_visualise")],
            memPages = 0)

func returnsNothingModule*(): string =
  ## Declares a result and leaves nothing on the stack. `ret`'s own underflow
  ## guard is the only thing between this and `stack[^1]` on an empty stack —
  ## a DIFFERENT guard from the `pop()` template the `Drop` fixture exercises,
  ## so each has evidence only it can satisfy (Verification-Harness-Traps §16a).
  buildWasm([FixtureFunc(params: 0, results: 1, locals: 0, body: "",
                         exportName: "t")])

func callWithTooFewOperandsModule*(): string =
  ## A caller that pushes ONE operand and calls a TWO-parameter helper.
  ## `enter`'s operand test is the only thing between this and `stack.pop()`
  ## on an empty stack.
  let helper = FixtureFunc(params: 2, results: 1, locals: 0,
                           body: localGet(0) & localGet(1) & I32Add)
  let body = i32Const(5) & call(0)
  buildWasm([helper, FixtureFunc(params: 0, results: 1, locals: 0, body: body,
                                 exportName: "t")])

func calleeReachingIntoCallerModule*(): string =
  ## THE CALLER'S OPERANDS ARE THE CALLER'S. `main` pushes two values it has
  ## not consumed and then calls a two-parameter helper with NOTHING of its own
  ## on the stack above them. A test of the whole stack's height admits this
  ## and the callee silently takes the caller's operands; a test against the
  ## caller's `stackBase` refuses it, which is what wasm's validator does.
  ##
  ## Three frames are needed for the escape to exist at all, because the ENTRY
  ## frame's `stackBase` is 0 and nothing is below it:
  ##
  ##     helper(a, b) = a + b
  ##     middle()     = call helper          -- pushes NOTHING of its own
  ##     outer()      = 111, 222, call middle
  ##
  ## When `middle` reaches `call helper` the stack is `[111, 222]` and both
  ## belong to OUTER — `middle`'s `stackBase` is 2. A check over the WHOLE
  ## stack's height sees two operands and lets the call through, and `helper`
  ## computes 333 out of a frame it cannot see.
  let helper = FixtureFunc(params: 2, results: 1, locals: 0,
                           body: localGet(0) & localGet(1) & I32Add)
  let middle = FixtureFunc(params: 0, results: 1, locals: 0, body: call(0))
  let outer = FixtureFunc(params: 0, results: 1, locals: 0,
                          body: i32Const(111) & i32Const(222) & call(1),
                          exportName: "t")
  buildWasm([helper, middle, outer])

func nestedCallAnswersModule*(): string =
  ## THE POSITIVE TWIN for the module above, through the same three-frame
  ## shape: `middle` pushes its OWN two operands, so the call is legitimate and
  ## the module answers 7. Without it, "a nested call is refused" is equally
  ## satisfied by an interpreter that refuses every nested call.
  let helper = FixtureFunc(params: 2, results: 1, locals: 0,
                           body: localGet(0) & localGet(1) & I32Add)
  let middle = FixtureFunc(params: 0, results: 1, locals: 0,
                           body: i32Const(3) & i32Const(4) & call(0))
  let outer = FixtureFunc(params: 0, results: 1, locals: 0,
                          body: i32Const(111) & Drop & call(1),
                          exportName: "t")
  buildWasm([helper, middle, outer])

func doubleElseModule*(): string =
  ## `if / else / else / end`. Legal to DECODE in this subset — an `else` only
  ## rewrites the open `if`'s `alt` — and the first `else` therefore keeps the
  ## `target = -1` it was built with, because the matching `end` resolves the
  ## SECOND one. Falling out of the `then` arm lands on it with `pc = -1`,
  ## which is the input the run loop's range guard refuses. It is the
  ## counterexample to that guard's former "UNREACHABLE BY CONSTRUCTION".
  let body = i32Const(1) & ifEmpty() & i32Const(10) & Drop &
             opElseB() & i32Const(20) & Drop &
             opElseB() & i32Const(30) & Drop & opEndB() & i32Const(0)
  buildWasm([FixtureFunc(params: 0, results: 1, locals: 0, body: body,
                         exportName: "t")])

func tooManyLocalsModule*(locals: int): string =
  ## A code section declaring `locals` i32 locals in one group, WITHOUT
  ## emitting them. `buildWasm` cannot express this — it writes the group and
  ## the body together — so the code section is assembled here.
  ##
  ## The declared count is what the decoder allocates from, so a bound tested
  ## AFTER the append is a bound that has already run the append: at
  ## `2^31 - 1` that is two billion `seq.add`s and the host is gone. The bound
  ## is tested BEFORE it, and this fixture is what says so.
  let ft = op(0x60) & uleb(0) & uleb(0)
  let body = uleb(1) & uleb(locals) & op(0x7F) & opEndB()
  WasmMagic & "\1\0\0\0" &
    section(1, vec([ft])) &
    section(3, vec([uleb(0)])) &
    section(10, vec([uleb(body.len) & body]))

func codeBodyCountMismatchModule*(bodies: int): string =
  ## ONE declared function, `bodies` code bodies. The decoder indexes
  ## `typeCounts[i]` for each body, so the count test is the only thing
  ## between a module a repository ships and an `IndexDefect` in the host.
  let ft = op(0x60) & uleb(0) & uleb(0)
  var codes: seq[string] = @[]
  for _ in 0 ..< bodies:
    let body = uleb(0) & opEndB()
    codes.add uleb(body.len) & body
  WasmMagic & "\1\0\0\0" &
    section(1, vec([ft])) &
    section(3, vec([uleb(0)])) &
    section(10, vec(codes))

func hugeImmediateModule*(): string =
  ## `local.get` whose index is the five-byte LEB128 `FF FF FF FF 7F` —
  ## 34,359,738,367.
  ##
  ## THE ENCODING IS WELL-FORMED AND THE VALUE IS NOT. WebAssembly's `uN`
  ## grammar is recursive over at most five bytes for a `u32` and constrains
  ## only the value, so the five-byte bound in `u32leb` does not refuse this —
  ## the RANGE test below it does, and that test is the only thing between a
  ## module a repository ships and `int32(34_359_738_367)` in `decodeBody`,
  ## which is a `RangeDefect` raised out of the host rather than a refusal.
  ## The immediate is written as raw bytes because `uleb` emits the canonical
  ## (shortest) encoding and cannot express this.
  let body = op(0x20) & "\xFF\xFF\xFF\xFF\x7F" & i32Const(0)
  buildWasm([FixtureFunc(params: 4, results: 1, locals: 0, body: body,
                         exportName: "ct_diff")])

func stackDepthModule*(pushes: int): string =
  ## `pushes` × `i32.const 1`, and nothing that pops.
  ##
  ## The operand stack's bound is the only thing that stops a module's declared
  ## body growing a host `seq` one entry per instruction — with
  ## `MaxWasmBodyInstr` at 8,192 that is bounded, so what its absence costs is
  ## not a crash but a bound that is not a bound, and the answer becomes an
  ## ANSWER where it should be a trap. Which is why this fixture is used at the
  ## boundary in both directions.
  var body = ""
  for _ in 0 ..< pushes: body.add i32Const(1)
  buildWasm([FixtureFunc(params: 4, results: 1, locals: 0, body: body,
                         exportName: "ct_diff")])

func moduleWithoutExport*(name: string): string =
  ## A well-formed module that exports something else. The twin for "the host
  ## asked for a name the module does not have", which must be a refusal and
  ## not a trap.
  buildWasm([FixtureFunc(params: 2, results: 1, locals: 0,
                         body: i32Const(0), exportName: name)])

func describeBytes*(data: string): string =
  ## A short hex rendering, for a `checkpoint` when a decode refusal is not the
  ## one a case expected.
  var parts: seq[string] = @[]
  for i in 0 ..< min(data.len, 32):
    parts.add toHex(int(uint8(data[i])), 2)
  result = parts.join(" ")
  if data.len > 32: result.add " …(" & $data.len & " bytes)"
