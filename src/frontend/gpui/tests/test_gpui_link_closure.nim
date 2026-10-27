## test_gpui_link_closure.nim — PLAT-20's shell/leaf split, asserted of the
## BUILD: the GPUI binary links no terminal renderer and no tree-sitter
## grammar archive.
##
## The `build-gpui` recipe (`justfile`, the block above `build-gpui:`) has no
## grammar prerequisite and no `tui-prereqs`, on purpose: *"this binary links
## no terminal renderer and no tree-sitter archive, which is the shell/leaf
## split being true of the BUILD rather than only of the source."* The
## `gpui-shell` lane carries no `isonim_tui` flags for the same reason
## (`ci/lib/test-lane-files.sh`).
##
## `test_gpui_shell_split.nim` reads import LINES of the shell's own modules,
## and so cannot see a TRANSITIVE edge. One existed: `gpui/main.nim` imports
## `tui/host/session_driver`, which took one string constant from
## `tui/app/origin_binding`. That module re-exports `views/styled_row`, which
## imports all of `isonim_tui`, and `isonim_tui/syntax/treesitter_ffi.nim`
## names `isonim-tui/build/grammars/libisonim_tui_grammars.a` in a
## `{.passl.}`. So `just build-gpui` failed at the link on any checkout where
## `just tui-prereqs` had not been run (codetracer-pm issue
## 2026-10-22-just-build-gpui-fails-to-link-without-the-tui-grammar-archive-its-recipe-says-it-does-not-need.md).
## The suite that links `main.nim` (`test_gpui_editing_surface.nim`) could not
## catch it. It passes on every host where some earlier build left the archive
## in place.
##
## This suite asks the COMPILER for the closure, which `--genDeps` writes to
## `<nimcache>/main.deps`, under the flags `build-gpui` uses. It reads those
## flags from `bf_gpui_nim_args`, the single definition the recipe and the
## freshness gate share. The answer does not depend on whether any archive
## exists on this host.
##
## ## What is allowed
##
## `isonim_tui/text/width.nim` and the four generated tables it imports
## (East Asian width, grapheme break, emoji, InCB) are pure Unicode: display
## width and grapheme breaks. The shared editing core in `viewmodel/editor/`
## measures text with `width`, and none of the five has a `{.passl.}`, a
## `{.compile.}` or any I/O. They are allowed BY NAME rather than as the whole
## `text/` directory, because its siblings are not pure: `text/ansi.nim`
## encodes terminal SGR sequences over `cells`, and `text/content.nim` pulls
## in `std/re`. Every other `isonim_tui` module is a renderer, a driver, a
## widget or the highlighter, so the closure must contain none of them.
##
## ## No mocks
##
## The real compiler, the real entry point and the real flags. Nothing is
## stubbed.
##
## ## Trap 13
##
## Every helper that calls `check` is a `template`.

import std/[os, osproc, strutils, unittest]

var asserted = 0
var countedAssertions = 0

template ck(condition: untyped) =
  inc asserted
  inc countedAssertions
  check condition

template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

template resetCount() =
  asserted = 0

proc repoRoot(): string =
  ## The codetracer checkout, from THIS file's path (`src/frontend/gpui/tests`),
  ## so the suite reads the tree it was compiled from in any working directory.
  currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir

proc gpuiNimArgs(root: string): seq[string] =
  ## `bf_gpui_nim_args`, the flags `just build-gpui` compiles with, read
  ## from the recipe's own definition rather than copied here.
  let (output, code) = execCmdEx(
    "bash -c " & quoteShell("source ci/lib/build-freshness.sh && bf_gpui_nim_args"),
    workingDir = root)
  if code != 0:
    raise newException(IOError,
      "bf_gpui_nim_args failed (exit " & $code & "): " & output)
  for line in output.splitLines():
    if line.strip().len > 0:
      result.add line.strip()

proc gpuiClosure(root: string): seq[string] =
  ## The compiler's import closure of `src/frontend/gpui/main.nim`, one
  ## absolute module path per entry. `--compileOnly` stops before the C
  ## compiler and the linker, so no archive is consulted.
  let cache = getTempDir() / ("ct-gpui-link-closure-" & $getCurrentProcessId())
  removeDir(cache)
  createDir(cache)
  defer: removeDir(cache)
  var cmd = quoteShell(getCurrentCompilerExe()) &
    " c --genDeps:on --compileOnly --hints:off --warnings:off"
  for a in gpuiNimArgs(root):
    cmd.add " " & quoteShell(a)
  cmd.add " --nimcache:" & quoteShell(cache)
  cmd.add " -o:" & quoteShell(cache / "unused-deps-probe")
  cmd.add " src/frontend/gpui/main.nim"
  let (output, code) = execCmdEx(cmd, workingDir = root)
  let deps = cache / "main.deps"
  if code != 0 or not fileExists(deps):
    raise newException(IOError,
      "the gpui closure could not be computed (nim exited " & $code &
      "), so this case could not run:\n" & output)
  for line in readFile(deps).splitLines():
    if line.strip().len > 0:
      result.add line.strip().replace('\\', '/')

proc isonimTuiModule(path: string): string =
  ## The module path below `isonim_tui/` (`syntax/treesitter_ffi.nim`), or ""
  ## when `path` is not an `isonim_tui` module. Matches on the package's
  ## source directory, so a codetracer file that merely mentions the name
  ## does not count.
  const marker = "/src/isonim_tui/"
  let at = path.find(marker)
  if at >= 0: path[at + marker.len .. ^1]
  elif path.endsWith("/src/isonim_tui.nim"): "isonim_tui.nim"
  else: ""

const AllowedIsonimTui = [
  ## The pure-Unicode modules `viewmodel/editor/` measures text with. See
  ## "What is allowed" in the header for why this is a list, not `text/`.
  "text/width.nim",
  "text/east_asian_width_table.nim",
  "text/grapheme_break_table.nim",
  "text/emoji_table.nim",
  "text/incb_table.nim",
]

suite "PLAT-20: the GPUI binary links no terminal renderer":

  test "the compiler-computed closure of gpui/main.nim holds no isonim_tui renderer or grammar archive":
    resetCount()
    let closure = gpuiClosure(repoRoot())
    # Positive controls, through the same reader as the negative checks
    # below. An empty or truncated listing satisfies every "contains no"
    # check, so the listing has to show the entry point, the GPUI binding
    # it really links, and the allowed `isonim_tui/text` module that
    # `viewmodel/editor` really imports.
    var sawEntry = false
    var sawGpui = false
    var sawText = false
    for p in closure:
      if p.endsWith("/src/frontend/gpui/main.nim"): sawEntry = true
      if p.endsWith("/isonim_gpui/bindings.nim"): sawGpui = true
      if isonimTuiModule(p) == "text/width.nim": sawText = true
    ck sawEntry
    ck sawGpui
    ck sawText
    # The negative half. Name each offender so a failure says which edge
    # to cut.
    var forbidden: seq[string] = @[]
    for p in closure:
      let m = isonimTuiModule(p)
      if m.len > 0 and m notin AllowedIsonimTui:
        forbidden.add m
    if forbidden.len > 0:
      checkpoint("isonim_tui modules in the GPUI closure: " & forbidden.join(", "))
    # `treesitter_ffi` is the module whose `{.passl.}` names the grammar
    # archive. It is checked by name as well as through the general rule, so
    # the failure states the link error it causes.
    ck "syntax/treesitter_ffi.nim" notin forbidden
    ck forbidden.len == 0
    expectCount(5)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 5

suite "PLAT-20: the assertion count":
  test "every case in this file ran":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
