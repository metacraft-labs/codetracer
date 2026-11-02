## user_keymap.nim — THE USER LAYER: one `keybindings.json` for every
## front-end, read by one loader.
##
## Owns: Base-Keymaps-And-Layer-Stack.md §3.4 — the file's shape (VS Code's
## `keybindings.json`: `key`, `command`, `when`, `args`, `-command` to remove
## a base row, plus `base` and `include`), its parse into rows, and the closed
## set of reasons a row does not load, each reported with its index and its
## text.
##
## Refuses to own: where the file lives and when it is re-read (the native
## hosts, `host/keybindings_file`; the browser's storage), how the rows are
## layered over a base (`keymap_router`), and the shipped sets an `include`
## names (`binding_sets`).
##
## **EVERY ROW IS ACCOUNTED FOR.** PLAT-31's rule — *"a keymap that ignores
## what it cannot parse is a keymap that tells the user their binding works"*
## — holds per row: a row loads, or it is in `errors` with a kind from
## `UserRowErrorKind`. A row the front-end cannot DELIVER (§7.4) is judged by
## the router, which knows the front-end.
##
## The file is JSONC, as VS Code's is: `//` and `/* */` comments and trailing
## commas are accepted, so a VS Code user's own file parses.
##
## Pure; compiles on C, JS and wasm32 — the desktop calls this code, not a
## TypeScript port (§3.5).

import std/[json, strutils]

import ./base_rows
import ./binding_sets
import ./editing_keymap
import ./when_expr

type
  UserRowErrorKind* = enum
    ## §3.4's closed set.
    ueBadJson = "bad JSON"
    ueUnknownCommand = "unknown command"
    ueUnknownContextKey = "unknown context key"
    ueMalformedWhen = "malformed when"
    ueMalformedKey = "malformed key"
    ueUnknownBase = "unknown base"
    ueUnknownInclude = "unknown include"
    ueUndeliverable = "a chord this front-end cannot deliver"

  UserRowError* = object
    kind*: UserRowErrorKind
    index*: int
      ## The row's position in the file (0-based); -1 for the whole file.
    text*: string
      ## The row as written.
    message*: string

  UserRow* = object
    index*: int
      ## The position in the file; a row an `include` brought in carries the
      ## include's index.
    origin*: string
      ## "" for the user's own row, else the binding set that supplied it.
    keyText*: string
      ## The key as written, for reports and displays.
    chords*: seq[string]
      ## Canonical names (`key_names.normalizeChordSequence`).
    operation*: string
      ## Vocabulary name bare, catalogued name with its namespace.
    argument*: string
    whenText*: string
    cond*: WhenExpr
    base*: string
      ## "" applies over every base; else the one base it applies over.
    removal*: bool
      ## `-command`: removes the base row with this key and command (and
      ## `when`, when given).

  UserKeymap* = object
    rows*: seq[UserRow]
    errors*: seq[UserRowError]
    total*: int
      ## Entries in the file, includes counted once.

func stripJsonc*(text: string): string =
  ## Comments and trailing commas out, strings untouched — VS Code's
  ## `keybindings.json` is JSONC.
  result = newStringOfCap(text.len)
  var i = 0
  var inString = false
  while i < text.len:
    let c = text[i]
    if inString:
      result.add c
      if c == '\\' and i + 1 < text.len:
        result.add text[i + 1]
        i += 2
        continue
      if c == '"': inString = false
      inc i
      continue
    if c == '"':
      inString = true
      result.add c
      inc i
    elif c == '/' and i + 1 < text.len and text[i + 1] == '/':
      while i < text.len and text[i] != '\n': inc i
    elif c == '/' and i + 1 < text.len and text[i + 1] == '*':
      i += 2
      while i + 1 < text.len and not (text[i] == '*' and text[i + 1] == '/'):
        inc i
      i += 2
    elif c == ',':
      var j = i + 1
      while j < text.len and text[j] in {' ', '\t', '\r', '\n'}: inc j
      if j < text.len and text[j] in {']', '}'}:
        inc i
      else:
        result.add c
        inc i
    else:
      result.add c
      inc i

func rowText(n: JsonNode): string = $n

func argumentOf(n: JsonNode): (bool, string) =
  ## A row's `args`: absent, a number or a string — what a catalogued
  ## operation's one argument can be.
  if n.isNil: return (true, "")
  case n.kind
  of JInt: (true, $n.getInt)
  of JString: (true, n.getStr)
  of JNull: (true, "")
  else: (false, "")

proc parseRow(entry: JsonNode; index: int; origin: string;
              result: var UserKeymap) =
  template fail(k: UserRowErrorKind; msg: string) =
    result.errors.add UserRowError(kind: k, index: index,
                                   text: rowText(entry), message: msg)
    return
  if entry.kind != JObject:
    fail(ueBadJson, "a row is an object")
  if entry.hasKey("include"):
    let name = entry["include"]
    if name.kind != JString or bindingSetIndex(name.getStr) < 0:
      fail(ueUnknownInclude, "'" & $name & "' is not a binding set (" &
           "stepping:codetracer, stepping:vscode, stepping:chorded, " &
           "stepping:none)")
    for r in BindingSets[bindingSetIndex(name.getStr)].rows:
      parseRow(%*{"key": r.key, "command": r.command, "when": r.whenText},
               index, name.getStr, result)
    return
  let keyNode = entry.getOrDefault("key")
  if keyNode.isNil or keyNode.kind != JString:
    fail(ueMalformedKey, "a row needs a \"key\"")
  let chords = normalizeChordSequence(keyNode.getStr)
  if chords.len == 0:
    fail(ueMalformedKey, "'" & keyNode.getStr & "' names no key")
  let cmdNode = entry.getOrDefault("command")
  if cmdNode.isNil or cmdNode.kind != JString or cmdNode.getStr.len == 0:
    fail(ueUnknownCommand, "a row needs a \"command\"")
  var command = cmdNode.getStr
  let removal = command.startsWith("-")
  if removal: command = command[1 .. ^1]
  let (argOk, arg) = argumentOf(entry.getOrDefault("args"))
  if not argOk:
    fail(ueUnknownCommand, "\"args\" is a number or a string")
  let full = if arg.len > 0: command & "(" & arg & ")" else: command
  let problem = operationProblem(full)
  if problem.len > 0:
    fail(ueUnknownCommand, problem)
  var whenText = ""
  let whenNode = entry.getOrDefault("when")
  if not whenNode.isNil:
    if whenNode.kind != JString:
      fail(ueMalformedWhen, "\"when\" is a string")
    whenText = whenNode.getStr
  let parsed = parseWhen(whenText)
  if not parsed.ok:
    if parsed.message.startsWith("unknown context key"):
      fail(ueUnknownContextKey, parsed.message)
    fail(ueMalformedWhen, parsed.message)
  var base = ""
  let baseNode = entry.getOrDefault("base")
  if not baseNode.isNil:
    var known = false
    if baseNode.kind == JString:
      for b in BaseKeymap:
        if $b == baseNode.getStr: known = true
    if not known:
      fail(ueUnknownBase, "'" & $baseNode & "' is not a base (cua, emacs, " &
           "vim, kakoune)")
    base = baseNode.getStr
  let (name, _) = splitOperation(full)
  result.rows.add UserRow(
    index: index, origin: origin, keyText: keyNode.getStr,
    chords: chords.splitWhitespace(), operation: vocabularyName(name),
    argument: arg, whenText: whenText, cond: parsed.expr, base: base,
    removal: removal)

proc parseUserKeymap*(text: string): UserKeymap =
  ## The whole file. An empty or whitespace-only file is no rows and no
  ## errors; a file that is not a JSON array is ONE error for the whole
  ## file, and nothing loads from it.
  result = UserKeymap()
  if text.strip().len == 0:
    return
  var root: JsonNode
  try:
    root = parseJson(stripJsonc(text))
  except:
    # BARE, as CONTRIBUTING.md requires of a parse that runs on both
    # backends: on JS `parseJson` defers to V8's `JSON.parse`, whose
    # `SyntaxError` no Nim exception type matches — a half-written file would
    # otherwise crash the desktop's loader instead of being reported.
    let msg = getCurrentExceptionMsg()
    result.errors.add UserRowError(kind: ueBadJson, index: -1, text: "",
      message: (if msg.len > 0: msg else: "the file is not valid JSON"))
    return
  if root.kind != JArray:
    result.errors.add UserRowError(kind: ueBadJson, index: -1, text: "",
                                   message: "the file is a JSON array of rows")
    return
  result.total = root.len
  for i, entry in root.elems:
    parseRow(entry, i, "", result)

func describe*(e: UserRowError): string =
  ## One line: where, why, and the row.
  let at = if e.index < 0: "keybindings.json" else: "keybindings.json row " &
           $(e.index + 1)
  at & ": " & $e.kind & " — " & e.message &
    (if e.text.len > 0: " — in: " & e.text else: "")

func appliesTo*(row: UserRow; base: BaseKeymap): bool =
  row.base.len == 0 or row.base == $base
