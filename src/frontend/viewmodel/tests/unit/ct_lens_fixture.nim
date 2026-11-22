## ct_lens_fixture.nim — builds the `ct-lens` plugin package
## (`src/plugins/ct-lens/`) and installs it as a component the way
## `ct install` lays one out: `<root>/ct-lens@0.1.0/{plugin.json, bin/…}`.
##
## The executable is compiled with the compiler running the suite, against
## the plugin SDK in this tree, into a private cache keyed by the CONTENT of
## its sources, so a suite that runs twice builds once. Not by their
## modification times: a mutation harness restores a subject with its old
## time, and a binary built from the mutated bytes would then look current.
##
## Nothing here stands in for anything: the package is the real plugin,
## built the way its author builds it (`docs/book/src/contributors/plugins.md`).

import std/[hashes, json, os, osproc, strutils]

import wasm_host_fixture
export wasm_host_fixture.pluginHostBin, wasm_host_fixture.RepoRoot

const
  LensSrcDir* = RepoRoot / "src" / "plugins" / "ct-lens"
  LensSdkDir* = RepoRoot / "src" / "plugin_sdk"
  LensComponent* = "ct-lens@0.1.0"
  LensExecutable* = "ct-lens-plugins"

proc lensScratchRoot*(): string =
  result = getEnv("CT_PLUGIN_TEST_SCRATCH", getTempDir() / "ct-plugin-process-tests") /
           "ct-lens"
  createDir(result)

proc lensSourceKey(): string =
  ## The bytes the executable is built from, hashed.
  var files = @[LensSdkDir / "codetracer_plugin_sdk.nim",
                RepoRoot / "src/frontend/viewmodel/plugin_host/protocol.nim",
                RepoRoot / "src/frontend/viewmodel/sync/mirror_session.nim"]
  for f in walkFiles(LensSrcDir / "*.nim"): files.add f
  var h: Hash = 0
  for f in files:
    if fileExists(f):
      h = h !& hash(f) !& hash(readFile(f))
  $(!$h) & "-" & getCurrentCompilerExe()

proc buildLensExecutable*(): string =
  ## The built `ct-lens-plugins`, rebuilt when a source is newer.
  let outDir = lensScratchRoot() / "build"
  createDir(outDir)
  result = outDir / LensExecutable
  let stamp = result & ".sources"
  let key = lensSourceKey()
  if fileExists(result) and fileExists(stamp) and readFile(stamp) == key:
    return
  let nim = getCurrentCompilerExe()
  let cmd = quoteShellCommand([nim, "c", "--hints:off", "--warnings:off",
    "--threads:on", "--mm:orc", "-d:release",
    "--path:" & LensSdkDir,
    "--nimcache:" & outDir / "nimcache",
    "-o:" & result, LensSrcDir / "ct_lens_plugins.nim"])
  let (output, code) = execCmdEx(cmd, workingDir = RepoRoot)
  doAssert code == 0, "building the ct-lens package failed:\n" & output
  writeFile(stamp, key)

proc installLens*(root: string; manifest = ""): string =
  ## Install the package under `root`; returns the component directory.
  ## `manifest` replaces `plugin.json` when given.
  let exe = buildLensExecutable()
  result = root / LensComponent
  createDir(result / "bin")
  copyFileWithPermissions(exe, result / "bin" / LensExecutable)
  writeFile(result / "plugin.json",
    if manifest.len > 0: manifest else: readFile(LensSrcDir / "plugin.json"))

proc installLensWasm*(root: string): string =
  ## The WebAssembly port of `ct-lens.watch` (`ct_lens_watch_wasm.nim`,
  ## `wasm/plugin.json`), installed under `root` as the component `ct-lens`:
  ## `plugin.json` and one `plugin.wasm`, the artifact every platform runs.
  ## `CT_LENS_WASM_MODULE` names a module built elsewhere — on another
  ## platform, to show that one artifact serves both.
  let given = getEnv("CT_LENS_WASM_MODULE", "")
  let module = if given.len > 0: given else: buildWasmModule(LensSrcDir / "ct_lens_watch_wasm.nim",
    "ct-lens-watch", @["--path:" & LensSrcDir],
    @[LensSrcDir / "lens_watch.nim",
      RepoRoot / "src/frontend/viewmodel/viewmodels/value_changes.nim"])
  result = root / LensComponent
  createDir(result)
  copyFile(module, result / "plugin.wasm")
  writeFile(result / "plugin.json", readFile(LensSrcDir / "wasm" / "plugin.json"))

proc lensManifest*(): JsonNode =
  parseJson(readFile(LensSrcDir / "plugin.json"))

proc lensPids*(): seq[int] =
  ## Every running `ct-lens-plugins` started from an installed component.
  let (o, _) = execCmdEx("pgrep -f " & LensComponent & "/bin/" & LensExecutable)
  for l in o.splitLines:
    if l.strip.len > 0: result.add parseInt(l.strip)

# ---------------------------------------------------------------------------
# A git repository with a known history, for the line-history plugin
# ---------------------------------------------------------------------------

proc git(dir: string; args: varargs[string]) =
  let (o, code) = execCmdEx(quoteShellCommand(@["git", "-C", dir] & @args))
  doAssert code == 0, "git " & args.join(" ") & " failed:\n" & o

proc makeHistoryRepo*(dir: string): string =
  ## A real repository whose `calc.py` has three commits: one that created
  ## it, one that changed `apply` (lines 4-6) and one that changed only
  ## `other` (lines 9-10). Returns the file's path.
  removeDir(dir)
  createDir(dir)
  git(dir, "init", "-q")
  git(dir, "config", "user.name", "Lens Tester")
  git(dir, "config", "user.email", "lens@example.invalid")
  git(dir, "config", "commit.gpgsign", "false")
  result = dir / "calc.py"
  writeFile(result, "import sys\n\n\ndef apply(a, b):\n    total = a + b\n" &
                    "    return total\n\n\ndef other():\n    return 1\n")
  git(dir, "add", "calc.py")
  git(dir, "commit", "-q", "-m", "create the calculator")
  writeFile(result, "import sys\n\n\ndef apply(a, b):\n    total = a * b\n" &
                    "    return total\n\n\ndef other():\n    return 1\n")
  git(dir, "commit", "-q", "-am", "multiply instead of adding")
  writeFile(result, "import sys\n\n\ndef apply(a, b):\n    total = a * b\n" &
                    "    return total\n\n\ndef other():\n    return 2\n")
  git(dir, "commit", "-q", "-am", "other returns two")
