# The host-free build configuration.
#
# WHAT THIS IS
# ------------
# NS1 (codetracer-specs/Planned-Work/Noir-Studio.milestones.org) asks for "a
# build configuration that **does not link the host modules**, so a direct call
# fails to compile". This file is half of it; ci/hostfree/stubs/no_host_access.nim
# is the other half, and ci/test/hostfree-build.sh proves both halves work by
# planting violations and requiring each to be rejected.
#
# Nim reads config.nims from the project directory and every parent, so a
# compile whose project file lives in ci/hostfree/ picks up the repo's normal
# search paths from ../../config.nims AND the poison below. Nothing else in the
# tree is affected: the desktop build never compiles a project file from here.
#
# WHY THIS IS STRONGER THAN THE TIME FACADE'S ENFORCEMENT
# -------------------------------------------------------
# codetracer-specs/Front-Ends/IsoNim/nim-everywhere-Time-Facade.md records its
# own weakness: "Anyone who calls std/asyncdispatch.sleepAsync or
# chronos.sleepAsync directly silently bypasses fake-time. Compile-time
# enforcement is impossible while the underlying primitives have their own
# clock." The platform facade has no such excuse — the host modules are
# separable, so here they are separated.
#
# WHY THE PATCH LIST IS SHORT, AND WHAT REPLACED IT
# --------------------------------------------------
# `patchFile` is global to the compilation: it rewrites an import for OUR code
# and for every dependency at once. Two earlier drafts of this file learned
# that the expensive way.
#
#   * Patching `std/posix` bans `std/times`, which imports it for
#     `clock_gettime`. Measured: 45 of 70 ViewModel and store modules failed,
#     none of them for a host-capability reason. The wall clock is the *time*
#     facade's concern, not this one.
#   * Patching `std/os` — even with a replacement that keeps the pure path
#     functions — broke `nim-everywhere/src/nim_everywhere/platform.nim` and
#     `isonim/src/isonim/dsl/tailwind.nim`, both of which reach the host
#     legitimately inside their own seams. Measured: 91 of 119 modules.
#
# A gate that fails for the wrong reason gets switched off, so the enforcement
# moved to a mechanism that can be *scoped*: the probe in
# ci/test/hostfree-build.sh `include`s the module under test after importing
# no_host_access.nim, which puts the poisoned declarations in that module's
# scope and in no dependency's. See that file's header for why `include` is the
# only Nim construct that scopes this way.
#
# What stays here is the subset that no dependency in the closure needs, where
# an import-level ban is strictly better than a call-level one — because then
# even a QUALIFIED call (`osproc.startProcess`) fails, and the module cannot be
# imported at all.

const hostFreeStubs = thisDir() & "/stubs"

switch("path", hostFreeStubs)

# `std/osproc` is NS1's named example ("a build that does not link `os` or
# `osproc`"). Nothing in the front-end dependency closure imports it, so it can
# be banned outright: `import std/osproc` is the error, and every name in it is
# then undeclared. `ci/test/hostfree-build.sh` scenario 2 plants exactly the
# milestone's `startProcess` and requires this to reject it.
patchFile("stdlib", "osproc", hostFreeStubs & "/osproc")

# `std/dynlib` loads arbitrary code from the host at run time. No front-end
# module has a reason to, and no dependency in the closure does.
patchFile("stdlib", "dynlib", hostFreeStubs & "/dynlib")

# `std/browsers` shells out to the platform's URL handler. That is the shell
# facade's `openExternalUrl`, which refuses anything but http/https/mailto —
# a restriction `openDefaultBrowser` does not make.
patchFile("stdlib", "browsers", hostFreeStubs & "/browsers")
