## headless_app/generate_default_layout.nim — PLAT-45 deliverable 7. **The
## build step that writes the desktop's default layout from the shared tree.**
##
##   generate_default_layout --out=<file>     write the generated config
##   generate_default_layout --check=<file>   exit 1 (and say why) when <file>
##                                            is not byte-for-byte what the
##                                            generator would write
##   generate_default_layout                  print it on stdout
##
## `src/config/default_layout.json` is an OUTPUT of this program: it is
## committed (the desktop embeds it with `staticRead` and every build variant
## publishes it), and `ci/test/default-layout-fresh.sh` runs `--check` so a
## hand edit of the committed file, or an edit of `sharedDefaultLayout()` that
## was not regenerated, fails by name. `just generate-default-layout` is the
## way to regenerate it.

import std/[os, strutils]

import desktop_panes

proc main(): int =
  var outPath = ""
  var checkPath = ""
  for arg in commandLineParams():
    if arg.startsWith("--out="):
      outPath = arg["--out=".len .. ^1]
    elif arg.startsWith("--check="):
      checkPath = arg["--check=".len .. ^1]
    else:
      stderr.writeLine("generate_default_layout: unknown argument '" & arg &
                       "'")
      return 2
  let text = generatedDefaultLayoutText()
  if checkPath.len > 0:
    if not fileExists(checkPath):
      stderr.writeLine("generate_default_layout: " & checkPath &
                       " does not exist")
      return 1
    let committed = readFile(checkPath)
    if committed != text:
      stderr.writeLine("generate_default_layout: " & checkPath & " is STALE: " &
        "it is not what `sharedDefaultLayout()` translates to. It is a " &
        "generated file — do not edit it by hand; change the shared tree in " &
        "src/frontend/headless_app/layout_model.nim and run " &
        "`just generate-default-layout`.")
      return 1
    echo "default layout is fresh: ", checkPath
    return 0
  if outPath.len > 0:
    writeFile(outPath, text)
    return 0
  stdout.write(text)
  0

when isMainModule:
  quit(main())
