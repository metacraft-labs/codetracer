## common/executable_value_abi.nim — a recorded value, encoded for a project's
## executable definition (Project-Definitions §7.1, ABI version 2).
##
## Version 1 handed a module the value's one-line RENDERING, so a module could
## not ask how many members a record has or what they are called. Version 2
## hands it the value as a tree, in a byte layout small enough to walk with the
## `i32`/`i64` loads the sandbox implements:
##
##   byte 0       completeness flag: 1 complete, 0 truncated
##   then, per node:
##     u8         kind   (`AbiKind`)
##     u16 + n    type name
##     u16 + n    text   (the scalar payload)
##     u16        member count — the members actually written
##     per member: u16 + n label, then the member's node
##
## All integers little-endian. Depth is capped at `MaxAbiDepth`, the whole
## encoding at `MaxExecutableInputBytes`; past either, members are left out,
## the container's count says how many were written, and the flag is 0 — so a
## module is never handed a count that disagrees with the bytes after it.
##
## PURE AND TOTAL: no I/O, every recursion bounded by depth and by the output
## budget, and it never raises.

import ./value_presentation
from ./project_executables import MaxExecutableInputBytes

type
  AbiKind* = enum
    akNil = 0, akInt = 1, akFloat = 2, akBool = 3, akString = 4, akChar = 5,
    akEnum = 6, akSequence = 7, akRecord = 8, akTuple = 9, akMap = 10,
    akVariant = 11, akPointer = 12, akOther = 13

const
  MaxAbiDepth* = 8
  MaxAbiField* = 1024
    ## The longest type name or text one node carries; a longer one is cut
    ## and the flag says the tree is truncated.

func abiKindOf*(k: PValueKind): AbiKind =
  case k
  of pvkNil: akNil
  of pvkInt: akInt
  of pvkFloat: akFloat
  of pvkBool: akBool
  of pvkString, pvkCString: akString
  of pvkChar: akChar
  of pvkEnum: akEnum
  of pvkSequence: akSequence
  of pvkRecord: akRecord
  of pvkTuple: akTuple
  of pvkMap: akMap
  of pvkVariant: akVariant
  of pvkPointer, pvkReference: akPointer
  else: akOther

func u16(n: int): string =
  let v = min(n, 0xFFFF)
  $char(v and 0xFF) & $char((v shr 8) and 0xFF)

func field(s: string): string =
  let t = if s.len > MaxAbiField: s[0 ..< MaxAbiField] else: s
  u16(t.len) & t

func headerOf(v: PValue; complete: var bool): string =
  let text = if v.kind == pvkEnum and v.enumName.len > 0: v.enumName
             else: v.text
  if v.typeName.len > MaxAbiField or text.len > MaxAbiField:
    complete = false
  result = $char(ord(abiKindOf(v.kind)))
  result.add field(v.typeName)
  result.add field(text)

func encodeNode(v: PValue; depth: int; budget: int; complete: var bool): string =
  ## One node and as many of its members as fit in `budget` bytes.
  if v.isNil:
    return $char(ord(akNil)) & u16(0) & u16(0) & u16(0)
  result = headerOf(v, complete)
  var members: seq[(string, PValue)] = @[]
  case v.kind
  of pvkMap:
    for e in v.entries: members.add ("", PValue(kind: pvkTuple,
      typeName: "entry", members: @[PMember(value: e.key), PMember(value: e.val)]))
  of pvkPointer, pvkReference:
    if not v.target.isNil: members.add ("*", v.target)
  else:
    for m in v.members: members.add (m.label, m.value)
  var body = ""
  var written = 0
  if depth >= MaxAbiDepth and members.len > 0:
    complete = false
  else:
    for (label, child) in members:
      let room = budget - result.len - 2 - body.len
      if room <= 0:
        complete = false
        break
      let enc = field(label) & encodeNode(child, depth + 1, room - 2 - label.len,
                                          complete)
      if enc.len > room:
        complete = false
        break
      body.add enc
      inc written
  if written < members.len: complete = false
  result.add u16(written)
  result.add body

func encodeStructuredValue*(v: PValue;
                            budget = MaxExecutableInputBytes): string =
  ## The ABI version 2 input for `v`: the completeness flag, then the tree.
  var complete = true
  let tree = encodeNode(v, 0, budget - 1, complete)
  (if complete: "\1" else: "\0") & tree
