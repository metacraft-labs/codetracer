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

import std/os

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
