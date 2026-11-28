## story_options.nim — the command line of `codetracer-zgui-story`.
##
## Kept apart from `story_host` so it can be tested without zgui's shim.

import std/[os, parseopt, strutils]

type
  HostOptions* = object
    kind*, surface*, fixture*, title*, outPath*, theme*, buildRoot*, repoRoot*, boxesPath*: string
    width*, height*: int
    scale*: float

const Usage* = "usage: codetracer-zgui-story --story=<kind>/<surface>/<fixture> --out=<png> " &
  "[--title=] [--width=] [--height=] [--scale=] [--theme=] [--build-root=]"

proc parseOptions*(args: seq[string]): HostOptions =
  ## The host's options from `args`. Raises `ValueError` for an option it does not know, a
  ## malformed value, or a missing `--story` or `--out`.
  result = HostOptions(width: 1600, height: 1000, scale: 1.0, theme: "dark",
                       buildRoot: "src/build-debug-repro", repoRoot: getCurrentDir(),
                       fixture: "populated")
  # `allowWhitespaceAfterColon = false`: the harness passes `--title="$title"`, which is
  # `--title=` for a story without a tab title, and by default `parseopt` takes the NEXT
  # argument (`--width=1100`) as that empty option's value.
  var p = initOptParser(args, allowWhitespaceAfterColon = false)
  for kind, key, value in p.getopt():
    if kind notin {cmdLongOption, cmdShortOption}: continue
    case key
    of "story":
      let parts = value.split('/')
      if parts.len < 2: raise newException(ValueError, "--story is <kind>/<surface>[/<fixture>]")
      result.kind = parts[0]
      result.surface = parts[1]
      if parts.len > 2: result.fixture = parts[2]
    of "title": result.title = value
    of "out": result.outPath = value
    of "width": result.width = parseInt(value)
    of "height": result.height = parseInt(value)
    of "scale": result.scale = parseFloat(value)
    of "theme": result.theme = value
    of "build-root": result.buildRoot = value
    of "repo-root": result.repoRoot = value
    of "boxes": result.boxesPath = value
    else: raise newException(ValueError, "unknown option --" & key)
  if result.kind.len == 0 or result.outPath.len == 0:
    raise newException(ValueError, Usage)
  result.buildRoot = absolutePath(result.buildRoot)
  result.repoRoot = absolutePath(result.repoRoot)
