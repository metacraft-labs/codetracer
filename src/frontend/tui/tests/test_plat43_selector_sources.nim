## PLAT-43 — the selector's SOURCE FACTS, each with a planted positive control.
##
## Run:
##   nim c -r src/frontend/tui/tests/test_plat43_selector_sources.nim
##
## Two claims the milestone makes about the TREE rather than about a run:
##
##   1. **ONE SELECTOR, TWO FRONT-ENDS** (Verification-Harness-Traps §30b). The
##      terminal's `:keymap` and the stored preference both reach
##      `keymap_selection.selectKeymap`, and BOTH native hosts read the
##      preference through `keymap_preference.loadKeymapPreference`.
##   2. **THE SELECTOR IS NOT A SECOND RESOLVER.** The name→model mapping names
##      no resolver entry point, and nothing else in the product maps a name to
##      a `KeymapModel` (`parseEnum[KeymapModel]`, the obvious second spelling).
##
## Identifiers are compared the way Nim compares them (§35b): the first
## character exactly, the rest case- and underscore-insensitively — so
## `select_keymap` and `selectKeymap` are ONE identifier here as they are to
## the compiler. Comments and string literals are stripped before scanning, so
## a name mentioned in prose is not a call.
##
## Every scan runs once over a PLANTED fixture that contains the thing it looks
## for: an absence scan that cannot find its target passes for free (§4).
##
## No mocks: the scanned files are the tree's own.

import std/[os, strutils, unittest]

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())

proc nimIdent(s: string): string =
  ## Nim's identifier equality, as a key.
  if s.len == 0: return ""
  result = $s[0]
  for c in s[1 .. ^1]:
    if c != '_': result.add c.toLowerAscii

proc codeOnly(src: string): string =
  ## `src` with comments and string/char literals blanked out.
  var i = 0
  while i < src.len:
    let c = src[i]
    if c == '#':
      while i < src.len and src[i] != '\n': inc i
      continue
    if c == '"':
      if i + 2 < src.len and src[i + 1] == '"' and src[i + 2] == '"':
        i += 3
        while i + 2 < src.len and not (src[i] == '"' and src[i + 1] == '"' and
                                       src[i + 2] == '"'):
          inc i
        i += 3
        continue
      inc i
      while i < src.len and src[i] != '"' and src[i] != '\n':
        if src[i] == '\\': inc i
        inc i
      inc i
      continue
    if c == '\'' and i + 2 < src.len and (src[i + 2] == '\'' or src[i + 1] == '\\'):
      i += (if src[i + 1] == '\\': 4 else: 3)
      continue
    result.add c
    inc i

proc identifiers(src: string): seq[string] =
  ## Every identifier token in the CODE of `src`, as a Nim-equality key.
  let code = codeOnly(src)
  var i = 0
  while i < code.len:
    if code[i] in IdentStartChars:
      var j = i
      while j < code.len and code[j] in IdentChars: inc j
      result.add nimIdent(code[i ..< j])
      i = j
    else:
      inc i

proc names(src: string; ident: string): bool =
  nimIdent(ident) in identifiers(src)

proc mapsNameToModel(src: string): bool =
  ## `parseEnum[KeymapModel]` — the second spelling of the selector — in any
  ## identifier-equal form, with any spacing inside the brackets.
  let code = codeOnly(src).multiReplace((" ", ""), ("\t", ""), ("\n", ""))
  var i = 0
  while i < code.len:
    if code[i] in IdentStartChars:
      var j = i
      while j < code.len and code[j] in IdentChars: inc j
      if nimIdent(code[i ..< j]) == nimIdent("parseEnum") and
         j < code.len and code[j] == '[':
        let close = code.find(']', j)
        if close > j and nimIdent(code[j + 1 ..< close]) == nimIdent("KeymapModel"):
          return true
      i = j
    else:
      inc i
  false

const ResolverEntryPoints = ["resolve", "resolveKey", "trieFor", "applyKey",
                             "driveKeys", "keymapOf"]

proc src(rel: string): string = readFile(repo / rel)

suite "PLAT-43: the scanners find what they look for (planted controls)":

  test "a call is found in any Nim-equal spelling, and prose is not a call":
    ck names("let s = select_keymap(x)", "selectKeymap")
    ck names("let s = selectKeyMap(x)", "selectKeymap")
    ck not names("# selectKeymap is called elsewhere", "selectKeymap")
    ck not names("echo \"selectKeymap\"", "selectKeymap")
    # The first character is significant in Nim, and so here.
    ck not names("let s = SelectKeymap(x)", "selectKeymap")

  test "the second spelling of the selector is found when planted":
    ck mapsNameToModel("let m = parseEnum[KeymapModel](name)")
    ck mapsNameToModel("let m = parse_enum[ Keymap_model ](name)")
    ck not mapsNameToModel("let m = parseEnum[keymapModel](name)")   # not Nim-equal
    ck not mapsNameToModel("# parseEnum[KeymapModel] would be a second selector")
    ck not mapsNameToModel("let m = parseEnum[ProductMode](name)")

suite "PLAT-43: one selector, two front-ends":

  test "the terminal's :keymap and the stored preference both call selectKeymap":
    ck names(src("src/frontend/tui/app/runtime.nim"), "selectKeymap")
    ck names(src("src/frontend/viewmodel/keymap/keymap_selection.nim"),
             "selectKeymap")
    # decodeKeymapPreference is the stored path, and it calls the selector
    # rather than parsing on its own.
    let sel = src("src/frontend/viewmodel/keymap/keymap_selection.nim")
    let decodeAt = sel.find("func decodeKeymapPreference")
    ck decodeAt > 0
    ck names(sel[decodeAt .. ^1], "selectKeymap")

  test "both native hosts read the preference through loadKeymapPreference":
    ck names(src("src/frontend/tui/main.nim"), "loadKeymapPreference")
    ck names(src("src/frontend/gpui/main.nim"), "loadKeymapPreference")

suite "PLAT-43: the selector is not a second resolver":

  test "the selector and the preference name no resolver entry point":
    for rel in ["src/frontend/viewmodel/keymap/keymap_selection.nim",
                "src/frontend/viewmodel/host/keymap_preference.nim"]:
      let s = src(rel)
      for entry in ResolverEntryPoints:
        checkpoint(rel & " / " & entry)
        ck not names(s, entry)

  test "nothing in the product maps a name to a KeymapModel on its own":
    var scanned = 0
    var offenders: seq[string] = @[]
    for dir in ["src/frontend", "src/common"]:
      for f in walkDirRec(repo / dir):
        if not f.endsWith(".nim"): continue
        if "/tests/" in f or "/build-" in f: continue
        inc scanned
        if mapsNameToModel(readFile(f)):
          offenders.add f.relativePath(repo)
    checkpoint("offenders: " & offenders.join(", "))
    ck scanned > 100
    ck offenders.len == 0

suite "PLAT-43 selector sources — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
