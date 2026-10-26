## gpui_child_env.nim — the environment a GPUI suite gives the
## `build/bin/codetracer-gpui` it starts.
##
## The binary `dlopen`s isonim-gpui's `libgpui_nim_shim.so`, and a shim built
## with `--features gpui-backend` needs libraries of its own (`libxcb`,
## `libxkbcommon`, …). On a NixOS host nothing puts those on the loader's
## default path. Two PLAT-44 suites started the binary with a fresh
## environment that held only the shim's directory, so every typed case
## exited 1 with "could not load: libgpui_nim_shim.so" (codetracer-pm issue
## 2026-10-22, "plat44 gpui suites spawn the binary with only the shim dir on
## LD_LIBRARY_PATH"). A fresh environment also drops `HOME` and `PATH` and
## leaves the child's per-user state unset.
##
## Where the libraries come from. The dev shell exports them as
## `CODETRACER_GPUI_RUNTIME_LIB_PATH` and deliberately does NOT put them on
## `LD_LIBRARY_PATH`: every process of the shell would then resolve that GL /
## Vulkan / Wayland stack first (`nix/shells/ci-base.nix`, "PLAT-37 — THE GPUI
## RUNTIME LIBRARY PATH"). The processes that need them prepend them
## themselves — the `ci/test/*-window.sh` captures do, and so does this
## helper, for the GPUI child only. Prepending the shim's directory to the
## inherited `LD_LIBRARY_PATH` alone is not enough: measured inside
## `repro exec .` on NixOS (2026-10-26), that child still fails to load the
## shim, and every GPUI plan suite that spelled it that way failed the same
## way; they now take `gpuiLibraryPath`. A host whose inherited
## `LD_LIBRARY_PATH` already carries them (a shell that exported it) keeps
## working, since that value follows.
##
## So the child gets:
##
##   * the WHOLE inherited environment;
##   * `LD_LIBRARY_PATH` = the shim's directory, then
##     `CODETRACER_GPUI_RUNTIME_LIB_PATH`, then the inherited value — each
##     only when non-empty;
##   * the case's own state directory as `CODETRACER_TUI_LAYOUT_DIR` and
##     `XDG_STATE_HOME`, and `CODETRACER_HOME` under it ("Tests never touch
##     your real CodeTracer state" in codetracer `AGENTS.md`), as
##     `test_plat48_gpui_plan.nim`'s `windowPlan` does.
##
## Not named `test_*.nim`: the `gpui-shell` lane runs every `test_*.nim` in
## this directory as a suite, and this module is not one.
## `test_gpui_child_env.nim` pins its contract.

import std/[os, strtabs, strutils]

const RuntimeLibPathEnvVar* = "CODETRACER_GPUI_RUNTIME_LIB_PATH"
  ## The dev shell's GPUI runtime library path (`nix/shells/ci-base.nix`).

proc gpuiLibraryPath*(shimDir: string): string =
  ## The `LD_LIBRARY_PATH` for a `codetracer-gpui` child whose shim lives in
  ## `shimDir`: `shimDir`, then `$CODETRACER_GPUI_RUNTIME_LIB_PATH`, then this
  ## process's `$LD_LIBRARY_PATH`. For the suites that build the rest of the
  ## child's environment themselves (their state variables differ on
  ## purpose); `gpuiChildEnv` uses it too.
  # Each part only when non-empty: an empty element (a leading, doubled or
  # trailing ':') is read by the dynamic loader as the current directory
  # (ld.so(8), "LD_LIBRARY_PATH").
  var parts = @[shimDir]
  for inherited in [getEnv(RuntimeLibPathEnvVar), getEnv("LD_LIBRARY_PATH")]:
    if inherited.len > 0:
      parts.add inherited
  parts.join(":")

proc gpuiChildEnv*(shimDir, stateDir: string): StringTableRef =
  ## The environment for a `codetracer-gpui` child whose shim lives in
  ## `shimDir` and whose per-user state belongs under `stateDir`. The calling
  ## process's own environment is read, never changed.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  result["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  # `loadKeymapPreference` and the layout store read the TUI layout directory;
  # a suite that writes `<stateDir>/keymap` chooses the child's keymap here.
  result["CODETRACER_TUI_LAYOUT_DIR"] = stateDir
  result["XDG_STATE_HOME"] = stateDir
  # Every other per-user location of the child (trace index, config, caches,
  # tmp): its own, under this case's directory (`common/ct_home`).
  result["CODETRACER_HOME"] = stateDir / "ct-home"
