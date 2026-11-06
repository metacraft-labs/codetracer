## Native listings use runtime addresses, not platform-sized row indices.
## Exercise the shipped VM's JSON answer/move paths, including browser JS where
## int is 32-bit. The mock supplies only the transport needed to build the
## store; native_calltrace_jump_test.rs tests real instruction production.
import std/[json, jsonutils, unittest]
import ../../../../common/types as wire
import isonim/core/signals
import isonim/viewmodel
import ../../backend/[backend_service, mock_backend]
import ../../store/[replay_data_store, types]
import ../../viewmodels/low_level_code_vm

when defined(js):
  import std/jsffi
  proc parseWire(text: cstring): JsObject {.importjs: "JSON.parse(#)".}
  proc stringifyWire(value: JsObject): cstring {.importjs: "JSON.stringify(#)".}

proc desktopWireValue[T](text: string): T =
  # DapApi.on uses rawValue.to(T), a JS object cast rather than std/json.to.
  when defined(js):
    parseWire(cstring(text)).to(T)
  else:
    jsonTo(parseJson(text), T, Joptions(allowMissingKeys: true))

const
  NativeBase = 0x555500001000'i64
  NativePC = 0x555500001001'i64
  Listing = """{"address":93823560585216,"error":"","instructions":[
    {"name":"push","args":"rbp","other":"","offset":93823560585216,"highLevelPath":"main.c","highLevelLine":13},
    {"name":"mov","args":"rbp,rsp","other":"","offset":93823560585217,"highLevelPath":"main.c","highLevelLine":13}]}"""

proc setup(): LowLevelCodeVM =
  let mock = newMockBackendService(autoRespond = true)
  createLowLevelCodeVM(createReplayDataStore(mock.toBackendService()))

suite "native listing addresses survive native and JS boundaries":
  test "the listing preserves ASLR addresses and displays every digit":
    let vm = setup()
    defer: vm.dispose()
    vm.applyAsmAnswer(parseJson(Listing), AsmFunctionLocation(path: "main.c", name: "main", line: 13))
    check vm.address.val == NativeBase
    check vm.instructions.val[0].offset == NativeBase
    check vm.instructions.val[1].offset == NativePC
    check formatOffset(vm.instructions.val[1], false) == "93823560585217"
    check addressText(vm.address.val) == "Originating address: 0x0000555500001000"
    let rows = vm.displayRows()
    check rows.len == 3
    check rows[2].offsetText == "93823560585217"

  test "moves retain the selected frame PC and the location fallback":
    let vm = setup()
    defer: vm.dispose()
    vm.store.applyStopLocation(parseJson("""{"location":{"offset":93823560585216},"frameInfo":{"hasSelected":true,"offset":93823560585217}}"""))
    check vm.store.stop.val.frameOffset == NativePC
    vm.store.applyStopLocation(parseJson("""{"location":{"offset":93823560585216},"frameInfo":{"hasSelected":false}}"""))
    check vm.store.stop.val.frameOffset == NativeBase
    vm.store.applyStopLocation(parseJson("""{"frameInfo":{"hasSelected":false}}"""))
    check vm.store.stop.val.frameOffset == -1

  test "the full PC selects the second instruction":
    let vm = setup()
    defer: vm.dispose()
    vm.applyAsmAnswer(parseJson(Listing), AsmFunctionLocation(path: "main.c", name: "main", line: 13))
    vm.store.applyStopLocation(parseJson("""{"location":{"offset":93823560585217}}"""))
    check vm.executionIndex == 1
    let rows = vm.displayRows()
    check rows[2].executing
    check not rows[1].executing

  test "addresses beyond 48 bits retain adjacent instruction precision":
    let vm = setup()
    defer: vm.dispose()
    vm.applyAsmAnswer(parseJson("""{"address":375298537295872,"error":"","instructions":[
      {"name":"push","offset":375298537295872,"highLevelPath":"main.c","highLevelLine":13},
      {"name":"mov","offset":375298537295873,"highLevelPath":"main.c","highLevelLine":13}]}"""),
      AsmFunctionLocation(path: "main.c", name: "main", line: 13))
    vm.store.applyStopLocation(parseJson("""{"location":{"offset":375298537295873}}"""))
    check vm.address.val == 0x1555500001000'i64
    check vm.executionIndex == 1
    check addressText(vm.address.val) == "Originating address: 0x0001555500001000"
    check formatOffset(vm.instructions.val[1], false) == "375298537295873"

  test "the common desktop wire types retain instruction and move widths":
    let listing = desktopWireValue[wire.Instructions](Listing)
    check sizeof(listing.address) == 8
    check sizeof(listing.instructions[0].offset) == 8
    check listing.address == NativeBase
    check listing.instructions[1].offset == NativePC
    # The desktop receives the complete Location object, including its
    # string/sequence fields; populate those unrelated fields with defaults.
    var moveWire = newJObject()
    for name, value in fieldPairs(wire.Location()):
      when value is string: moveWire[name] = %""
      elif value is seq: moveWire[name] = newJArray()
      elif value is bool: moveWire[name] = %false
      else: moveWire[name] = %0
    moveWire["offset"] = parseJson("93823560585217")
    moveWire["originatingInstructionAddress"] = parseJson("93823560585217")
    let location = desktopWireValue[wire.Location]($moveWire)
    let frame = desktopWireValue[wire.FrameInfo]("""{"offset":93823560585217,"hasSelected":true}""")
    check sizeof(location.offset) == 8
    check sizeof(location.originatingInstructionAddress) == 8
    check sizeof(frame.offset) == 8
    check location.offset == NativePC
    check location.originatingInstructionAddress == NativePC
    check frame.offset == NativePC
    when defined(js):
      # The middleware forwards the typed Instructions with toJs. Ensure
      # this same relay still supplies a serializable native answer to the VM.
      let relayed = parseJson($stringifyWire(listing.toJs))
      check relayed["address"].getBiggestInt == NativeBase
      check relayed["instructions"][1]["offset"].getBiggestInt == NativePC
