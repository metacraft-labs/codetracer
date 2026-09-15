## version_gpui.nim — the `codetracer-gpui` component's own version string.
##
## A module of its own rather than a literal in `main.nim` for the reason
## `src/ct/version.nim` is one: a version printed by `--version` and a version
## written into a component's capability file are the same claim, and two
## spellings of one claim part (Verification-Harness-Traps §14).
##
## It is deliberately NOT `src/ct/version.nim`'s value. `codetracer-gpui` is a
## separate component the launcher resolves independently — the same status
## `codetracer-tui` has — so it versions on its own axis, and a user running a
## desktop from one release beside a GPUI front-end from another must be able to
## see that.

const GpuiFrontEndVersion* = "0.1.0-plat20"
  ## PLAT-20 ships the SHELL. The suffix is in the version rather than in a
  ## release note because a binary that draws pane names and no debugger
  ## surfaces should say which milestone it is, and `0.1.0` alone would not.
