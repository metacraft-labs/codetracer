## CS-M10 (Clispec Library campaign, reprobuild-pm): `ct`'s command line is a
## clispec description, and nothing of confutils' type-based command line is
## left.
##
## `test_cs_m10_no_enum_subcommands_left` scans every Nim source under `src/`
## (this file aside) and fails on any of:
##
##   * a `{.command.}` pragma: confutils' case-object subcommands, whose
##     discriminator is an enum (`case cmd* {.command, defaultValue:
##     noCommand.}: StartUpCommand`);
##   * an object field carrying confutils' command-line pragmas (`desc`,
##     `longDesc`, `abbr`, `argument`, `restOfArgs`, `defaultValue`, `name`,
##     ...): a type confutils' loader would read;
##   * an import (or export) of the `confutils` module itself, the one that
##     defines the type-based `load`.  ct imports only the parts that are not
##     that loader: `confutils/defs` (`ConfigurationError`),
##     `confutils/clispec_config` (`cliConfiguration`, the description's
##     loader), `confutils/runtime_surface` and `confutils/shell_completion`.
##     So no confutils `load` of a command line can remain:
##     `CodetracerConf.load` is ct's own (`codetracerconf.nim`, over the
##     description), which the scan checks too.
##
## Comments and string literals are not code, so they are not scanned.
##
## The scan is checked against itself (negative controls): sources written
## to a scratch tree with a reintroduced enum subcommand, a confutils field
## pragma, and a bare `import confutils` are each reported.
##
## `CT_CS_M10_SCAN_ROOT` points the first test at another tree (a copy of the
## repository with a change in it) instead of this one.
##
## No mocks: the scan reads the repository's files.
##
## Lane: `cli-record` (`ci/lib/test-lane-files.sh` globs `src/tests/cli`).

import std/[os, re, sets, strutils, tempfiles, unittest]

const
  ThisFile = currentSourcePath
  RepoRoot = ThisFile.parentDir.parentDir.parentDir.parentDir

  ## confutils' pragmas for a command-line field (confutils/defs.nim).
  ConfutilsFieldPragmas = ["desc", "longDesc", "abbr", "argument",
    "restOfArgs", "defaultValue", "defaultValueDesc", "name", "hidden",
    "ignore", "separator", "implicitlySelectable", "command",
    "defaultCommandName"].toHashSet

proc code(text: string): string =
  ## `text` with comments (`#`, `##`, `#[ ]#`, `##[ ]##`) and string and
  ## character literals blanked out, line structure kept.
  var i = 0
  var depth = 0
  while i < text.len:
    let c = text[i]
    if depth > 0:
      if c == ']' and i + 1 < text.len and text[i + 1] == '#':
        dec depth
        i += 2
        continue
      if c == '#' and i + 1 < text.len and text[i + 1] == '[':
        inc depth
        i += 2
        continue
      result.add(if c == '\n': '\n' else: ' ')
      inc i
    elif c == '#':
      if i + 1 < text.len and text[i + 1] == '[' or
          (i + 2 < text.len and text[i + 1] == '#' and text[i + 2] == '['):
        inc depth
        i += (if text[i + 1] == '[': 2 else: 3)
        continue
      while i < text.len and text[i] != '\n': inc i
    elif c == '"':
      if text.continuesWith("\"\"\"", i):
        let e = text.find("\"\"\"", i + 3)
        let stop = if e < 0: text.len else: e + 3
        for k in i ..< stop:
          result.add(if text[k] == '\n': '\n' else: ' ')
        i = stop
      else:
        result.add ' '
        inc i
        while i < text.len and text[i] notin {'"', '\n'}:
          if text[i] == '\\' and i + 1 < text.len: inc i
          inc i
        result.add ' '
        inc i
    elif c == '\'' and i + 2 < text.len and
        (text[i + 2] == '\'' or (text[i + 1] == '\\' and i + 3 < text.len)):
      # a character literal: 'x' or '\n'
      let stop = if text[i + 1] == '\\': text.find('\'', i + 2) + 1
                 else: i + 3
      for k in i ..< max(stop, i + 1): result.add ' '
      i = max(stop, i + 1)
    else:
      result.add c
      inc i

proc lineOf(text: string; pos: int): int =
  text[0 ..< min(pos, text.len)].count('\n') + 1

proc scanSource*(path, text: string): seq[string] =
  ## What in one source is left of confutils' type-based command line.
  let src = code(text)
  # `{.command.}` (alone or among other pragmas)
  let command = re(r"\{\.(?:[^}]*?[,\s])?command\b(?!\s*:)[^}]*\}", {reStudy})
  var start = 0
  while true:
    let (first, last) = src.findBounds(command, start)
    if first < 0: break
    result.add path & ":" & $lineOf(src, first) &
      ": a `{.command.}` pragma (confutils' enum subcommands): " &
      src[first .. last].splitWhitespace.join(" ")
    start = last + 1
  # a field with confutils' command-line pragmas
  start = 0
  let field = re(r"(\w+)\*?\s*\{\.((?:(?!\.\}).)*)\.\}\s*:", {reDotAll, reStudy})
  var groups: array[2, string]
  while true:
    let (first, last) = src.findBounds(field, groups, start)
    if first < 0: break
    for item in groups[1].split({',', '\n'}):
      let name = item.strip.split({':', ' '})[0].strip
      if name in ConfutilsFieldPragmas:
        result.add path & ":" & $lineOf(src, first) & ": field `" &
          groups[0] & "` carries confutils' `" & name & "` pragma"
        break
    start = last + 1
  # the `confutils` module itself (not `confutils/<part>`)
  var lineNo = 0
  for line in src.splitLines:
    inc lineNo
    for m in line.findAll(re"(?<![\w/.])(pkg/)?confutils\b(?!\s*/)"):
      result.add path & ":" & $lineNo &
        ": imports `confutils`, the module of the type-based `load`"
      break

proc scanTree*(root: string): seq[string] =
  ## Every source under `<root>/src`, this test aside.
  for f in walkDirRec(root / "src"):
    if not f.endsWith(".nim"): continue
    if f.extractFilename == ThisFile.extractFilename: continue
    let rel = f.relativePath(root)
    if rel.startsWith("src/build") or "/node_modules/" in rel: continue
    var text = ""
    try: text = readFile(f)
    except IOError, OSError:
      result.add rel & ": unreadable"
      continue
    result.add scanSource(rel, text)
  # `CodetracerConf.load` is ct's own, over the description.
  let conf = root / "src" / "ct" / "codetracerconf.nim"
  let confText = try: readFile(conf) except IOError, OSError: ""
  if "proc load*(T: typedesc[CodetracerConf]" notin code(confText):
    result.add "src/ct/codetracerconf.nim: no `load` of ct's own for " &
      "`CodetracerConf` (it would be confutils')"
  if "include cli/ct_cli_description" notin code(confText):
    result.add "src/ct/codetracerconf.nim: does not include ct's clispec " &
      "description (`cli/ct_cli_description.nim`)"

suite "CS-M10: no confutils type-based command line left in ct":
  test "test_cs_m10_no_enum_subcommands_left":
    let root = getEnv("CT_CS_M10_SCAN_ROOT", RepoRoot)
    checkpoint("scanned: " & root / "src")
    check dirExists(root / "src" / "ct")
    let found = scanTree(root)
    for f in found: checkpoint(f)
    check found.len == 0

  test "negative control: a reintroduced enum subcommand is reported":
    let src = """
import confutils/defs
type
  Cmd* {.pure.} = enum
    noCommand, list
  Conf* = object
    case cmd* {.
      command
      defaultValue: noCommand .}: Cmd
    of Cmd.noCommand: discard
    of Cmd.list: discard
"""
    let found = scanSource("x.nim", src)
    for f in found: checkpoint(f)
    check found.len >= 1
    var sawCommand = false
    for f in found:
      if "`{.command.}`" in f: sawCommand = true
    check sawCommand

  test "negative control: a confutils field pragma and `import confutils` are reported":
    let fieldSrc = "type C = object\n  verbose* {.\n    desc: \"talk\"\n    abbr: \"v\" .}: bool\n"
    check scanSource("f.nim", fieldSrc).len == 1
    check scanSource("i.nim", "import\n  std/os,\n  confutils,\n  x\n").len == 1
    check scanSource("j.nim", "import confutils\n").len == 1
    check scanSource("k.nim", "from pkg/confutils import load\n").len == 1
    # the parts ct may import, and mentions in comments and strings, are not
    check scanSource("ok.nim", "import confutils/defs, confutils/[clispec_config]\n" &
      "# confutils {.command.}\nlet s = \"import confutils {.command.}\"\n").len == 0

  test "negative control: a scratch copy of the tree with an enum subcommand fails":
    let scratch = createTempDir("ct_cs_m10_scan_", "")
    try:
      createDir(scratch / "src" / "ct" / "cli")
      let conf = readFile(RepoRoot / "src" / "ct" / "codetracerconf.nim")
      writeFile(scratch / "src" / "ct" / "codetracerconf.nim", conf)
      check scanTree(scratch).len == 0
      writeFile(scratch / "src" / "ct" / "codetracerconf.nim", conf.replace(
        "  CodetracerConf* = object\n",
        "  CodetracerConf* = object\n    case legacy* {.command, " &
        "defaultValue: ArbCommand.noCommand.}: ArbCommand\n" &
        "    else: discard\n"))
      let found = scanTree(scratch)
      for f in found: checkpoint(f)
      check found.len >= 1
    finally:
      removeDir(scratch)
