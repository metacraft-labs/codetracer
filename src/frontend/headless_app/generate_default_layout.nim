## headless_app/generate_default_layout.nim — PLAT-45 deliverable 7, PLAT-47
## deliverable 1. **The build step that writes the desktop's bundled layout
## and the default every front-end opens with.**
##
##   node generate_default_layout.js --out=<dir>     write both files into <dir>
##   node generate_default_layout.js --check=<dir>   exit 1 (and say why) when
##                                                   either file in <dir> is not
##                                                   byte-for-byte what this
##                                                   program would write
##   node generate_default_layout.js                 print both on stdout
##
## `<dir>` is the repository root; the two outputs are
##
##   * `src/config/default_layout.json` — the BUNDLED tree
##     (`layout_model.sharedBundledLayout`) in the GoldenLayout config the
##     desktop loads (`desktop_panes.layoutNodeToGoldenConfig`); the input
##     every mode's default is derived from;
##   * `src/frontend/headless_app/shared_default_layout.generated.json` — the
##     desktop's DEBUG-mode default, derived from that config by the ONE
##     function the desktop itself calls
##     (`index/mode_default_layout.modeDefaultLayout`), read back into the
##     shared vocabulary (`desktop_panes.goldenConfigToLayoutNode`). This is
##     `layout_model.sharedDefaultLayout()`'s tree: what the terminal and the
##     GPUI window open with, and what the desktop's first run shows.
##
## ## Why this is a node program
##
## The per-mode derivation is the desktop's own code, and the desktop's own
## code is JavaScript (`index/layout_config_repair` is `importjs` over the
## GoldenLayout config). A C generator would have had to re-implement it, and a
## re-implementation is a second answer to "what is the debug-mode layout" that
## can drift from the first — exactly the three-defaults state PLAT-45 removed.
## So this is compiled with `nim js -d:nodejs` and run under node
## (`just generate-default-layout`, `ci/test/default-layout-fresh.sh`).
##
## Both outputs are committed (the desktop embeds the first with `staticRead`
## and every build variant publishes it; the terminal and GPUI embed the
## second the same way), so both are checked fresh by the same gate.

when not defined(js):
  {.error: "generate_default_layout is a node program: compile it with " &
    "`nim js -d:nodejs` (the per-mode derivation is the desktop's JavaScript)".}

import std/[json, jsffi, strutils]

import desktop_panes
import ../index/mode_default_layout
import ../../common/types

const
  BundledPath* = "src/config/default_layout.json"
  SharedDefaultPath* = "src/frontend/headless_app/shared_default_layout.generated.json"

proc nodeArgs(): seq[string] =
  var raw: seq[cstring]
  {.emit: "`raw` = process.argv.slice(2);".}
  for a in raw: result.add $a

proc nodeReadFile(path: cstring): cstring {.importjs:
  "(function(p){ try { return require('fs').readFileSync(p, 'utf8'); } " &
  "catch (e) { return null; } })(#)".}
proc nodeWriteFile(path, text: cstring) {.importjs:
  "require('fs').writeFileSync(#, #)".}
proc jsonParse(text: cstring): js {.importjs: "JSON.parse(#)".}
proc jsonStringify(value: js): cstring {.importjs: "JSON.stringify(#)".}
proc stderrWrite(text: cstring) {.importjs: "process.stderr.write(#)".}
proc stdoutWrite(text: cstring) {.importjs: "process.stdout.write(#)".}
proc exitWith(code: int) {.importjs: "process.exit(#)".}

proc outputs(): seq[(string, string)] =
  ## The two files, in order, as (repository-relative path, exact bytes).
  let bundledText = generatedDefaultLayoutText()
  # THE DESKTOP'S OWN DERIVATION, on the bytes it will load.
  let debugConfig = modeDefaultLayout(jsonParse(cstring(bundledText)),
                                      DebugMode)
  let debugJson = parseJson($jsonStringify(debugConfig))
  @[(BundledPath, bundledText),
    (SharedDefaultPath, generatedSharedDefaultText(debugJson))]

proc main(): int =
  var outDir = ""
  var checkDir = ""
  for arg in nodeArgs():
    if arg.startsWith("--out="):
      outDir = arg["--out=".len .. ^1]
    elif arg.startsWith("--check="):
      checkDir = arg["--check=".len .. ^1]
    else:
      stderrWrite(cstring("generate_default_layout: unknown argument '" & arg &
                          "'\n"))
      return 2
  let files = outputs()
  if checkDir.len > 0:
    var stale = 0
    for (rel, text) in files:
      let path = checkDir & "/" & rel
      let committed = nodeReadFile(cstring(path))
      if committed.isNil:
        stderrWrite(cstring("generate_default_layout: " & path &
                            " does not exist\n"))
        inc stale
      elif $committed != text:
        stderrWrite(cstring("generate_default_layout: " & path & " is STALE: " &
          "it is not what the bundled tree and the desktop's debug-mode " &
          "derivation generate. It is a generated file — do not edit it by " &
          "hand; change `sharedBundledLayout()` in " &
          "src/frontend/headless_app/layout_model.nim (or the per-mode tables " &
          "in common_types/codetracer_features/frontend.nim) and run " &
          "`just generate-default-layout`.\n"))
        inc stale
      else:
        stdoutWrite(cstring("default layout is fresh: " & path & "\n"))
    return (if stale > 0: 1 else: 0)
  if outDir.len > 0:
    for (rel, text) in files:
      nodeWriteFile(cstring(outDir & "/" & rel), cstring(text))
    return 0
  for (rel, text) in files:
    stdoutWrite(cstring("=== " & rel & "\n" & text))
  0

exitWith(main())
