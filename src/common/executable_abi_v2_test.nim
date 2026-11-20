## executable_abi_v2_test.nim — the executable ABI, version 2
## (Project-Definitions §7.1): a `data` section, `i64`, and a structured value.
##
## Real WebAssembly modules (`project_wasm_fixtures`), decoded and run by the
## real sandbox, admitted under a real trust ledger value. NO MOCKS.
##
## Compile and run (lane `common-units`):
##   nim c -r src/common/executable_abi_v2_test.nim

import std/[strutils, unittest]

import ./project_wasm
import ./project_wasm_fixtures
import ./project_executables
import ./project_definitions/layout
import ./executable_value_abi
import ./value_presentation

const Identity = "fs2:1:2:3"

proc admitted(kind: DefinitionFileKind; bytes: string;
              ledger: var ProjectTrustLedger): ExecutableDefinition =
  let digest = "sha256:abi-v2-" & $bytes.len
  discard ledger.grant(Identity, kind, digest, "2026-11-20T00:00:00Z", "/c")
  let a = admitExecutable(kind, definitionPath("", kind), digest, bytes,
                          admit(ledger, Identity, kind, digest), Identity)
  doAssert a.ok, render(a.problem)
  a.definition

suite "a data section":

  test "a segment is in memory before the first instruction, and is charged":
    let module = buildWasm([FixtureFunc(params: 2, results: 1,
      body: i32Const(64), exportName: "ct_visualise")]) &
      dataSection([(64, "from the data section\0")])
    let d = decodeModule(module)
    check d.ok
    check d.module.data.len == 1
    check d.module.instantiationCost == WasmPageSize + 22
    var ledger: ProjectTrustLedger
    let def = admitted(dfkVisualiserCode, module, ledger)
    let t = def.visualiseWith(ledger, "anything")
    check t.fromDefinition
    check t.text == "from the data section"

  test "a segment outside the declared memory is refused by name":
    let module = buildWasm([FixtureFunc(params: 2, results: 1,
      body: i32Const(0), exportName: "ct_visualise")]) &
      dataSection([(WasmPageSize - 2, "four")])
    let d = decodeModule(module)
    check not d.ok
    check d.problem.code == wpcBadIndex
    check "outside the declared memory" in d.problem.detail

  test "a passive segment is refused":
    let module = buildWasm([FixtureFunc(params: 2, results: 1,
      body: i32Const(0), exportName: "ct_visualise")]) &
      section(11, vec([uleb(1) & uleb(3) & "abc"]))
    let d = decodeModule(module)
    check not d.ok
    check d.problem.code == wpcUnsupportedSection

suite "i64":

  test "i64 arithmetic past 32 bits, and the conversions":
    # (5_000_000_000 * 3) / 1_000_000_000 = 15, wrapped to i32.
    let body = i64Const(5_000_000_000) & i64Const(3) & I64Mul &
               i64Const(1_000_000_000) & I64DivS & I32WrapI64
    let run = buildWasm([FixtureFunc(params: 0, results: 1, body: body,
                                     exportName: "f")]).decodeModule.module
                .runExport("f", [])
    check run.ok
    check run.value == 15

  test "an i64 local and a comparison past 32 bits":
    # local 0 (i64) = 4_294_967_296; result = local0 >u 4_294_967_295
    let body = i64Const(4_294_967_296) & localSet(0) &
               localGet(0) & i64Const(4_294_967_295) & I64GtU
    let d = decodeModule(buildWasm([FixtureFunc(params: 0, results: 1,
      i64Locals: 1, body: body, exportName: "f")]))
    check d.ok
    let run = d.module.runExport("f", [])
    check run.ok
    check run.value == 1

  test "an i64 division by zero traps":
    let run = buildWasm([FixtureFunc(params: 0, results: 1,
      body: i64Const(1) & i64Const(0) & I64DivS & I32WrapI64,
      exportName: "f")]).decodeModule.module.runExport("f", [])
    check not run.ok
    check run.trap == wtDivideByZero

  test "a float is still refused":
    let d = decodeModule(buildWasm([FixtureFunc(params: 0, results: 0,
      body: "\x43\0\0\0\0\x1A", exportName: "f")]))
    check not d.ok
    check d.problem.code == wpcUnsupportedOpcode

suite "a structured value":

  proc pair(): PValue =
    PValue(kind: pvkTuple, typeName: "Tuple", members: @[
      PMember(value: PValue(kind: pvkInt, typeName: "Int", text: "3")),
      PMember(value: PValue(kind: pvkInt, typeName: "Int", text: "4"))])

  test "the encoding is the layout the spec states":
    let e = encodeStructuredValue(pair())
    check e[0] == '\1'                       # complete
    check ord(e[1]) == ord(akTuple)
    check ord(e[2]) == 5 and ord(e[3]) == 0  # "Tuple"
    check e[4 .. 8] == "Tuple"
    check ord(e[9]) == 0 and ord(e[10]) == 0 # no text
    check ord(e[11]) == 2 and ord(e[12]) == 0 # two members
    # first member: empty label, then an Int "3"
    check ord(e[13]) == 0 and ord(e[14]) == 0
    check ord(e[15]) == ord(akInt)
    check e[18 .. 20] == "Int"
    check e[23] == '3'

  test "a value past the budget is truncated, and says so":
    var wide = PValue(kind: pvkSequence, typeName: "list")
    for k in 0 ..< 2000:
      wide.members.add PMember(value: PValue(kind: pvkInt, typeName: "Int",
                                             text: $k))
    let e = encodeStructuredValue(wide)
    check e.len <= MaxExecutableInputBytes
    check e[0] == '\0'
    let written = ord(e[1 + 1 + 2 + 4 + 2]) + 256 * ord(e[1 + 1 + 2 + 4 + 3])
    check written > 0 and written < 2000

  test "a module that speaks version 2 counts the members it was handed":
    # Reads the member count at input + 11 and answers it as one digit.
    let body = i32Const(16) & localGet(0) & i32Load8U(11) & i32Const(48) &
               I32Add & i32Store8() & i32Const(17) & i32Const(0) &
               i32Store8() & i32Const(16)
    let module = buildWasm([FixtureFunc(params: 2, results: 1, body: body,
                                        exportName: "ct_visualise_value")])
    var ledger: ProjectTrustLedger
    let def = admitted(dfkVisualiserCode, module, ledger)
    check def.takesStructuredValues
    check def.hasEntryPoint
    let t = def.visualiseWith(ledger, executableInputOf(pair()),
                              valueInput = encodeStructuredValue(pair()))
    check t.fromDefinition
    check t.text == "2"

  test "a version 1 module is still handed the rendering":
    var ledger: ProjectTrustLedger
    let def = admitted(dfkVisualiserCode, echoLengthModule(), ledger)
    check not def.takesStructuredValues
    let t = def.visualiseWith(ledger, "(3, 4)",
                              valueInput = encodeStructuredValue(pair()))
    check t.text == "06"
