## ui_dispatch_test.nim — PLAT-1, the two EFFECTS the decision cannot perform.
##
## Subject: `src/ct/launch/ui_dispatch.nim` — reading `ui` out of the user's
## configuration (`codetracer-specs/CLI/ct/ui-selection.md` §5, layer 3) and
## finding the component binary a handoff names (§3, §3.2).
##
## ## NO MOCKS
##
## Both subjects are filesystem lookups, so every case here uses the real
## filesystem: real directories under `$TMPDIR`, real `.config.yaml` files, and
## component bundles laid down by the REAL packaging producer
## (`scripts/build-tui-component.sh`) from the REAL shipped capability file.
##
## One thing here is a stand-in and it is named rather than hidden: the
## `codetracer-tui` binary inside those bundles is a COPY OF `ct` ITSELF. That
## is not a mock of the terminal front-end — nothing in this file runs it or
## asserts anything about what it does. `resolveTuiBinary` answers "which PATH
## would be exec'd", and the only property the file at that path needs is to
## EXIST. Using `ct` means the bundle holds a real executable rather than a
## script this file wrote, and it means this suite does not require
## `just build-tui`. The suite that actually RUNS the front-end through
## `--ui=tui` is `src/tests/ui_selection/test_ct_ui_resolution.nim`, which
## requires the real binary by name.
##
## ## THE CASE THIS FILE EXISTS FOR
##
## `src/config/default_config.yaml` — the file every installation starts from —
## already contains a `ui:` key, nested under `flow:`, where it selects the flow
## presentation. A reader that matched `ui:` anywhere would resolve every
## default installation to `--ui=parallel` and then refuse to start. That case
## is asserted against the SHIPPED file rather than against an invented one, per
## `docs/tui-testing.md` rule 6: where the subject is a published table, read the
## publication.

import std/[os, osproc, streams, strutils, unittest]

import ui_dispatch
import ../../common/config

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 44

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate the codetracer checkout from " & currentSourcePath())

let
  root = repoRoot()
  shippedDefaultConfig = root / "src" / "config" / "default_config.yaml"
  shippedCaps = root / "packaging" / "codetracer-tui.caps"

var
  scratch = ""
  originalDir = ""

proc writeConfig(dir, body: string) =
  createDir(dir)
  writeFile(dir / configPath, body)

proc readUiFrom(dir: string): string =
  ## `configuredUiValue` as seen from `dir`. The working directory is the input
  ## to the subject — `findConfig` walks up from it — so it is set rather than
  ## passed.
  let previous = getCurrentDir()
  setCurrentDir(dir)
  try:
    configuredUiValue()
  finally:
    setCurrentDir(previous)

suite "PLAT-1 §5 layer 3: reading `ui` out of a real configuration file":

  test "the scratch tree and the shipped default config both exist":
    # FIRST AND SEPARATELY, so a missing checkout file reports as itself rather
    # than as a resolution failure several cases later. Not a skip.
    ck fileExists(shippedDefaultConfig)
    ck fileExists(shippedCaps)
    originalDir = getCurrentDir()
    scratch = getTempDir() / ("plat1-ui-dispatch-" & $getCurrentProcessId())
    removeDir(scratch)
    createDir(scratch)
    ck dirExists(scratch)

  test "a top-level `ui` key is read, in every spelling a user writes":
    var compared = 0
    for (body, wanted) in [("ui: tui\n", "tui"),
                           ("ui: \"webui\"\n", "webui"),
                           ("ui: 'electron'\n", "electron"),
                           ("ui:    gui   \n", "gui"),
                           ("ui: tui  # the terminal\n", "tui"),
                           ("theme: \"x\"\nui: tui\ndebug: true\n", "tui")]:
      inc compared
      let dir = scratch / ("read-" & $compared)
      writeConfig(dir, body)
      let got = readUiFrom(dir)
      checkpoint(body.strip() & " -> '" & got & "'")
      ck got == wanted
    ck compared == 6

  test "THE SHIPPED DEFAULT CONFIG resolves to NO front-end":
    # `flow:` / `  ui: "parallel"` is in this file, and a reader that matched
    # `ui:` anywhere would answer `parallel` — an unknown value, so every
    # default installation would refuse to start. Read from the publication.
    let shipped = readFile(shippedDefaultConfig)
    # The trap is present in the bytes being read, so this is a statement about
    # a real file rather than about a hypothetical one.
    ck shipped.contains("  ui: \"parallel\"")
    let dir = scratch / "shipped"
    writeConfig(dir, shipped)
    let got = readUiFrom(dir)
    checkpoint("shipped default config -> '" & got & "'")
    ck got == ""
    # THE POSITIVE TWIN, in the same file: append a top-level key and it IS
    # found, so the "" above is about column zero and not about this reader
    # finding nothing at all.
    writeConfig(dir, shipped & "\nui: tui\n")
    ck readUiFrom(dir) == "tui"

  test "an indented `ui` key is never a front-end, whatever it is under":
    var compared = 0
    for body in ["flow:\n  ui: tui\n",
                 "flow:\n  ui: \"tui\"\n",
                 "somewhere:\n    ui: webui\n",
                 "  ui: tui\n"]:
      inc compared
      let dir = scratch / ("indent-" & $compared)
      writeConfig(dir, body)
      checkpoint(body.strip() & " -> '" & readUiFrom(dir) & "'")
      ck readUiFrom(dir) == ""
    ck compared == 4

  test "a config with no `ui` key, or an empty one, answers nothing":
    let noKey = scratch / "no-key"
    writeConfig(noKey, "theme: \"default_dark\"\ndebug: true\n")
    ck readUiFrom(noKey) == ""
    let empty = scratch / "empty-value"
    writeConfig(empty, "ui:\n")
    ck readUiFrom(empty) == ""
    let emptyFile = scratch / "empty-file"
    writeConfig(emptyFile, "")
    ck readUiFrom(emptyFile) == ""

  test "the NEAREST configuration wins, and stops the walk":
    # `common/config.findConfig` walks up from the working directory and stops
    # at the first file it finds. A reader that kept walking would let a config
    # three directories up answer for a project that has one of its own — the
    # setting would then depend on where the user stood.
    let outer = scratch / "walk"
    let inner = outer / "a" / "b"
    writeConfig(outer, "ui: webui\n")
    createDir(inner)
    # From `outer/a/b` with no file of its own, the walk finds `outer`'s.
    ck readUiFrom(inner) == "webui"
    # …and a file at `outer/a` shadows it.
    writeConfig(outer / "a", "ui: tui\n")
    ck readUiFrom(inner) == "tui"
    # …and one at `inner` shadows that.
    writeConfig(inner, "ui: electron\n")
    ck readUiFrom(inner) == "electron"
    # A nearer file with NO key answers "" rather than deferring outward. That
    # is the same rule stated from the other side, and it is the one a reader
    # that "kept looking for an answer" would get wrong.
    writeConfig(inner, "theme: \"x\"\n")
    ck readUiFrom(inner) == ""

  test "reading the configuration creates nothing and rewrites nothing":
    # `common/config.loadConfig` — the ordinary loader — CREATES
    # `~/.config/codetracer/` and COPIES the default config in, and on a parse
    # failure it REPLACES the user's file. §3.1 puts this read before any of
    # that, so it must have no effect at all. Asserted on a directory holding a
    # file this reader cannot parse.
    let dir = scratch / "no-side-effects"
    createDir(dir)
    let body = "this: is: not: yaml:\n\t- [\n"
    writeFile(dir / configPath, body)
    var before: seq[string] = @[]
    for kind, path in walkDir(dir):
      before.add path.lastPathPart
    ck readUiFrom(dir) == ""
    var after: seq[string] = @[]
    for kind, path in walkDir(dir):
      after.add path.lastPathPart
    ck after == before
    ck after.len == 1
    # Byte for byte: the file the reader could not use is the file that is
    # still there.
    ck readFile(dir / configPath) == body

suite "PLAT-1 §3: finding the component the handoff names":

  test "an explicit CODETRACER_TUI_BIN wins over everything":
    let pinned = scratch / "pinned-binary"
    writeFile(pinned, "#!/bin/sh\nexit 0\n")
    putEnv(tuiBinaryEnvVar, pinned)
    ck resolveTuiBinary("codetracer-tui") == pinned
    delEnv(tuiBinaryEnvVar)

  test "an installed component bundle is found through the launcher's roots":
    # THE REAL PACKAGING PRODUCER over the real capability file. A test that
    # assembled its own bundle would pass over a packaging script that had
    # stopped working — which is how the component would go missing in the
    # field while this stayed green.
    delEnv(tuiBinaryEnvVar)
    let componentsRoot = scratch / "components"
    let standIn = root / "src" / "build-debug" / "bin" / "ct"
    if not fileExists(standIn):
      checkpoint("missing " & standIn & " — run `just build-once`")
    ck fileExists(standIn)
    let p = startProcess("/usr/bin/env",
                         args = @["bash", "-euo", "pipefail",
                                  root / "scripts" / "build-tui-component.sh",
                                  "--out-root", componentsRoot,
                                  "--tui-bin", standIn, "--link"],
                         options = {poStdErrToStdOut})
    let output = p.outputStream.readAll()
    let rc = p.waitForExit()
    p.close()
    checkpoint("build-tui-component.sh exit " & $rc & "\n" & output)
    ck rc == 0

    var bundle = ""
    for kind, path in walkDir(componentsRoot):
      if kind == pcDir: bundle = path
    ck bundle.len > 0
    ck bundle.lastPathPart.startsWith("codetracer-tui@")
    # BYTE FOR BYTE, so the lookup below is about the bundle the product ships.
    ck readFile(bundle / "capabilities") == readFile(shippedCaps)

    putEnv(componentsRootEnvVar, componentsRoot)
    let resolved = resolveTuiBinary("codetracer-tui")
    checkpoint("resolved: " & resolved)
    ck resolved == bundle / "bin" / "codetracer-tui"
    ck fileExists(resolved) or symlinkExists(resolved)

    # THE CONTROL: with the root emptied, the same call must not answer with
    # this bundle. Without it, "the bundle was found" is satisfied by any
    # arrangement that returns a path — including one that ignored the root.
    let emptyRoot = scratch / "components-empty"
    createDir(emptyRoot)
    putEnv(componentsRootEnvVar, emptyRoot)
    let afterEmpty = resolveTuiBinary("codetracer-tui")
    checkpoint("with an empty root: '" & afterEmpty & "'")
    ck afterEmpty != bundle / "bin" / "codetracer-tui"
    delEnv(componentsRootEnvVar)

  test "CODETRACER_COMPONENT_DIR's own root is searched FIRST":
    # The launcher exports the bundle it execed; a component looking for a
    # SIBLING should look where it was itself found before it looks anywhere
    # else. Two roots, each holding a bundle, and the one named by
    # `CODETRACER_COMPONENT_DIR` must win.
    delEnv(tuiBinaryEnvVar)
    let standIn = root / "src" / "build-debug" / "bin" / "ct"
    var roots: seq[string] = @[]
    for name in ["self-root", "other-root"]:
      let r = scratch / name
      let p = startProcess("/usr/bin/env",
                           args = @["bash", "-euo", "pipefail",
                                    root / "scripts" / "build-tui-component.sh",
                                    "--out-root", r, "--tui-bin", standIn,
                                    "--link"],
                           options = {poStdErrToStdOut})
      discard p.outputStream.readAll()
      ck p.waitForExit() == 0
      p.close()
      roots.add r
    putEnv(componentsRootEnvVar, roots[1])
    # No `CODETRACER_COMPONENT_DIR`: the override root answers.
    delEnv(componentDirEnvVar)
    ck resolveTuiBinary("codetracer-tui").startsWith(roots[1])
    # With it, the sibling root answers instead — the same call, one variable
    # apart, so this is about the variable rather than about the roots.
    putEnv(componentDirEnvVar, roots[0] / "codetracer-desktop@0.0.0")
    ck resolveTuiBinary("codetracer-tui").startsWith(roots[0])
    delEnv(componentDirEnvVar)
    delEnv(componentsRootEnvVar)

  test "nothing installed anywhere answers with the empty string":
    # "" rather than a bare filename, so the caller can report the component by
    # name instead of exec'ing something that does not exist and turning a
    # missing install into ENOENT.
    delEnv(tuiBinaryEnvVar)
    delEnv(componentDirEnvVar)
    let emptyRoot = scratch / "components-empty"
    createDir(emptyRoot)
    putEnv(componentsRootEnvVar, emptyRoot)
    let answer = resolveTuiBinary("codetracer-tui-that-does-not-exist")
    checkpoint("answer: '" & answer & "'")
    ck answer == ""
    delEnv(componentsRootEnvVar)

  test "the scratch tree is removed":
    # Not a convenience: this suite writes bundles, symlinks and config files
    # under $TMPDIR, and a run that left them behind would make the next run's
    # walk-order cases depend on the previous one.
    setCurrentDir(originalDir)
    removeDir(scratch)
    ck not dirExists(scratch)

suite "assertion count":

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
