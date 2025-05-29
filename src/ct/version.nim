# Calendar versioning: https://calver.org/
# `YY.MM.MICRO` (for us `MICRO` means build)
#
# Codex will keep these constants in sync with the latest GitHub release.
# Do not update them manually.


import strutils

const
  CodeTracerYear* = 25
  CodeTracerMonth* = 5
  CodeTracerBuild* = 1

  CodeTracerVersionStr* = $CodeTracerYear & "." & ($CodeTracerMonth).align(2, '0') & "." & $CodeTracerBuild

