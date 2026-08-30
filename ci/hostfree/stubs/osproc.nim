## Host-free build: `std/osproc` is not linked.
##
## Patched in by `ci/hostfree/config.nims`. Importing it is a compile error
## rather than a link error, so the violation names the file that caused it.
##
## If you need this capability, it belongs behind the platform facade at
## `src/frontend/viewmodel/platform/` — see NS1 in
## `codetracer-specs/Planned-Work/Noir-Studio.milestones.org`. If your module
## genuinely is host-side (the desktop or container instantiation, or
## `src/frontend/index/`), it does not belong in the host-free surface: see
## `ci/hostfree/README` for how the surface is chosen.
{.error: "std/osproc is not linked in the host-free build; route this through src/frontend/viewmodel/platform (NS1, the platform facade)".}
