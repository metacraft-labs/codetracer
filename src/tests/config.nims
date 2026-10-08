# Every test program under this directory runs with private per-user state:
# `test_support/state_isolation` points `XDG_STATE_HOME` and
# `CODETRACER_TUI_LAYOUT_DIR` away from the developer's own before the suite
# starts, so no suite (or binary it spawns) reads or writes
# `~/.local/state/codetracer`. See that module's header.
import std/os
switch("import", currentSourcePath().parentDir() / "../frontend/test_support/state_isolation.nim")
