## project_wasm.nim — PLAT-13's sandbox. A WebAssembly decoder and interpreter
## for the executable tier of a project definition, and nothing else.
##
## Project-Definitions.md §9 decision 2 asks for WASM and gives the reason this
## file is written the way it is:
##
##   "a project definition is *hostile-by-default* input, and a sandbox whose
##    boundary is a language convention is not a boundary."
##
## ## THE BOUNDARY IS THAT THE MODULE HAS NO IMPORTS, AND THAT IS AN ALLOW-LIST
##
## §2.3 says an executable definition gets **strictly less** than a plugin: "no
## network, ever; no filesystem beyond what they are handed; no process
## spawning". PLAT-8 paid eleven verified escapes to learn that a *denylist over
## a language surface loses* and an *allow-list over a closure does not*, and
## this module is that lesson applied to a different language.
##
## The allow-list here is the set of host functions a module may call, and it is
## **empty**. `decodeModule` refuses a module whose import section declares
## anything at all (`wpcImportDeclared`), so there is no `call` a module can
## write that reaches outside this interpreter — no `fd_write`, no WASI, no
## "just this one host hook for logging". A refusal is not needed for `open`,
## for `socket` or for `fork`, because there is no mechanism by which their
## names could be spelled: the only `call` opcode this interpreter implements
## resolves against the module's **own** function vector.
##
## That is a structural property of the decoder rather than a list somebody
## maintains, which is the difference §2.3 and PLAT-8's residual 8 are both
## about. `project_trust.nim` states the same floor a second time in PLAT-8's
## own vocabulary — an empty `GrantSet` that `capabilities.decide` refuses on
## every `IoRequestKind` — because two audiences need it said two ways, and the
## suite asserts the two agree.
##
## ## THE SUBSET IS SMALL ON PURPOSE, AND EVERY EXCLUSION IS A REFUSAL
##
## There is no "unsupported, ignored" arm anywhere below. A section this build
## does not implement, a value type it does not implement, an opcode it does not
## implement and a block type it does not implement are each a typed refusal
## naming what was found — PLAT-11's `pdcUnknownKey` rule, in a binary format.
## The alternative is a decoder that skips what it does not understand, which is
## how a module that means one thing to a producer and another to this
## interpreter gets admitted.
##
## What is implemented:
##
##   | section  | treatment |
##   |----------|-----------|
##   | custom   | skipped by LENGTH, never parsed |
##   | type     | function types over `i32` only |
##   | import   | refused if it declares ANYTHING |
##   | function | type indices |
##   | memory   | at most one, bounded by `MaxWasmPages` |
##   | export   | functions only |
##   | code     | locals (`i32` only) and a decoded body |
##   | anything else (table, global, start, element, data, data-count, unknown) | refused by id |
##
## `data` is refused rather than implemented, and it costs the module its
## constant pool: a module that wants bytes in memory writes them with
## `i32.const` + `i32.store8`. That is a real cost and it is taken deliberately,
## because a data section is a second way for a module's *file* to place bytes
## at an address, and the host writes the only bytes this ABI is about.
##
## Block types are restricted to the empty type (`0x40`). Every label therefore
## carries no values, so a branch is "truncate the operand stack to the height
## the label recorded, and jump" with no arity arithmetic — which is what makes
## the interpreter's control flow total by inspection rather than by argument.
##
## ## EVERYTHING HOSTILE IS DECIDED AT DECODE, NOT AT RUN
##
## The body of every function is decoded into `seq[Instr]` before anything runs,
## and the structured instructions have their matching `else` / `end` resolved
## there. So the run loop indexes an array of already-validated instructions and
## never parses a byte. An unknown opcode, an unterminated block, a branch
## deeper than the label stack, a LEB128 that does not terminate and a length
## that runs off the end of the file are all decode-time refusals with a name.
##
## ## THE WORK BOUND COUNTS THE WORK, NOT A PROXY FOR IT
##
## PLAT-12 spent four verification rounds on one sentence — *a bound whose
## report is constant in the quantity being multiplied is a bound on the wrong
## quantity* — so this file states, up front, every quantity a run spends and
## charges each at the site that spends it:
##
##   | quantity | charged at | why it is not free |
##   |---|---|---|
##   | an instruction retired | `runExportIn`'s loop, `spend(1)`, once per instruction | the unit the bound is about |
##   | a frame's locals | `runExportIn`, before `enter`, for the entry frame and again at every `opCall` | `newSeq[int32](n)` is O(n), and `n` is the MODULE's number |
##   | a memory page at instantiation | `instantiationCost`, charged by the caller BEFORE it allocates | the page is ZEROED, and the count is the module's |
##   | a byte the host writes into memory | `project_executables.prepare` | O(len), and `len` is the host's input |
##   | a byte the host reads out of memory | `project_executables.visualiseWith`, after `readCString` | O(len), and the module chose the length |
##
## **AND THE TABLE IS ONLY TRUE WHILE AN INSTRUCTION IS O(1), WHICH IT WAS NOT
## — UNDER ORC.** The first row is the unit the bound is about, so anything the
## loop does per instruction that is NOT constant makes the whole table describe
## the wrong quantity — and nothing in `spent` can see it, because `spent` is a
## correct count of a unit whose cost has changed.
##
## **THE MEMORY MANAGER IS AN INPUT TO EVERY NUMBER BELOW, AND IT DECIDES
## WHETHER THERE IS A DEFECT AT ALL.** `let x = someSeq` is a COPY under ORC and
## a REFCOUNT BUMP under refc. Measured on 2026-09-13, one host, one session,
## best of seven, work bound 200,001, `spent` IDENTICAL at 200,002 in every row:
##
##   | mm | fixture | body length | with the copy | with the alias |
##   |---|---|---|---|---|
##   | orc | `paddedLoopModule` | 5 | 24.1 ms | 7.4 ms |
##   | orc | `paddedLoopModule` | 8,005 | **7,819.8 ms** | 7.3 ms |
##   | orc | `paddedCalleeModule` | 8 | 28.6 ms | 11.2 ms |
##   | orc | `paddedCalleeModule` | 8,003 | **3,390.8 ms** | 11.4 ms |
##   | refc | `paddedLoopModule` | 8,005 | 22.6 ms | 21.8 ms |
##   | refc | `paddedCalleeModule` | 8,003 | 36.7 ms | 35.8 ms |
##
## and through the product's own entry point (`diffWith`, the shipped
## `MaxExecutableWork`), an 8,056-byte module — inside `MaxWasmBodyInstr`,
## inside `MaxWasmBytes` — went from **66.9 s to 52 ms** under ORC, reporting
## 1,000,001 of 1,000,000 both times. (That row is the 2026-09-13 verification
## pass's own measurement, on the same host and under the same `nim c` default.)
##
## **WHICH BUILDS WERE EVER AFFECTED, PLAINLY.** `common-units` — the lane that
## runs this file's suite — compiles with Nim 2.x's default ORC, so the defect
## was real there and the two long-body cases and arms W18/W19 belong there.
## `ct-cli-units` compiles `--mm:refc`, and EVERY SHIPPED BINARY IS REFC:
## `repro.nim`'s `ctNative` and `ctNimJs` both pass `mm = "refc"`, and
## `src/Tuprules.tup` passes `--mm:refc`. **No shipped `ct` ever carried this
## defect.** The repair is correct and free under both, and it is kept because
## the lane that grades the property is ORC and a build that moved to ORC would
## meet it.
##
## The cause was `let body = m.functions[fnIdx].body` in the run loop: a COPY of
## the whole body per retired instruction. `opCall` and `enter` had the same
## shape one level up (a copy of the callee's whole `WasmFunction` per CALL),
## and `ret` a smaller one (the frame's `FuncType`, two seqs, per return). The
## two load-bearing ones are `{.cursor.}` aliases now — the other three were
## DELETED rather than kept, because ORC already infers a cursor for them and an
## annotation no arm can kill is a row that looks like coverage (§16a). The two
## long-body cases in `project_trust_test` plus arms W18 and W19 are what keep
## it that way, because the only quantity a regression moves is TIME and `spent`
## goes on reporting the same number.
## **There is no sixth row: the fix was to make the quantity constant, not to
## charge for it.**
##
## The last three are charged by the CALLER and arrive here as `spentAlready`,
## which is a parameter rather than something this file recomputes: the caller
## did the work, and a second calculation of the same quantity here would be a
## second thing that can be wrong (§14).
##
## `WasmRun.spent` moves with all five. `project_trust_test` pins it as an
## EQUALITY over a run small enough to enumerate every unit of, because an
## inequality between a bound and a measurement of a different quantity is the
## exact shape that passed for a day in PLAT-12.
##
## ## PURE
##
## No filesystem, no clock, no process, no `isonim`, and no dependency outside
## `std/strutils`. It runs in `common-units`, a lane that links no renderer and
## opens no handle, so every refusal below is asserted without a machine — the
## same argument `plugin_model/capabilities.nim` makes for the same reason.

import std/strutils

type
  WasmProblemCode* = enum
    ## Why a module is not one this build will run. Every one is a REFUSAL;
    ## there is no severity axis here, because a module that is not admitted
    ## does not run and there is no partial admission.
    ##
    ## Ordered by the phase that discovers it: the file, the sections, the
    ## bodies, the run.
    wpcEmpty                 ## no bytes at all
    wpcNotWasm               ## the four-byte magic is not `\0asm`
    wpcUnsupportedVersion    ## a binary-format version other than 1
    wpcTruncated             ## a length or an index ran off the end
    wpcMalformedInteger      ## a LEB128 that does not terminate, or overflows
    wpcTooLarge              ## a bound on the module itself was exceeded
    wpcImportDeclared        ## the import section declares something. See the header
    wpcUnsupportedSection    ## a section id this subset does not implement
    wpcSectionOutOfOrder     ## sections repeated or out of the spec's order
    wpcUnsupportedType       ## a value type other than `i32`
    wpcUnsupportedBlockType  ## a block type other than the empty one
    wpcUnsupportedOpcode     ## an opcode outside the implemented subset
    wpcUnbalancedBlock       ## a block, loop or if with no matching `end`
    wpcBadIndex              ## a function, type, local or label index out of range
    wpcNoSuchExport          ## the module exports no function of the wanted name
    wpcWrongSignature        ## the export's type is not the one the ABI states

  WasmProblem* = object
    ## WHAT WAS FOUND, AND WHERE. `at` is a byte offset into the module for a
    ## decode problem and an instruction index for a run problem, and `detail`
    ## says which — because a bare number that means two things is a number a
    ## reader cannot use.
    code*: WasmProblemCode
    at*: int
    detail*: string

  WasmTrap* = enum
    ## Why a run stopped without an answer. Distinguished from
    ## `WasmProblemCode` because these are properties of a RUN and not of a
    ## module: the same module traps on one input and answers on another, and a
    ## reader told "the module is malformed" would go and edit a correct file.
    wtNone
    wtUnreachable        ## the module executed `unreachable`
    wtOutOfBounds        ## a load or a store outside the linear memory
    wtDivideByZero
    wtIntegerOverflow    ## `INT32_MIN / -1`, which wasm defines as a trap
    wtStackOverflow      ## the operand stack or the call depth bound
    wtStackUnderflow     ## a pop on an empty operand stack
    wtWorkExhausted      ## the work bound. §7's "bounded and total", enforced

  ValType* = enum
    vtI32
      ## THE ONLY ONE. `i64`, `f32`, `f64`, `v128` and the reference types are
      ## refused at decode with `wpcUnsupportedType`. A float in a visualiser or
      ## a diff would also breach §3.1's determinism requirement on any host
      ## whose rounding differs, so the exclusion is a feature twice over.

  FuncType* = object
    params*: seq[ValType]
    results*: seq[ValType]   ## at most one, which is wasm 1.0's own bound

  Op* = enum
    ## The implemented opcodes, named rather than left as numbers. The decoder
    ## maps a byte to one of these and refuses every byte it cannot map, so
    ## this enum IS the subset.
    opUnreachable, opNop, opBlock, opLoop, opIf, opElse, opEnd
    opBr, opBrIf, opReturn, opCall
    opDrop, opSelect
    opLocalGet, opLocalSet, opLocalTee
    opI32Load, opI32Load8U, opI32Store, opI32Store8
    opMemorySize
    opI32Const
    opI32Eqz, opI32Eq, opI32Ne
    opI32LtS, opI32LtU, opI32GtS, opI32GtU
    opI32LeS, opI32LeU, opI32GeS, opI32GeU
    opI32Add, opI32Sub, opI32Mul
    opI32DivS, opI32DivU, opI32RemS, opI32RemU
    opI32And, opI32Or, opI32Xor, opI32Shl, opI32ShrS, opI32ShrU

  Instr* = object
    ## ONE DECODED INSTRUCTION. `imm` carries the only immediate any opcode in
    ## the subset has (a constant, an index, a branch depth); `memOffset`
    ## carries a load or store's static offset; `target` and `alt` carry the
    ## resolved control-flow destinations, computed at decode.
    op*: Op
    imm*: int32
    memOffset*: uint32
    target*: int32
      ## `block`/`if`: the index of the matching `end`. `loop`: its own index,
      ## which is where a branch to it goes. `else`: the matching `end`.
    alt*: int32
      ## `if`: the index of the matching `else`, or -1 when there is none.

  WasmFunction* = object
    typeIndex*: int
    localTypes*: seq[ValType]
      ## The DECLARED locals, after the parameters. `pushFrame` allocates
      ## `params.len + localTypes.len` slots and charges for them.
    body*: seq[Instr]

  WasmExport* = object
    name*: string
    funcIndex*: int

  WasmModule* = object
    ## A module this build will run. There is no arm anywhere that produces one
    ## of these from bytes it did not fully understand.
    types*: seq[FuncType]
    functions*: seq[WasmFunction]
    exports*: seq[WasmExport]
    memoryPages*: int        ## 0 when the module declares no memory
    byteCount*: int          ## what it decoded from, for the report

  WasmDecode* = object
    ok*: bool
    module*: WasmModule
    problem*: WasmProblem

  WasmRun* = object
    ## WHAT A RUN PRODUCED, AS A VALUE. Nothing here raises: a trap, an
    ## exhausted allowance and an answer are three fields of one record, for the
    ## reason PLAT-8's `ReadOutcome` is one — a caller that has to catch an
    ## exception to learn that a sandbox refused something is a caller that can
    ## forget to.
    ok*: bool
    value*: int32
    trap*: WasmTrap
    spent*: int
      ## Every unit the run cost, over all five charged quantities — see the
      ## header's table. It is reported whether or not the run answered,
      ## because a reader watching a number approach a bound needs it to be the
      ## number the bound is about.
    bound*: int
    instance*: WasmInstance
      ## The memory as the run left it. This is how the ABI reads a result:
      ## the module returns an ADDRESS and the bytes are read out of here.

  WasmInstance* = object
    ## A module's mutable state for one run. Separate from `WasmModule` so the
    ## module can be decoded once, admitted once, and run many times without a
    ## run being able to change what the next one starts from.
    memory*: seq[byte]

const
  MaxWasmBytes* = 64 * 1024
    ## The module itself, matching `layout.MaxDefinitionBytes`. The two are the
    ## same number because they bound the same thing — a file a repository
    ## ships — and a second number here would be a second thing to keep in step.

  MaxWasmTypes* = 64
  MaxWasmFunctions* = 256
  MaxWasmExports* = 32
  MaxWasmLocals* = 256
  MaxWasmParams* = 8
  MaxWasmBodyInstr* = 8192
    ## Per function. The decoder stops and refuses rather than growing a `seq`
    ## for as long as the file lasts.

  MaxWasmPages* = 4
    ## 256 KiB of linear memory. A visualiser renders one value and a diff
    ## compares two; neither is a workload, and the page count is ZEROED at
    ## instantiation so it is also a cost the module chooses for the host.

  WasmPageSize* = 65536

  MaxWasmStack* = 1024
    ## Operand stack depth.
  MaxWasmCallDepth* = 64

  MaxExecutableWork* = 1_000_000
    ## §7: "a diff algorithm must be total and bounded. A comparison that can
    ## loop or recurse without limit hangs a pane".
    ##
    ## IT IS A CONSTANT AND NOT A TIMEOUT, deliberately. A timeout makes the
    ## answer depend on the machine, which breaks §3.1's determinism — the same
    ## value must render identically across runs and front-ends — and it turns
    ## a security bound into a measurement that is different under load
    ## (Verification-Harness-Traps §12). A unit of work is the same unit on
    ## every host, so a module that answers here answers everywhere.
    ##
    ## The size is quoted against what a run of this ABI actually costs,
    ## MEASURED rather than estimated, and RE-MEASURED on 2026-09-13. The
    ## dominant term is the one page every fixture declares (65,536), so a run's
    ## marginal cost is what is worth reading:
    ##
    ##   | the run | `spent` |
    ##   |---|---|
    ##   | the needle visualiser, `runExport` alone (no input written, no text read) | 65,630 |
    ##   | the same through `visualiseWith`, input `"a value"` (7 bytes) | 65,666 |
    ##   | the same through `visualiseWith`, input `"a recorded value"` (16 bytes) | 65,675 |
    ##   | the byte-equality diff over two 5-byte buffers | 65,672 |
    ##   | the same over two 200-byte buffers | 70,157 |
    ##   | the same over two 4,096-byte buffers (`MaxExecutableInputBytes`) | 159,765 |
    ##
    ## **THE FIRST THREE ROWS USED TO BE ONE ROW, AND THAT WAS THE DEFECT.** It
    ## read "the needle visualiser, 29 bytes of output — 65,666", which names
    ## the module's OUTPUT and not the host's INPUT — and the input is a charged
    ## quantity (`prepare` spends `input.len`). A verification pass re-measured
    ## it at **65,675** and reported a stale number; both figures are right, for
    ## inputs nine bytes apart, and neither row said which. A measurement in a
    ## comment must name every input it depends on, or the next person to take
    ## it gets a different number and cannot tell a drifted bound from a
    ## differently-phrased question. Rows 4-6 reproduced exactly.
    ##
    ## So the allowance is ~6x the most expensive run this ABI can be ASKED for
    ## — a comparison of two inputs at the input bound — and the margin is
    ## deliberately not larger: a bound nothing can reach is a bound nobody has
    ## watched work, which is how PLAT-12's spent a day reporting a number it
    ## had never measured.

  WasmMagic* = "\0asm"

func problem(code: WasmProblemCode; at: int; detail: string): WasmProblem =
  WasmProblem(code: code, at: at, detail: detail)

func codeText*(c: WasmProblemCode): string =
  ## The human half of the code, written here rather than at each refusal site
  ## so one code cannot acquire two spellings (PLAT-11's `diagnostics.codeText`,
  ## same rule).
  case c
  of wpcEmpty: "the file is empty"
  of wpcNotWasm: "not a WebAssembly module"
  of wpcUnsupportedVersion: "a binary format version this build does not read"
  of wpcTruncated: "the module ends in the middle of something"
  of wpcMalformedInteger: "a malformed LEB128 integer"
  of wpcTooLarge: "a bound on the module was exceeded"
  of wpcImportDeclared: "the module imports something"
  of wpcUnsupportedSection: "a section this build does not implement"
  of wpcSectionOutOfOrder: "sections repeated or out of order"
  of wpcUnsupportedType: "a value type this build does not implement"
  of wpcUnsupportedBlockType: "a block type this build does not implement"
  of wpcUnsupportedOpcode: "an instruction this build does not implement"
  of wpcUnbalancedBlock: "a block with no matching end"
  of wpcBadIndex: "an index outside the module"
  of wpcNoSuchExport: "the module does not export what the host asked for"
  of wpcWrongSignature: "the exported function has the wrong signature"

func render*(p: WasmProblem): string =
  result = codeText(p.code)
  if p.detail.len > 0: result.add ": " & p.detail
  result.add " (at " & $p.at & ")"

func trapText*(t: WasmTrap): string =
  case t
  of wtNone: "no trap"
  of wtUnreachable: "the module executed 'unreachable'"
  of wtOutOfBounds: "a load or store outside the module's own memory"
  of wtDivideByZero: "a division by zero"
  of wtIntegerOverflow: "an integer division that overflows"
  of wtStackOverflow: "the operand stack or call depth bound"
  of wtStackUnderflow: "an operand was taken from an empty stack"
  of wtWorkExhausted: "the work bound"

# ---------------------------------------------------------------------------
# The cursor. Every read in this file goes through it.
# ---------------------------------------------------------------------------

type
  Cursor = object
    ## ONE BOUNDS-CHECKED READER, and the reason there is one is §14: a second
    ## place that indexes `data` is a second place that can be wrong while this
    ## one goes on agreeing with itself. Nothing below indexes the bytes
    ## directly.
    data: string
    pos: int
    failed: bool
    problem: WasmProblem

func fail(c: var Cursor; code: WasmProblemCode; detail: string) =
  if not c.failed:
    c.failed = true
    c.problem = problem(code, c.pos, detail)

func atEnd(c: Cursor): bool = c.pos >= c.data.len

func u8(c: var Cursor): int =
  if c.failed: return 0
  if c.pos >= c.data.len:
    c.fail(wpcTruncated, "a byte was wanted and the module ended")
    return 0
  result = int(uint8(c.data[c.pos]))
  inc c.pos

func bytes(c: var Cursor; n: int): string =
  if c.failed: return ""
  if n < 0 or c.pos + n > c.data.len:
    c.fail(wpcTruncated, $n & " byte(s) were wanted and the module ended")
    return ""
  result = c.data[c.pos ..< c.pos + n]
  c.pos += n

func u32leb(c: var Cursor): int =
  ## Unsigned LEB128, bounded at five bytes.
  ##
  ## THE FIVE-BYTE BOUND IS THE REFUSAL AND NOT A CONVENIENCE. A LEB128 with
  ## the continuation bit set for ever is the cheapest denial of service a
  ## binary format has, and "read until the top bit is clear" is how a decoder
  ## reads a whole file as one integer. Five bytes is what a 32-bit value
  ## needs; a sixth is a malformed integer, by name.
  ##
  ## PADDING INSIDE FIVE BYTES IS ACCEPTED, DELIBERATELY, AND THAT IS THE SPEC'S
  ## OWN RULE. `80 80 80 80 00` decodes to 0 here, and a verification pass read
  ## that as a deviation. It is not: WebAssembly's binary grammar for `uN` is
  ## recursive over at most `ceil(N/7)` bytes and constrains only the VALUE, so
  ## a 5-byte encoding of 0 is well-formed u32 and every conforming decoder
  ## accepts it (<https://webassembly.github.io/spec/core/binary/values.html>,
  ## §5.2.2). Refusing it would refuse modules real toolchains emit — relocatable
  ## objects pad LEB128s so a linker can patch them in place — and would be this
  ## decoder disagreeing with the format rather than restricting it. What the
  ## bound above refuses is a SIXTH byte, which the grammar does not allow
  ## either. `a padded LEB128 inside the five-byte bound is the spec's own
  ## encoding` is the case that pins the acceptance, so the asymmetry is
  ## falsifiable rather than argued (Verification-Harness-Traps §7a).
  if c.failed: return 0
  var shift = 0
  var value: uint64 = 0
  var read = 0
  while true:
    let b = c.u8()
    if c.failed: return 0
    inc read
    value = value or (uint64(b and 0x7F) shl shift)
    if (b and 0x80) == 0: break
    shift += 7
    if read >= 5:
      c.fail(wpcMalformedInteger,
             "an unsigned integer longer than five bytes")
      return 0
  if value > uint64(high(int32)):
    c.fail(wpcMalformedInteger, "an unsigned integer larger than 2^31-1")
    return 0
  int(value)

func i32leb(c: var Cursor): int32 =
  ## Signed LEB128, bounded at five bytes, sign-extended.
  if c.failed: return 0
  var shift = 0
  var value: uint32 = 0
  var read = 0
  var b = 0
  while true:
    b = c.u8()
    if c.failed: return 0
    inc read
    value = value or (uint32(b and 0x7F) shl shift)
    shift += 7
    if (b and 0x80) == 0: break
    if read >= 5:
      c.fail(wpcMalformedInteger, "a signed integer longer than five bytes")
      return 0
  if shift < 32 and (b and 0x40) != 0:
    value = value or (not uint32(0) shl shift)
  cast[int32](value)

func valType(c: var Cursor): ValType =
  ## `i32` and nothing else — see `ValType`.
  let b = c.u8()
  if c.failed: return vtI32
  if b != 0x7F:
    c.fail(wpcUnsupportedType,
           "value type 0x" & toHex(b, 2) & "; this build implements i32 only")
  vtI32

# ---------------------------------------------------------------------------
# Decoding a function body
# ---------------------------------------------------------------------------

func opOf(b: int): (Op, bool) =
  ## THE SUBSET, AS A TABLE. A byte that is not here is `wpcUnsupportedOpcode`,
  ## which is the "no unrecognised-and-ignored arm" rule (PLAT-11's `parse.nim`
  ## header) applied to a binary encoding.
  case b
  of 0x00: (opUnreachable, true)
  of 0x01: (opNop, true)
  of 0x02: (opBlock, true)
  of 0x03: (opLoop, true)
  of 0x04: (opIf, true)
  of 0x05: (opElse, true)
  of 0x0B: (opEnd, true)
  of 0x0C: (opBr, true)
  of 0x0D: (opBrIf, true)
  of 0x0F: (opReturn, true)
  of 0x10: (opCall, true)
  of 0x1A: (opDrop, true)
  of 0x1B: (opSelect, true)
  of 0x20: (opLocalGet, true)
  of 0x21: (opLocalSet, true)
  of 0x22: (opLocalTee, true)
  of 0x28: (opI32Load, true)
  of 0x2D: (opI32Load8U, true)
  of 0x36: (opI32Store, true)
  of 0x3A: (opI32Store8, true)
  of 0x3F: (opMemorySize, true)
  of 0x41: (opI32Const, true)
  of 0x45: (opI32Eqz, true)
  of 0x46: (opI32Eq, true)
  of 0x47: (opI32Ne, true)
  of 0x48: (opI32LtS, true)
  of 0x49: (opI32LtU, true)
  of 0x4A: (opI32GtS, true)
  of 0x4B: (opI32GtU, true)
  of 0x4C: (opI32LeS, true)
  of 0x4D: (opI32LeU, true)
  of 0x4E: (opI32GeS, true)
  of 0x4F: (opI32GeU, true)
  of 0x6A: (opI32Add, true)
  of 0x6B: (opI32Sub, true)
  of 0x6C: (opI32Mul, true)
  of 0x6D: (opI32DivS, true)
  of 0x6E: (opI32DivU, true)
  of 0x6F: (opI32RemS, true)
  of 0x70: (opI32RemU, true)
  of 0x71: (opI32And, true)
  of 0x72: (opI32Or, true)
  of 0x73: (opI32Xor, true)
  of 0x74: (opI32Shl, true)
  of 0x75: (opI32ShrS, true)
  of 0x76: (opI32ShrU, true)
  else: (opNop, false)

func decodeBody(c: var Cursor; endPos: int): seq[Instr] =
  ## Decode one function body into instructions, and RESOLVE the control flow.
  ##
  ## The nesting stack holds the index of each open `block`/`loop`/`if`, so the
  ## matching `end` is written into `target` as it is met rather than searched
  ## for afterwards. An `end` with nothing open terminates the body; an open
  ## block when the body ends is `wpcUnbalancedBlock`.
  var open: seq[int] = @[]
  var instrs: seq[Instr] = @[]
  while true:
    if c.failed: return instrs
    if c.pos >= endPos:
      c.fail(wpcUnbalancedBlock,
             "the body ended with " & $open.len & " block(s) still open")
      return instrs
    if instrs.len >= MaxWasmBodyInstr:
      c.fail(wpcTooLarge,
             "more than " & $MaxWasmBodyInstr & " instructions in one function")
      return instrs
    let raw = c.u8()
    if c.failed: return instrs
    let (op, known) = opOf(raw)
    if not known:
      c.fail(wpcUnsupportedOpcode,
             "opcode 0x" & toHex(raw, 2) & "; this build implements a closed " &
             "subset of wasm 1.0 with no imports, no floats and no indirect " &
             "calls")
      return instrs
    var ins = Instr(op: op, target: -1, alt: -1)
    case op
    of opBlock, opLoop, opIf:
      let bt = c.u8()
      if c.failed: return instrs
      if bt != 0x40:
        c.fail(wpcUnsupportedBlockType,
               "block type 0x" & toHex(bt, 2) & "; this build implements the " &
               "empty block type only, so a label carries no values")
        return instrs
      open.add instrs.len
    of opBr, opBrIf, opCall, opLocalGet, opLocalSet, opLocalTee:
      ins.imm = int32(c.u32leb())
    of opI32Const:
      ins.imm = c.i32leb()
    of opI32Load, opI32Load8U, opI32Store, opI32Store8:
      discard c.u32leb()               # alignment hint; advisory, ignored
      ins.memOffset = uint32(c.u32leb())
    of opMemorySize:
      let reserved = c.u8()
      if c.failed: return instrs
      if reserved != 0x00:
        c.fail(wpcBadIndex, "memory.size names memory " & $reserved &
               "; this build implements memory 0 only")
        return instrs
    of opElse:
      if open.len == 0:
        c.fail(wpcUnbalancedBlock, "an 'else' with no 'if' open")
        return instrs
      let ifIdx = open[^1]
      if instrs[ifIdx].op != opIf:
        c.fail(wpcUnbalancedBlock, "an 'else' closing a block that is not an 'if'")
        return instrs
      instrs[ifIdx].alt = int32(instrs.len)
    of opEnd:
      if open.len == 0:
        # The body's own terminating `end`.
        instrs.add ins
        return instrs
      let startIdx = open.pop()
      instrs[startIdx].target = int32(instrs.len)
      if instrs[startIdx].op == opIf and instrs[startIdx].alt >= 0:
        instrs[int(instrs[startIdx].alt)].target = int32(instrs.len)
    else:
      discard
    instrs.add ins

# ---------------------------------------------------------------------------
# Decoding a module
# ---------------------------------------------------------------------------

func decodeModule*(data: string): WasmDecode =
  ## Bytes to a module, or a named refusal. THE ONLY WAY A `WasmModule` IS
  ## CONSTRUCTED FROM UNTRUSTED BYTES.
  if data.len == 0:
    return WasmDecode(problem: problem(wpcEmpty, 0,
      "an executable definition with no bytes in it"))
  if data.len > MaxWasmBytes:
    return WasmDecode(problem: problem(wpcTooLarge, 0,
      $data.len & " bytes; the bound is " & $MaxWasmBytes))

  var c = Cursor(data: data)
  let magic = c.bytes(4)
  if c.failed: return WasmDecode(problem: c.problem)
  if magic != WasmMagic:
    return WasmDecode(problem: problem(wpcNotWasm, 0,
      "the first four bytes are not the WebAssembly magic"))
  let version = c.bytes(4)
  if c.failed: return WasmDecode(problem: c.problem)
  if version != "\1\0\0\0":
    return WasmDecode(problem: problem(wpcUnsupportedVersion, 4,
      "binary format version is not 1"))

  var m = WasmModule(byteCount: data.len, memoryPages: 0)
  var typeCounts: seq[int] = @[]   # function index -> type index
  var lastSection = 0
  var codeSeen = false

  while not c.atEnd and not c.failed:
    let sectionAt = c.pos
    let id = c.u8()
    if c.failed: break
    let size = c.u32leb()
    if c.failed: break
    let payloadStart = c.pos
    if payloadStart + size > data.len:
      c.fail(wpcTruncated, "section " & $id & " claims " & $size &
             " bytes and the module has " & $(data.len - payloadStart))
      break
    let payloadEnd = payloadStart + size

    if id != 0:
      # THE ORDER IS THE SPEC'S AND IT IS ENFORCED. Two `code` sections, or an
      # `export` before its `function`, are ways to say one thing twice; a
      # decoder that takes the last one read and a producer that meant the
      # first are how a module means two things.
      if id <= lastSection:
        c.fail(wpcSectionOutOfOrder,
               "section id " & $id & " after section id " & $lastSection)
        break
      lastSection = id

    case id
    of 0:
      # Custom. SKIPPED BY LENGTH AND NEVER PARSED — its contents are a name
      # table or a producer string and nothing here reads either.
      c.pos = payloadEnd
    of 1:
      let n = c.u32leb()
      if c.failed: break
      if n > MaxWasmTypes:
        c.fail(wpcTooLarge, $n & " types; the bound is " & $MaxWasmTypes)
        break
      for _ in 0 ..< n:
        let form = c.u8()
        if c.failed: break
        if form != 0x60:
          c.fail(wpcUnsupportedType, "a type that is not a function type")
          break
        var ft = FuncType()
        let np = c.u32leb()
        if c.failed: break
        if np > MaxWasmParams:
          c.fail(wpcTooLarge, $np & " parameters; the bound is " & $MaxWasmParams)
          break
        for _ in 0 ..< np: ft.params.add c.valType()
        let nr = c.u32leb()
        if c.failed: break
        if nr > 1:
          c.fail(wpcUnsupportedType,
                 "a function returning " & $nr & " values; wasm 1.0 allows one")
          break
        for _ in 0 ..< nr: ft.results.add c.valType()
        m.types.add ft
    of 2:
      # THE WHOLE SANDBOX, IN ONE REFUSAL. See the header.
      let n = c.u32leb()
      if c.failed: break
      if n != 0:
        c.fail(wpcImportDeclared,
               "the module declares " & $n & " import(s). An executable " &
               "project definition is handed NOTHING: it has no host " &
               "functions, so it cannot reach the network, the filesystem or " &
               "another process, and there is no grant that adds one " &
               "(Project-Definitions.md §2.3)")
        break
    of 3:
      let n = c.u32leb()
      if c.failed: break
      if n > MaxWasmFunctions:
        c.fail(wpcTooLarge, $n & " functions; the bound is " & $MaxWasmFunctions)
        break
      for _ in 0 ..< n:
        let t = c.u32leb()
        if c.failed: break
        if t >= m.types.len:
          c.fail(wpcBadIndex, "type index " & $t & " of " & $m.types.len)
          break
        typeCounts.add t
    of 5:
      let n = c.u32leb()
      if c.failed: break
      if n > 1:
        c.fail(wpcTooLarge, "more than one memory")
        break
      for _ in 0 ..< n:
        let kind = c.u8()
        if c.failed: break
        if kind notin {0x00, 0x01}:
          c.fail(wpcUnsupportedType, "a memory limit form this build does not read")
          break
        let minPages = c.u32leb()
        if kind == 0x01: discard c.u32leb()
        if c.failed: break
        if minPages > MaxWasmPages:
          c.fail(wpcTooLarge, $minPages & " pages; the bound is " & $MaxWasmPages &
                 " (" & $(MaxWasmPages * WasmPageSize) & " bytes), and the " &
                 "pages are zeroed at instantiation so the count is a cost the " &
                 "module chooses for the host")
          break
        m.memoryPages = minPages
    of 7:
      let n = c.u32leb()
      if c.failed: break
      if n > MaxWasmExports:
        c.fail(wpcTooLarge, $n & " exports; the bound is " & $MaxWasmExports)
        break
      for _ in 0 ..< n:
        let nameLen = c.u32leb()
        if c.failed: break
        let name = c.bytes(nameLen)
        if c.failed: break
        let kind = c.u8()
        if c.failed: break
        let idx = c.u32leb()
        if c.failed: break
        if kind != 0x00:
          c.fail(wpcUnsupportedSection,
                 "export '" & name & "' is not a function; this build exposes " &
                 "no table, memory or global to a host")
          break
        m.exports.add WasmExport(name: name, funcIndex: idx)
    of 10:
      codeSeen = true
      let n = c.u32leb()
      if c.failed: break
      if n != typeCounts.len:
        c.fail(wpcBadIndex, $n & " code bodies for " & $typeCounts.len &
               " declared function(s)")
        break
      for i in 0 ..< n:
        let bodySize = c.u32leb()
        if c.failed: break
        let bodyStart = c.pos
        if bodyStart + bodySize > payloadEnd:
          c.fail(wpcTruncated, "a function body runs past its section")
          break
        var fn = WasmFunction(typeIndex: typeCounts[i])
        let nLocalGroups = c.u32leb()
        if c.failed: break
        var localCount = 0
        for _ in 0 ..< nLocalGroups:
          let count = c.u32leb()
          if c.failed: break
          let vt = c.valType()
          if c.failed: break
          localCount += count
          if localCount > MaxWasmLocals:
            c.fail(wpcTooLarge, $localCount & " locals; the bound is " &
                   $MaxWasmLocals)
            break
          for _ in 0 ..< count: fn.localTypes.add vt
        if c.failed: break
        fn.body = c.decodeBody(bodyStart + bodySize)
        if c.failed: break
        if c.pos != bodyStart + bodySize:
          c.fail(wpcTruncated,
                 "a function body did not end where its length said it would")
          break
        m.functions.add fn
    of 4:
      c.fail(wpcUnsupportedSection,
             "a table section. This build implements no indirect calls, so a " &
             "table has nothing to hold")
    of 6:
      c.fail(wpcUnsupportedSection,
             "a global section. A module's state is its locals and its own " &
             "memory, both of which start clean on every run")
    of 8:
      c.fail(wpcUnsupportedSection,
             "a start section. A module runs when the HOST calls an export " &
             "and at no other time; a start function runs at instantiation, " &
             "which is before the host has decided anything")
    of 9, 11, 12:
      c.fail(wpcUnsupportedSection,
             "an element, data or data-count section. See the header: the " &
             "host writes the only bytes this ABI is about, and a data " &
             "section is a second way for a module's FILE to place bytes at " &
             "an address")
    else:
      c.fail(wpcUnsupportedSection, "section id " & $id)
    if c.failed: break
    if c.pos != payloadEnd and id != 0:
      c.fail(wpcTruncated, "section " & $id & " did not end where its length " &
             "said it would (declared at byte " & $sectionAt & ")")
      break

  if c.failed:
    return WasmDecode(problem: c.problem)
  if typeCounts.len > 0 and not codeSeen:
    return WasmDecode(problem: problem(wpcTruncated, data.len,
      "functions were declared and no code section followed"))
  for e in m.exports:
    if e.funcIndex >= m.functions.len:
      return WasmDecode(problem: problem(wpcBadIndex, 0,
        "export '" & e.name & "' names function " & $e.funcIndex & " of " &
        $m.functions.len))
  WasmDecode(ok: true, module: m)

# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

func exportedFunction*(m: WasmModule; name: string): int =
  ## The function index of an exported name, or -1. A linear scan over at most
  ## `MaxWasmExports` entries; there is no map, because a map would be a second
  ## representation of the same list.
  for e in m.exports:
    if e.name == name: return e.funcIndex
  -1

func instantiate*(m: WasmModule): WasmInstance =
  ## A clean instance. The memory is zeroed, so two runs of one module cannot
  ## communicate — which is §3.1's determinism requirement made structural
  ## rather than requested.
  WasmInstance(memory: newSeq[byte](m.memoryPages * WasmPageSize))

type
  Frame = object
    fn: int
    pc: int
    locals: seq[int32]
    stackBase: int
    labels: seq[Label]

  Label = object
    isLoop: bool
    start: int32     ## a loop branches to itself
    after: int32     ## a block or if branches past its `end`
    height: int      ## the operand stack height when the label was pushed

func instantiationCost*(m: WasmModule): int =
  ## What instantiating this module costs, as a number the host charges BEFORE
  ## it allocates. `newSeq[byte]` zeroes, so a module declaring four pages has
  ## asked the host for a quarter-megabyte of writes before a single
  ## instruction retires — a quantity the module chooses and the bound must
  ## therefore see (PLAT-12's lesson: a bound that does not see a quantity the
  ## input multiplies is a bound on the wrong quantity).
  m.memoryPages * WasmPageSize

proc runExportIn*(m: WasmModule; instance: WasmInstance; name: string;
                  args: openArray[int32]; work: int = MaxExecutableWork;
                  spentAlready = 0): WasmRun =
  ## Call an exported function in an instance the CALLER prepared — which is
  ## how the ABI hands a module its input, since a module has no way of its own
  ## to obtain bytes.
  ##
  ## `spentAlready` is what the caller has already charged for building that
  ## instance and filling it. It is a parameter rather than something this
  ## function recomputes, because the caller is the one that did the work and a
  ## second calculation of the same quantity here would be a second thing that
  ## can be wrong (§14).
  ##
  ## THE BOUND IS TESTED IN THE ONE LOOP EVERY INSTRUCTION PASSES THROUGH and
  ## CHARGED at the five sites that spend — see the header. A bound tested
  ## where the work is not done is PLAT-12's defect, and the shape of that
  ## defect is that the counter reports a number while the process does
  ## something the number is not about.
  ##
  ## THE BOUND IS TESTED IN THE ONE LOOP EVERY INSTRUCTION PASSES THROUGH and
  ## CHARGED at the five sites that spend — see the header. A bound tested
  ## where the work is not done is PLAT-12's defect, and the shape of that
  ## defect is that the counter reports a number while the process does
  ## something the number is not about.
  ##
  ## A MISSING EXPORT AND A WRONG ARITY ARE `ok = false` WITH NO TRAP, which is
  ## a third outcome rather than a rounding of the two: neither is a property of
  ## the run, and a caller told "the module trapped" about a module it called by
  ## the wrong name would go looking inside the module. `admitExecutable` in
  ## `project_executables.nim` refuses both before a run is ever attempted; this
  ## is the second, structural answer for a caller that did not.
  result.bound = work
  result.spent = spentAlready
  result.instance = instance

  var stack: seq[int32] = @[]
  var frames: seq[Frame] = @[]

  template spend(n: int): untyped =
    result.spent += n
    if result.spent > work:
      result.trap = wtWorkExhausted
      return

  template push(v: int32): untyped =
    if stack.len >= MaxWasmStack:
      result.trap = wtStackOverflow
      return
    stack.add v

  template pop(): int32 =
    if stack.len <= frames[^1].stackBase:
      result.trap = wtStackUnderflow
      return
    stack.pop()

  # The caller's charge is tested here rather than only added, so an allowance
  # already spent on instantiation and input stops the run before its first
  # instruction rather than after it.
  spend(0)

  let fi = m.exportedFunction(name)
  if fi < 0: return
  let ft0 = m.types[m.functions[fi].typeIndex]
  if args.len != ft0.params.len: return

  proc enter(fnIdx: int; m: WasmModule; stack: var seq[int32];
             frames: var seq[Frame]): bool =
    ## Push a frame, moving the parameters off the operand stack into locals.
    ## `false` on a depth failure or a missing operand; the caller turns that
    ## into the trap, because one reporting shape is better than two.
    if frames.len >= MaxWasmCallDepth: return false
    # NO `{.cursor.}` HERE, AND THAT IS MEASURED RATHER THAN AN OVERSIGHT —
    # see the two annotated bindings in `runExportIn` and the table at the
    # first of them. Nim 2.2.8's ORC infers a cursor for both of these, so an
    # explicit one is a second mechanism with no arm that can kill it, which
    # Verification-Harness-Traps §16a says to delete rather than keep. The
    # property is held by the CASES, which measure the cost per call and do not
    # care which mechanism delivers it.
    let fn = m.functions[fnIdx]
    let ft = m.types[fn.typeIndex]
    # THE CALLER'S OPERANDS ARE THE CALLER'S. A callee may take arguments only
    # from the operands its own caller pushed — `stackBase` is where the
    # caller's frame starts, and testing the WHOLE stack instead would let a
    # callee consume an OUTER frame's operands, which wasm's validator forbids
    # and which this interpreter has no other check against.
    # <https://webassembly.github.io/spec/core/valid/instructions.html>
    let base = (if frames.len > 0: frames[^1].stackBase else: 0)
    if stack.len - base < ft.params.len: return false
    var f = Frame(fn: fnIdx, pc: 0)
    f.locals = newSeq[int32](ft.params.len + fn.localTypes.len)
    for i in countdown(ft.params.len - 1, 0):
      f.locals[i] = stack.pop()
    f.stackBase = stack.len
    frames.add f
    true

  for a in args:
    if stack.len >= MaxWasmStack:
      result.trap = wtStackOverflow
      return
    stack.add a
  # THE ENTRY FRAME'S LOCALS ARE CHARGED like every other frame's.
  spend(ft0.params.len + m.functions[fi].localTypes.len)
  if not enter(fi, m, stack, frames):
    result.trap = wtStackOverflow
    return

  while frames.len > 0:
    spend(1)
    let fnIdx = frames[^1].fn
    # ONE INSTRUCTION IS ONE UNIT, AND THIS LINE IS WHAT MAKES THAT TRUE.
    #
    # `let body = m.functions[fnIdx].body` is a COPY of the whole function
    # body, taken once per retired instruction, so the run's real cost was
    # O(instructions x body length) while `spent` reported O(instructions) —
    # a bound that does not see a quantity the input multiplies, which is the
    # defect this file's header quotes PLAT-12 about, and the header carries
    # the measurement: 7.3 ms -> 7,819.8 ms at a body of 8,005 UNDER ORC, with
    # `spent` identical at 200,002 in both. Under refc the same line is a
    # refcount bump (21.8 ms -> 22.6 ms), so the defect was real in the ORC lane
    # that runs the cases and was never in a shipped binary — every shipped
    # build is refc. The header says which builds, and why the alias stays.
    #
    # `{.cursor.}` is a non-owning alias: `m` is a non-`var` parameter and is
    # not mutated anywhere in this loop, so the alias is valid for the whole
    # run. The header carries the full before/after; the case that holds it
    # down is "a body 1,600x longer spends the same AND takes the same time",
    # and arm W18 is what proves the case has teeth.
    #
    # TWO BINDINGS IN THIS FILE CARRY THE ANNOTATION AND FOUR DO NOT, AND THE
    # DIFFERENCE IS MEASURED. ORC infers a cursor for a `let` it can prove does
    # not outlive or alias-mutate its source, and it does so for `enter`'s `fn`
    # and `ft`, for `ret`'s `rft` and for `ft0` — removing the annotation from
    # any of them, or from all four at once, leaves the timing flat (7.4-9.0 ms
    # at every body length, 2026-09-13, ORC). It does NOT infer one here or at
    # `opCall`, which is what the 7,819.8 ms and 3,390.8 ms ORC rows are. So the
    # four redundant annotations were DELETED rather than kept: a mechanism
    # with no arm that can kill it is a row that looks like coverage
    # (Verification-Harness-Traps §16a), and arm W20 — written for `enter`'s
    # `fn` — SURVIVED, which is how this was found rather than argued.
    let body {.cursor.} = m.functions[fnIdx].body
    if frames[^1].pc < 0 or frames[^1].pc >= body.len:
      # A `pc` outside the body is refused HERE rather than asserted, because a
      # sandbox whose failure mode is a Defect is a sandbox that takes the host
      # down with it.
      #
      # IT SAID "UNREACHABLE BY CONSTRUCTION" UNTIL 2026-09-13, AND THAT WAS
      # FALSE. `if / else / else / end / end` decodes: each `else` writes its
      # own index into the enclosing `if`'s `alt`, so the SECOND one overwrites
      # the first, and the `end` resolves `instrs[alt].target` for that second
      # `else` only. The FIRST `else` keeps the `target = -1` it was built
      # with, and a run that falls out of the `then` arm lands on it, sets
      # `nextPc = -1`, and arrives here. The module traps and the host is fine
      # — so the GUARD earns its place; only the claim that nothing could reach
      # it did not. `a second 'else' is decoded, and falling out of the 'then'
      # arm traps rather than jumping to -1` is the case that pins it.
      result.trap = wtUnreachable
      return
    let ins = body[frames[^1].pc]
    var nextPc = frames[^1].pc + 1

    template ret(): untyped =
      ## Leave the current frame, carrying its result value if it has one, and
      ## go round the loop. THE `continue` IS LOAD-BEARING: without it control
      ## falls through to `frames[^1].pc = nextPc` at the bottom, which would
      ## write the CALLEE's next index over the CALLER's — a return that lands
      ## in the wrong function.
      let rft = m.types[m.functions[frames[^1].fn].typeIndex]
      var rv: int32 = 0
      if rft.results.len == 1:
        if stack.len <= frames[^1].stackBase:
          result.trap = wtStackUnderflow
          return
        rv = stack[^1]
      stack.setLen(frames[^1].stackBase)
      discard frames.pop()
      if rft.results.len == 1: stack.add rv
      if frames.len == 0:
        result.ok = true
        result.value = (if rft.results.len == 1: rv else: 0)
        return
      continue

    template branch(depth: int32): untyped =
      ## A branch to a depth past the outermost label is a branch to the
      ## FUNCTION's own implicit label, which is a return — wasm's own rule,
      ## and the reason a depth the decoder did not validate is still total.
      if depth < 0 or int(depth) >= frames[^1].labels.len:
        ret()
      else:
        let lbl = frames[^1].labels[frames[^1].labels.len - 1 - int(depth)]
        if stack.len > lbl.height: stack.setLen(lbl.height)
        if lbl.isLoop:
          frames[^1].labels.setLen(frames[^1].labels.len - int(depth))
          nextPc = int(lbl.start) + 1
        else:
          frames[^1].labels.setLen(frames[^1].labels.len - int(depth) - 1)
          nextPc = int(lbl.after) + 1

    template memAt(addend: int32; width: int): int =
      ## EVERY memory access goes through here, and the arithmetic is done in
      ## `uint64` so that a base near 2^32 plus an offset cannot wrap back into
      ## the memory (§14: one predicate, one function, and this is the one the
      ## sandbox's memory safety rests on).
      let base = uint64(cast[uint32](addend)) + uint64(ins.memOffset)
      if base + uint64(width) > uint64(result.instance.memory.len):
        result.trap = wtOutOfBounds
        return
      int(base)

    case ins.op
    of opUnreachable:
      result.trap = wtUnreachable
      return
    of opNop: discard
    of opBlock:
      frames[^1].labels.add Label(isLoop: false, start: int32(frames[^1].pc),
                                  after: ins.target, height: stack.len)
    of opLoop:
      frames[^1].labels.add Label(isLoop: true, start: int32(frames[^1].pc),
                                  after: ins.target, height: stack.len)
    of opIf:
      let cond = pop()
      frames[^1].labels.add Label(isLoop: false, start: int32(frames[^1].pc),
                                  after: ins.target, height: stack.len)
      if cond == 0:
        nextPc = (if ins.alt >= 0: int(ins.alt) + 1 else: int(ins.target))
    of opElse:
      # Reached by falling out of the `then` arm: skip the `else` arm entirely
      # and land on the matching `end`, which pops the label.
      nextPc = int(ins.target)
    of opEnd:
      if frames[^1].labels.len > 0:
        discard frames[^1].labels.pop()
      else:
        ret()
    of opBr: branch(ins.imm)
    of opBrIf:
      let cond = pop()
      if cond != 0: branch(ins.imm)
    of opReturn: ret()
    of opCall:
      if ins.imm < 0 or int(ins.imm) >= m.functions.len:
        result.trap = wtUnreachable
        return
      # AN ALIAS, NOT A COPY — see the `body` note above. `let callee =
      # m.functions[...]` copies the callee's whole body on every call, so a
      # call cost O(callee body length) against a charge of
      # O(params + locals). Measured under ORC: 11.4 ms -> 3,390.8 ms at a
      # callee body of 8,003, with `spent` identical at 200,002. Under refc the
      # binding is a refcount bump (35.8 ms -> 36.7 ms) — see the header for
      # which builds were ever affected.
      let callee {.cursor.} = m.functions[int(ins.imm)]
      spend(m.types[callee.typeIndex].params.len + callee.localTypes.len)
      frames[^1].pc = nextPc
      if not enter(int(ins.imm), m, stack, frames):
        result.trap = wtStackOverflow
        return
      continue
    of opDrop: discard pop()
    of opSelect:
      let c = pop()
      let b = pop()
      let a = pop()
      push(if c != 0: a else: b)
    of opLocalGet:
      if ins.imm < 0 or int(ins.imm) >= frames[^1].locals.len:
        result.trap = wtUnreachable
        return
      push(frames[^1].locals[int(ins.imm)])
    of opLocalSet:
      if ins.imm < 0 or int(ins.imm) >= frames[^1].locals.len:
        result.trap = wtUnreachable
        return
      frames[^1].locals[int(ins.imm)] = pop()
    of opLocalTee:
      if ins.imm < 0 or int(ins.imm) >= frames[^1].locals.len:
        result.trap = wtUnreachable
        return
      let v = pop()
      frames[^1].locals[int(ins.imm)] = v
      push(v)
    of opI32Load:
      let a = pop()
      let at = memAt(a, 4)
      var v: uint32 = 0
      for k in 0 ..< 4:
        v = v or (uint32(result.instance.memory[at + k]) shl (8 * k))
      push(cast[int32](v))
    of opI32Load8U:
      let a = pop()
      let at = memAt(a, 1)
      push(int32(result.instance.memory[at]))
    of opI32Store:
      let v = pop()
      let a = pop()
      let at = memAt(a, 4)
      let u = cast[uint32](v)
      for k in 0 ..< 4:
        result.instance.memory[at + k] = byte((u shr (8 * k)) and 0xFF'u32)
    of opI32Store8:
      let v = pop()
      let a = pop()
      let at = memAt(a, 1)
      result.instance.memory[at] = byte(cast[uint32](v) and 0xFF'u32)
    of opMemorySize:
      push(int32(result.instance.memory.len div WasmPageSize))
    of opI32Const: push(ins.imm)
    of opI32Eqz:
      let a = pop()
      push(if a == 0: 1'i32 else: 0'i32)
    of opI32Eq:
      let b = pop()
      let a = pop()
      push(if a == b: 1'i32 else: 0'i32)
    of opI32Ne:
      let b = pop()
      let a = pop()
      push(if a != b: 1'i32 else: 0'i32)
    of opI32LtS:
      let b = pop()
      let a = pop()
      push(if a < b: 1'i32 else: 0'i32)
    of opI32LtU:
      let b = pop()
      let a = pop()
      push(if cast[uint32](a) < cast[uint32](b): 1'i32 else: 0'i32)
    of opI32GtS:
      let b = pop()
      let a = pop()
      push(if a > b: 1'i32 else: 0'i32)
    of opI32GtU:
      let b = pop()
      let a = pop()
      push(if cast[uint32](a) > cast[uint32](b): 1'i32 else: 0'i32)
    of opI32LeS:
      let b = pop()
      let a = pop()
      push(if a <= b: 1'i32 else: 0'i32)
    of opI32LeU:
      let b = pop()
      let a = pop()
      push(if cast[uint32](a) <= cast[uint32](b): 1'i32 else: 0'i32)
    of opI32GeS:
      let b = pop()
      let a = pop()
      push(if a >= b: 1'i32 else: 0'i32)
    of opI32GeU:
      let b = pop()
      let a = pop()
      push(if cast[uint32](a) >= cast[uint32](b): 1'i32 else: 0'i32)
    of opI32Add:
      let b = pop()
      let a = pop()
      push(cast[int32](cast[uint32](a) + cast[uint32](b)))
    of opI32Sub:
      let b = pop()
      let a = pop()
      push(cast[int32](cast[uint32](a) - cast[uint32](b)))
    of opI32Mul:
      let b = pop()
      let a = pop()
      push(cast[int32](cast[uint32](a) * cast[uint32](b)))
    of opI32DivS:
      let b = pop()
      let a = pop()
      if b == 0:
        result.trap = wtDivideByZero
        return
      if a == low(int32) and b == -1'i32:
        # WASM DEFINES THIS AS A TRAP, and Nim's `div` would raise here, so the
        # two agree only because this arm exists.
        result.trap = wtIntegerOverflow
        return
      push(a div b)
    of opI32DivU:
      let b = pop()
      let a = pop()
      if b == 0:
        result.trap = wtDivideByZero
        return
      push(cast[int32](cast[uint32](a) div cast[uint32](b)))
    of opI32RemS:
      let b = pop()
      let a = pop()
      if b == 0:
        result.trap = wtDivideByZero
        return
      if a == low(int32) and b == -1'i32: push(0'i32)
      else: push(a mod b)
    of opI32RemU:
      let b = pop()
      let a = pop()
      if b == 0:
        result.trap = wtDivideByZero
        return
      push(cast[int32](cast[uint32](a) mod cast[uint32](b)))
    of opI32And:
      let b = pop()
      let a = pop()
      push(a and b)
    of opI32Or:
      let b = pop()
      let a = pop()
      push(a or b)
    of opI32Xor:
      let b = pop()
      let a = pop()
      push(a xor b)
    of opI32Shl:
      let b = pop()
      let a = pop()
      push(cast[int32](cast[uint32](a) shl (cast[uint32](b) and 31'u32)))
    of opI32ShrS:
      let b = pop()
      let a = pop()
      # ARITHMETIC, WRITTEN OUT. Nim's `shr` on a signed integer has changed
      # meaning across releases, and a shift whose sign behaviour depends on
      # the compiler is a visualiser that renders two different values on two
      # machines — §3.1's determinism, lost in one operator.
      let n = int(cast[uint32](b) and 31'u32)
      if a < 0:
        push(cast[int32](not ((not cast[uint32](a)) shr n)))
      else:
        push(cast[int32](cast[uint32](a) shr n))
    of opI32ShrU:
      let b = pop()
      let a = pop()
      push(cast[int32](cast[uint32](a) shr (cast[uint32](b) and 31'u32)))

    frames[^1].pc = nextPc

  result.ok = true

proc runExport*(m: WasmModule; name: string; args: openArray[int32];
                work: int = MaxExecutableWork): WasmRun =
  ## The whole of a run, for a caller that has no bytes to hand the module: a
  ## clean instance, its instantiation charged, and the call.
  ##
  ## IT IS A FORWARDER AND NOT A SECOND IMPLEMENTATION. `project_executables`
  ## takes the other route — instantiate, write, run — and if this function
  ## repeated the loop rather than calling it, the two would be two answers to
  ## "what does a run cost" (Verification-Harness-Traps §14).
  m.runExportIn(m.instantiate(), name, args, work, m.instantiationCost)

# ---------------------------------------------------------------------------
# The host's side of the memory
# ---------------------------------------------------------------------------

func writeBytes*(inst: var WasmInstance; at: int; data: string): bool =
  ## Put the host's input where the module can read it. BOUNDS-CHECKED against
  ## the instance's own memory, and `false` rather than a raise, so the caller
  ## has one shape for "the module cannot be given its input".
  if at < 0 or at + data.len > inst.memory.len: return false
  for i in 0 ..< data.len:
    inst.memory[at + i] = byte(data[i])
  true

func readCString*(inst: WasmInstance; at: int; bound: int): string =
  ## Read a NUL-terminated byte string out of the module's memory.
  ##
  ## THE BOUND IS THE HOST'S AND NOT THE MODULE'S. A module that never writes a
  ## NUL would otherwise decide how long the host's answer is, which is the
  ## module choosing the host's allocation — the shape §2.2's work bound exists
  ## to refuse. Reaching the bound returns what was read; the caller reports the
  ## truncation, because silently shortening somebody's output is the blank
  ## surface this campaign keeps refusing.
  if at < 0 or at >= inst.memory.len: return ""
  var i = at
  let stop = min(inst.memory.len, at + max(0, bound))
  while i < stop and inst.memory[i] != 0'u8:
    result.add char(inst.memory[i])
    inc i
