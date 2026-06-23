# RUNQUOTA_SRC fallback for the runquota_process import paths.
#
# nim.cfg (next to this file) lists the runquota library paths relative to a
# normal workspace checkout (metacraft/codetracer/... -> metacraft/runquota).
# That relative layout does not resolve in two important cases:
#
#   * a git worktree under .claude/worktrees/<name>/, where the codetracer repo
#     root is several directories deeper than the workspace root, and
#   * CI / standalone clones that only have the flake-pinned runquota source.
#
# In both cases the codetracer nix dev shell exports RUNQUOTA_SRC pointing at
# the flake input's runquota source tree. Nim .cfg files cannot expand OS
# environment variables in --path values, but NimScript config (this file) can,
# so we add the RUNQUOTA_SRC-based paths here when the variable is set. Adding
# extra paths is harmless when the relative sibling paths already resolved —
# Nim picks the first module it finds.

import std/[os, strutils]

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
if runquotaSrc.len > 0:
  for lib in runquotaLibs:
    switch("path", runquotaSrc / "libs" / lib / "src")

# M1 (Incremental-Test-Runner): codetracer-trace-format-nim source fallback.
#
# nim.cfg (next to this file) lists the trace-format-nim source relative to a
# normal workspace checkout (codetracer/src/ct_test/../../../codetracer-trace-format-nim/src).
# That relative layout does not resolve in a git worktree under
# .claude/worktrees/<name>/ or in CI / standalone clones that only have the
# flake-pinned source. In those cases set CODETRACER_TRACE_FORMAT_NIM_SRC to
# the package's `src` dir. Adding the extra path is harmless when the relative
# sibling already resolved — Nim picks the first module it finds.
let traceFormatSrc = getEnv("CODETRACER_TRACE_FORMAT_NIM_SRC")
if traceFormatSrc.len > 0:
  switch("path", traceFormatSrc)

# M6b (Incremental-Test-Runner): io-mon + nim-stackable-hooks source fallbacks.
#
# nim.cfg lists these relative to a normal workspace checkout
# (codetracer/src/ct_test/../../../io-mon/src and .../nim-stackable-hooks/src).
# That relative layout does not resolve in a git worktree under
# .claude/worktrees/<name>/ or in CI / standalone clones that only have the
# flake-pinned sources. In those cases set IO_MON_SRC / NIM_STACKABLE_HOOKS_SRC
# to the package `src` dirs. Adding the extra path is harmless when the relative
# sibling already resolved — Nim picks the first module it finds.
let ioMonSrc = getEnv("IO_MON_SRC")
if ioMonSrc.len > 0:
  switch("path", ioMonSrc)
let stackableHooksSrc = getEnv("NIM_STACKABLE_HOOKS_SRC")
if stackableHooksSrc.len > 0:
  switch("path", stackableHooksSrc)

# M1 (Incremental-Test-Runner): `results` version pin for the seekable CTFS
# reader.
#
# codetracer-trace-format-nim is written against the `results` package >= 0.5
# (its `?` short-circuit operator expands to the `.v` field that version
# introduced).  codetracer vendors an OLDER `results` at `libs/nim-result`
# (added to the path by the repo-root nim.cfg), which lacks that field, so
# compiling the trace-format-nim modules `ctfs_seekable.nim` imports fails with
# "undeclared field: 'v'" unless a >= 0.5 `results` is searched FIRST.
#
# config.nims `switch("path", ...)` runs during config evaluation and the path
# it adds is searched ahead of the repo-root `libs/nim-result`, so pinning the
# newer `results` here makes ONLY the ct_test build prefer it (the rest of the
# codetracer build is untouched).  Resolution order:
#   1. CODETRACER_RESULTS_SRC env var (CI / standalone clones point this at a
#      checkout of results >= 0.5), else
#   2. the newest `results-0.5*` package under `~/.nimble/pkgs2` (the dev shell
#      provisions it as a trace-format-nim dependency).
# When neither resolves we add nothing and the build falls back to the vendored
# results — the seekable read then fails to compile loudly rather than silently
# mis-resolving, surfacing the missing dependency.
proc pinNewerResults() =
  let envSrc = getEnv("CODETRACER_RESULTS_SRC")
  if envSrc.len > 0 and dirExists(envSrc):
    switch("path", envSrc)
    return
  let pkgs2 = getHomeDir() / ".nimble" / "pkgs2"
  if dirExists(pkgs2):
    var best = ""
    for kind, p in walkDir(pkgs2):
      if kind == pcDir and p.lastPathPart.startsWith("results-0.5"):
        if p.lastPathPart > best.lastPathPart:
          best = p
    if best.len > 0:
      switch("path", best)

pinNewerResults()

# M1 (Incremental-Test-Runner): ensure <zstd.h> resolves for the trace-format-nim
# modules.
#
# codetracer-trace-format-nim's CTFS reader links libzstd and `#include`s the
# system <zstd.h>.  The codetracer dev shell ships the header via the nix
# cc-wrapper's `NIX_CFLAGS_COMPILE` (`-isystem .../zstd-*-dev/include`), but the
# repo-root nim.cfg's compiler options can shadow that wrapper injection on some
# build paths, so a bare `nim c` of an engine test that pulls in the reader
# fails with "'zstd.h' file not found".  We re-surface the zstd dev include
# directories out of `NIX_CFLAGS_COMPILE` and pass them explicitly with
# `--passC`, which is harmless when the wrapper already supplied them (duplicate
# `-isystem` is a no-op) and decisive when it did not.  No-op outside Nix (the
# env var is empty / carries no zstd include) — non-Nix builds get the header
# from the system include path as usual.
block:
  let nixCflags = getEnv("NIX_CFLAGS_COMPILE")
  if nixCflags.len > 0:
    let toks = nixCflags.splitWhitespace()
    var i = 0
    while i < toks.len:
      # NIX_CFLAGS_COMPILE encodes include dirs as the two tokens
      # "-isystem" "<dir>"; forward only the zstd ones we actually need.
      if toks[i] == "-isystem" and i + 1 < toks.len:
        let dir = toks[i + 1]
        if "zstd" in dir:
          switch("passC", "-isystem " & dir)
        i += 2
      else:
        i += 1
