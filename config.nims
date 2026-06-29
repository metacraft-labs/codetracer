import std/[os, strutils]

proc addPathIfDir(path: string) =
  if path.len > 0 and dirExists(path):
    switch("path", path)

let repoRoot = currentSourcePath().parentDir()
let workspaceRoot = repoRoot.parentDir()

# The top-level `ct` entry point imports `src/ct_test/incremental_cli`.
# Nim loads config files from the main module's directory, not from imported
# module directories, so `src/ct_test/nim.cfg` is not seen when compiling `ct`.
# Mirror the sibling discovery used by the dev shell: prefer an explicit source
# path, then the normal workspace sibling checkout.
addPathIfDir(getEnv("CODETRACER_TRACE_FORMAT_NIM_SRC"))
addPathIfDir(workspaceRoot / "codetracer-trace-format-nim" / "src")
addPathIfDir(getEnv("IO_MON_SRC"))
addPathIfDir(workspaceRoot / "io-mon" / "src")
addPathIfDir(getEnv("NIM_STACKABLE_HOOKS_SRC"))
addPathIfDir(workspaceRoot / "nim-stackable-hooks" / "src")

const runquotaLibs = [
  "runquota_process",
  "runquota_core",
  "runquota_host",
  "runquota_host_macos",
  "runquota_host_linux",
  "runquota_host_windows",
  "runquota_codec",
  "runquota_protocol",
]

let runquotaSrc = getEnv("RUNQUOTA_SRC")
for lib in runquotaLibs:
  addPathIfDir(runquotaSrc / "libs" / lib / "src")
  addPathIfDir(workspaceRoot / "runquota" / "libs" / lib / "src")

# The trace-format Nim reader uses the `results` package >= 0.5. Keep this
# ahead of the repo-vendored `libs/nim-result` when available. CodeTracer code
# should import `results` directly; the deprecated singular `result` shim is not
# present in newer releases.
addPathIfDir(getEnv("CODETRACER_RESULTS_SRC"))
let pkgs2 = getHomeDir() / ".nimble" / "pkgs2"
if dirExists(pkgs2):
  var best = ""
  for kind, path in walkDir(pkgs2):
    if kind == pcDir and path.lastPathPart.startsWith("results-0.5"):
      if best.len == 0 or path.lastPathPart > best.lastPathPart:
        best = path
  addPathIfDir(best)

block:
  let nixCflags = getEnv("NIX_CFLAGS_COMPILE")
  if nixCflags.len > 0:
    let toks = nixCflags.splitWhitespace()
    var i = 0
    while i < toks.len:
      if toks[i] == "-isystem" and i + 1 < toks.len:
        let dir = toks[i + 1]
        if "zstd" in dir:
          switch("passC", "-isystem " & dir)
        i += 2
      else:
        i += 1
