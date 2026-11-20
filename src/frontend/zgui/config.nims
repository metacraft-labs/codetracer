# The zgui front-end (codetracer-zgui) and its suites render through
# isonim-zgui, the IsoNim renderer on zgui's retained document. It is reached
# like the other renderer siblings: the workspace checkout, then
# ISONIM_ZGUI_SRC, which overrides it (Nim searches later `--path` entries
# first). Only this tree imports it, so the path is added here rather than in
# the repository's config.nims.
import std/os

let zguiWorkspaceRoot = currentSourcePath().parentDir() / ".." / ".." / ".." / ".."
if dirExists(zguiWorkspaceRoot / "isonim-zgui" / "src"):
  switch("path", zguiWorkspaceRoot / "isonim-zgui" / "src")
if getEnv("ISONIM_ZGUI_SRC").len > 0 and dirExists(getEnv("ISONIM_ZGUI_SRC")):
  switch("path", getEnv("ISONIM_ZGUI_SRC"))
