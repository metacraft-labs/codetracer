## when_expr.nim — a binding's `when` condition: VS Code's subset, parsed once
## and evaluated against `context_keys.ContextKeys`.
##
## Owns: Base-Keymaps-And-Layer-Stack.md §4.1's grammar —
##
##     expr   := or
##     or     := and ( "||" and )*
##     and    := unary ( "&&" unary )*
##     unary  := "!" unary | "(" expr ")" | atom
##     atom   := key | key "==" value | key "!=" value
##
## — its evaluation, and `canBothHold`, the exact overlap test §5.6 decides
## base conflicts with.
##
## **AN UNKNOWN KEY IS A PARSE ERROR, NOT `false`.** A misspelt key that
## evaluated false would disable its binding with no report (§4.1). So is a
## comparison against a value outside the key's closed domain, and a bare key
## that is not a bool. VS Code's `=~`, `in` and the numeric comparisons are not
## taken: no condition of this product needs them.
##
## Pure, no I/O; compiles on C, JS and wasm32.

import std/strutils

import ./context_keys

export context_keys

type
  WhenKind* = enum
    wkTrue, wkKey, wkEq, wkNe, wkNot, wkAnd, wkOr

  WhenExpr* = ref object
    ## The parsed condition. `wkTrue` is the empty `when` — always.
    case kind*: WhenKind
    of wkTrue: discard
    of wkKey, wkEq, wkNe:
      key*: ContextKey
      value*: string
    of wkNot:
      operand*: WhenExpr
    of wkAnd, wkOr:
      left*, right*: WhenExpr

  WhenParse* = object
    ok*: bool
    expr*: WhenExpr
    message*: string

  Lexer = object
    text: string
    pos: int

func alwaysTrue*(): WhenExpr = WhenExpr(kind: wkTrue)

proc skipSpace(lx: var Lexer) =
  while lx.pos < lx.text.len and lx.text[lx.pos] == ' ': inc lx.pos

proc peekOp(lx: var Lexer; op: string): bool =
  lx.skipSpace()
  lx.text.continuesWith(op, lx.pos)

proc readWord(lx: var Lexer): string =
  lx.skipSpace()
  if lx.pos < lx.text.len and lx.text[lx.pos] in {'\'', '"'}:
    let q = lx.text[lx.pos]
    inc lx.pos
    let start = lx.pos
    while lx.pos < lx.text.len and lx.text[lx.pos] != q: inc lx.pos
    result = lx.text[start ..< min(lx.pos, lx.text.len)]
    if lx.pos < lx.text.len: inc lx.pos
    return
  let start = lx.pos
  while lx.pos < lx.text.len and
        lx.text[lx.pos] in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}:
    inc lx.pos
  lx.text[start ..< lx.pos]

proc parseOr(lx: var Lexer; err: var string): WhenExpr

proc parseUnary(lx: var Lexer; err: var string): WhenExpr =
  if err.len > 0: return nil
  if lx.peekOp("!") and not lx.peekOp("!="):
    inc lx.pos
    let inner = parseUnary(lx, err)
    if inner.isNil: return nil
    return WhenExpr(kind: wkNot, operand: inner)
  if lx.peekOp("("):
    inc lx.pos
    let inner = parseOr(lx, err)
    if inner.isNil: return nil
    if not lx.peekOp(")"):
      err = "a '(' is not closed"
      return nil
    inc lx.pos
    return inner
  let name = lx.readWord()
  if name.len == 0:
    err = "expected a context key at column " & $(lx.pos + 1)
    return nil
  var key: ContextKey
  if not parseContextKey(name, key):
    err = "unknown context key '" & name & "'"
    return nil
  for negated in [false, true]:
    if lx.peekOp(if negated: "!=" else: "=="):
      lx.pos += 2
      let value = lx.readWord()
      if value notin domainOf(key):
        err = "'" & value & "' is not a value of '" & name & "' (" &
              domainOf(key).join(", ") & ")"
        return nil
      return (if negated: WhenExpr(kind: wkNe, key: key, value: value)
              else: WhenExpr(kind: wkEq, key: key, value: value))
  if not isBoolKey(key):
    err = "'" & name & "' is not a boolean; compare it with == or !="
    return nil
  WhenExpr(kind: wkKey, key: key, value: "true")

proc parseAnd(lx: var Lexer; err: var string): WhenExpr =
  result = parseUnary(lx, err)
  while not result.isNil and lx.peekOp("&&"):
    lx.pos += 2
    let rhs = parseUnary(lx, err)
    if rhs.isNil: return nil
    result = WhenExpr(kind: wkAnd, left: result, right: rhs)

proc parseOr(lx: var Lexer; err: var string): WhenExpr =
  result = parseAnd(lx, err)
  while not result.isNil and lx.peekOp("||"):
    lx.pos += 2
    let rhs = parseAnd(lx, err)
    if rhs.isNil: return nil
    result = WhenExpr(kind: wkOr, left: result, right: rhs)

proc parseWhen*(text: string): WhenParse =
  ## `text` → a condition, or the reason it is not one. The empty text is
  ## `wkTrue`.
  if text.strip().len == 0:
    return WhenParse(ok: true, expr: alwaysTrue(), message: "")
  var lx = Lexer(text: text, pos: 0)
  var err = ""
  let e = parseOr(lx, err)
  if e.isNil:
    return WhenParse(ok: false, expr: nil, message: err)
  lx.skipSpace()
  if lx.pos < lx.text.len:
    return WhenParse(ok: false, expr: nil,
                     message: "unexpected '" & lx.text[lx.pos .. ^1] & "'")
  WhenParse(ok: true, expr: e, message: "")

func evalWhen*(e: WhenExpr; c: ContextKeys): bool =
  if e.isNil: return true
  case e.kind
  of wkTrue: true
  of wkKey, wkEq: c.values[e.key] == e.value
  of wkNe: c.values[e.key] != e.value
  of wkNot: not evalWhen(e.operand, c)
  of wkAnd: evalWhen(e.left, c) and evalWhen(e.right, c)
  of wkOr: evalWhen(e.left, c) or evalWhen(e.right, c)

func keysOf(e: WhenExpr; acc: var seq[ContextKey]) =
  if e.isNil: return
  case e.kind
  of wkTrue: discard
  of wkKey, wkEq, wkNe:
    if e.key notin acc: acc.add e.key
  of wkNot: keysOf(e.operand, acc)
  of wkAnd, wkOr:
    keysOf(e.left, acc)
    keysOf(e.right, acc)

func canBothHold*(a, b: WhenExpr): bool =
  ## Whether some assignment of the keys the two conditions read makes both
  ## true — §5.6's conflict test, **decided by enumeration over the closed
  ## domains**, which is exact because every key is a bool or a closed enum.
  var keys: seq[ContextKey] = @[]
  keysOf(a, keys)
  keysOf(b, keys)
  var c = defaultContextKeys()
  var idx = newSeq[int](keys.len)
  while true:
    for i, k in keys: c.values[k] = domainOf(k)[idx[i]]
    if evalWhen(a, c) and evalWhen(b, c): return true
    var i = 0
    while i < keys.len:
      inc idx[i]
      if idx[i] < domainOf(keys[i]).len: break
      idx[i] = 0
      inc i
    if i == keys.len: return false
