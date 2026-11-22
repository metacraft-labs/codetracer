## plugin_host_path.nim — THE answer to "which `ct-plugin-host` runs the WASM
## plugin packages" (Extensibility-Model.md §11.9), for every front-end that
## runs plugins: the terminal, GPUI, the desktop's main process and `ct host`.
##
## In the order they are preferred:
##
## 1. `CODETRACER_PLUGIN_HOST` — the path to run, as given;
## 2. beside the running program: `<dir of the executable>/ct-plugin-host`. A
##    release lays the host next to the front-end that runs it — the TUI
##    component's `bin/`, `build/bin/` in a checkout (`just build-plugin-host`);
## 3. the installation prefix's `bin/` (`CODETRACER_PREFIX`, which the desktop
##    and `ct host` packages set): `<prefix>/bin/ct-plugin-host`.
##
## The candidates are computed without touching the filesystem, so a test can
## assert the order; `findPluginHost` returns the first that exists, or "".

import std/strutils

when defined(js):
  import std/envvars
  import ./node_os
else:
  import std/os

const
  PluginHostEnv* = "CODETRACER_PLUGIN_HOST"
  PluginHostExe* = when defined(windows): "ct-plugin-host.exe"
                   else: "ct-plugin-host"

proc joinPath2(a, b: string): string =
  if a.endsWith("/"): a & b else: a & "/" & b

proc pluginHostCandidates*(appDir, prefix: string): seq[string] =
  ## `appDir`: the directory of the running executable ("" when there is
  ## none, as in Electron's renderer). `prefix`: the installation prefix, or "".
  proc addOnce(acc: var seq[string]; p: string) =
    if p.len > 0 and p notin acc: acc.add p
  result.addOnce getEnv(PluginHostEnv, "")
  if appDir.len > 0:
    result.addOnce joinPath2(appDir, PluginHostExe)
  if prefix.len > 0:
    result.addOnce joinPath2(joinPath2(prefix, "bin"), PluginHostExe)

proc findPluginHost*(appDir, prefix: string): string =
  for c in pluginHostCandidates(appDir, prefix):
    if fileExists(c): return c
  ""

when not defined(js):
  proc findPluginHost*(): string =
    ## For a native front-end: beside this executable (symlinks resolved, so a
    ## component's linked `bin/` finds the host beside the real binary), then
    ## `CODETRACER_PREFIX/bin`.
    findPluginHost(getAppDir(), getEnv("CODETRACER_PREFIX", ""))
