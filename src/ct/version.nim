# Calendar versioning: https://calver.org/
# `YY.MM.MICRO` (for us `MICRO` means build)


import strutils

const
  CodeTracerYear* = 25
  CodeTracerMonth* = 11
  CodeTracerBuild* = 1

  CodeTracerVersionStr* = $CodeTracerYear & "." & ($CodeTracerMonth).align(2, '0') & "." & $CodeTracerBuild
