## test_plat46_token_derivation.nim — PLAT-46 deliverable 6, proved by a
## SCRATCH BUILD: change one design-system token and every rung moves.
##
## ## The claim
##
## "The 256- and 16-colour rungs are DERIVED from each role's token hex …, not a
## second table — so changing a token changes every rung." Asserting the rungs
## against the same derivation run in-process (which
## `app/tests/test_degraded_style_tables.nim` also does) cannot tell a derived
## rung from a table that happens to agree with today's tokens. So this suite
## changes a token for real:
##
##   1. copies the desktop's Monaco theme documents into a scratch directory
##      (since PLAT-47 the keyword role is painted from them, generated beside
##      the pinned `codetracer-design-system`);
##   2. rewrites their `keyword` rule to two colours nothing else in the
##      system uses (one per mode);
##   3. runs the REAL generator (`scripts/tokens-to-styl.sh --nim-out
##      --editor-theme`) over the pinned design system and the scratch themes;
##   4. compiles a probe against the REAL `app/theme/` modules, copied into a
##      scratch tree beside the regenerated `design_tokens.nim`, and the same
##      probe against the committed one;
##   5. asserts that the keyword role moved on EVERY coloured rung (24-bit, 256,
##      16, terminal palette) in both modes, that each moved rung is the nearest
##      entry to the NEW hex, and — the control — that a role bound to a token
##      nobody touched did not move at all.
##
## ## No mocks
##
## The generator, the modules and the compiler are the real ones; only the
## token VALUE is changed, in a scratch copy, which is the experiment rather
## than a substitution inside the subject.
##
## ## It does not skip
##
## No design-system source, a generator failure, or a probe that will not
## compile FAILS by name.

import std/[json, os, osproc, strutils, unittest]

import ../app/theme/colour_math

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 17

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  NewDark = "#11aa33"
  NewLight = "#2255cc"
    ## Colours no token of the system resolves to, so a rung that still shows
    ## the old keyword pink could not have come from the new hex by accident.
  ThemeModules = ["roles.nim", "cell_style.nim", "colour_math.nim",
                  "palette.nim", "capabilities.nim", "editor_theme.nim"]
  ProbeSource = """
import ./palette
import ./capabilities

proc fgOf(role: SemanticRole; depth: ColorDepth; mode: DesignMode;
          palette = pkDesign): string =
  resolveRoles(CellStyle(role: role), depth, mode, palette).fg

for mode in [dmDark, dmLight]:
  let m = if mode == dmDark: "dark" else: "light"
  for role in [srSyntaxKeyword, srSyntaxString]:
    for depth in [cdTrueColor, cdAnsi256, cdAnsi16]:
      echo m, " ", $role, " ", $depth, " ", fgOf(role, depth, mode)
    echo m, " ", $role, " terminal ", fgOf(role, cdTrueColor, mode, pkTerminal)
"""
    ## Prints one line per (mode, role, rung): the foreground that rung paints.

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError, "no codetracer checkout above " &
                     currentSourcePath())

proc run(cmd: string): (string, int) =
  execCmdEx(cmd)

proc designSystemSource(root, scratch: string): string =
  ## The pinned design system, as a directory: the checked-out submodule when
  ## it is AT the pin, else the workspace sibling's copy of the pinned commit.
  let (lsOut, lsCode) = run("git -C " & quoteShell(root) &
                            " ls-files -s -- libs/codetracer-design-system")
  doAssert lsCode == 0, lsOut
  let pinned = lsOut.splitWhitespace()[1]
  let sub = root / "libs" / "codetracer-design-system"
  if fileExists(sub / "mapped" / "mapped.json"):
    let (head, code) = run("git -C " & quoteShell(sub) & " rev-parse HEAD")
    if code == 0 and head.strip() == pinned:
      return sub
  let sibling = root.parentDir / "codetracer-design-system"
  let dest = scratch / "ds-pinned"
  createDir(dest)
  let (arOut, arCode) = run("git -C " & quoteShell(sibling) & " archive " &
                            pinned & " | tar -x -C " & quoteShell(dest))
  doAssert arCode == 0, "cannot obtain codetracer-design-system at the " &
    "pinned " & pinned & " (git submodule update --init " &
    "libs/codetracer-design-system): " & arOut
  dest

proc buildProbe(scratchTree, tokensNim, root: string): string =
  ## Copy the real theme modules beside `tokensNim` and run the probe.
  let theme = scratchTree / "src" / "frontend" / "tui" / "app" / "theme"
  createDir(theme)
  createDir(scratchTree / "src" / "frontend" / "styles" / "generated")
  createDir(scratchTree / "src" / "common" / "terminal_graphics")
  for m in ThemeModules:
    copyFile(root / "src" / "frontend" / "tui" / "app" / "theme" / m, theme / m)
  let syntax = scratchTree / "src" / "frontend" / "tui" / "app" / "syntax"
  createDir(syntax)
  copyFile(root / "src" / "frontend" / "tui" / "app" / "syntax" /
             "token_class.nim", syntax / "token_class.nim")
  for m in ["tiers.nim", "oklab.nim", "raster.nim"]:
    copyFile(root / "src" / "common" / "terminal_graphics" / m,
             scratchTree / "src" / "common" / "terminal_graphics" / m)
  copyFile(tokensNim,
           scratchTree / "src" / "frontend" / "styles" / "generated" /
             "design_tokens.nim")
  writeFile(theme / "probe_rungs.nim", ProbeSource)
  let (outp, code) = run("nim c -r --hints:off --warnings:off --nimcache:" &
                         quoteShell(scratchTree / "nimcache") & " " &
                         quoteShell(theme / "probe_rungs.nim"))
  doAssert code == 0, "the probe did not compile or run:\n" & outp
  outp

proc lineOf(table, prefix: string): string =
  for line in table.splitLines():
    if line.startsWith(prefix & " "):
      return line[prefix.len + 1 .. ^1]
  ""

suite "PLAT-46 deliverable 6: every rung is derived from the token":

  test "a changed keyword token moves every rung; an untouched one does not":
    let root = repoRoot()
    let scratch = getTempDir() / "plat46-derivation-" & $getCurrentProcessId()
    removeDir(scratch)
    createDir(scratch)
    defer: removeDir(scratch)

    # PLAT-47: the keyword role is painted from the DESKTOP'S Monaco theme
    # (`codetracerDark.json` / `codetracerWhite.json`), which the same
    # generator reads beside the pinned design system. So the edit is to a
    # scratch copy of those two files — the keyword rule — and the design
    # system is the pinned one, untouched.
    let ds = designSystemSource(root, scratch)
    let themes = scratch / "monaco-themes"
    createDir(themes)
    let themeSrc = root / "src" / "public" / "third_party" / "monaco-themes" /
                   "themes" / "customThemes" / "json"
    for (name, hex) in [("codetracerDark.json", NewDark),
                        ("codetracerWhite.json", NewLight)]:
      var doc = parseFile(themeSrc / name)
      for rule in doc["rules"]:
        if rule{"token"}.getStr == "keyword":
          rule["foreground"] = %hex[1 .. ^1]
      writeFile(themes / name, pretty(doc))

    let tokensNim = scratch / "gen" / "design_tokens.nim"
    let (genOut, genCode) = run("bash " &
      quoteShell(root / "scripts" / "tokens-to-styl.sh") & " " &
      quoteShell(ds) & " " & quoteShell(scratch / "gen") &
      " --nim-out " & quoteShell(tokensNim) &
      " --editor-theme " & quoteShell(themes))
    checkpoint(genOut)
    ck genCode == 0
    ck readFile(tokensNim).contains(NewDark)

    let before = buildProbe(scratch / "tree-before",
      root / "src" / "frontend" / "styles" / "generated" / "design_tokens.nim",
      root)
    let after = buildProbe(scratch / "tree-after", tokensNim, root)
    checkpoint("committed tokens:\n" & before)
    checkpoint("mutated tokens:\n" & after)

    var moved = 0
    for (mode, hex) in [("dark", NewDark), ("light", NewLight)]:
      let c = parseHexColour(hex)
      let rgb = lineOf(after, mode & " syntax-keyword truecolor")
      let idx = lineOf(after, mode & " syntax-keyword ansi256")
      let ansi = lineOf(after, mode & " syntax-keyword ansi16")
      ck rgb == hex
      ck idx == "indexed:" & $nearestXterm256(c)
      ck ansi == AnsiNames[nearestAnsi16Family(c)]
      # EVERY coloured rung moved off the committed token's answer …
      for rung in ["truecolor", "ansi256", "ansi16", "terminal"]:
        let prefix = mode & " syntax-keyword " & rung
        if lineOf(after, prefix) != lineOf(before, prefix):
          inc moved
      # … and the CONTROL: a role bound to an untouched token did not.
      for rung in ["truecolor", "ansi256", "ansi16", "terminal"]:
        let prefix = mode & " syntax-string " & rung
        ck lineOf(after, prefix) == lineOf(before, prefix)
    checkpoint("keyword rungs that moved: " & $moved & " of 8")
    ck moved == 8

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
