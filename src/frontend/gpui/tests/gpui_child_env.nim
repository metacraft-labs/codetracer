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

const WindowRunCeilingS* = 300
  ## How long one run of `codetracer-gpui` a GPUI suite starts may take
  ## before it is killed (`timeout`), in seconds. A HANG CEILING, NOT A
  ## TIMING EXPECTATION: a run that never finishes (a move the engine never
  ## answers) fails instead of waiting forever, and nothing else is read
  ## into it. Two minutes was not enough on a machine at load 150, where
  ## three plat50 runs were cut off mid-run; CI runners are loaded too.

proc gpuiRunScript*(redirects = ""; ceilingS = WindowRunCeilingS): string =
  ## The `/bin/sh -c` script a suite starts `codetracer-gpui` with: `$0` is
  ## the binary, `$@` its arguments, `redirects` its streams' files; run
  ## under `timeout` at the hang ceiling, so every run a suite starts this
  ## way has one.
  "exec timeout " & $ceilingS & " \"$0\" \"$@\"" &
    (if redirects.len > 0: " " & redirects else: "")

const TimeoutKilledExit* = 124
  ## The status `timeout` exits with when it killed the run at its ceiling.

proc gpuiExitText*(rc: int; ceilingS = WindowRunCeilingS): string =
  ## How a suite names a run's non-zero status: a run `gpuiRunScript`'s
  ## `timeout` killed is a HANG, said as one, not one more failed exit.
  if rc == TimeoutKilledExit: "hung past WindowRunCeilingS (" & $ceilingS & " s) and was killed"
  else: "exited " & $rc

const RuntimeLibPathEnvVar* = "CODETRACER_GPUI_RUNTIME_LIB_PATH"
  ## The dev shell's GPUI runtime library path (`nix/shells/ci-base.nix`).

const GpuiShimLibrary* =
  when defined(windows): "gpui_nim_shim.dll"
  elif defined(macosx): "libgpui_nim_shim.dylib"
  else: "libgpui_nim_shim.so"
  ## The file a `codetracer-gpui` child dlopens from its shim directory (the
  ## names `ci/lib/gpui-refusal-prereqs.sh` stages).

proc gpuiLibraryPath*(shimDir: string): string =
  ## The `LD_LIBRARY_PATH` for a `codetracer-gpui` child whose shim lives in
  ## `shimDir`: `shimDir`, then `$CODETRACER_GPUI_RUNTIME_LIB_PATH`, then this
  ## process's `$LD_LIBRARY_PATH`. For the suites that build the rest of the
  ## child's environment themselves (their state variables differ on
  ## purpose); `gpuiChildEnv` uses it too.
  ##
  ## Raises `IOError`, naming the file, when `shimDir` holds no shim. A child
  ## without one dies when it dlopens it, so every case of the suite failed
  ## as if the window were wrong: a grading layout whose isonim-gpui target
  ## had no shim ran `test_plat48_gpui_plan` 0 OK / 14 FAILED, and its
  ## mutation harness read that as a red baseline (`just build-gpui` only
  ## warns that the shim is not built).
  let shim = shimDir / GpuiShimLibrary
  if not fileExists(shim):
    raise newException(IOError, "prerequisite missing: " & shim &
      " (isonim-gpui's Rust shim: build it with `cd ../isonim-gpui && just " &
      "rust-build`, or point ISONIM_GPUI_SHIM_DIR at a built one)")
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
