import repro_project_dsl

defineCliInterface nimJs, "nim-js":
  subcmd "js":
    flag defines, seq[string],
      alias = "-d:",
      format = concat,
      repeated = true
    flag mm, string,
      alias = "--mm:",
      format = concat
    boolFlag hintsOff, alias = "--hints:off"
    boolFlag warningsOff, alias = "--warnings:off"
    flag disabledHints, seq[string],
      alias = "--hint[",
      format = concat,
      repeated = true
    flag disabledWarnings, seq[string],
      alias = "--warning[",
      format = concat,
      repeated = true
    boolFlag debugInfo, alias = "--debugInfo"
    boolFlag debugInfoOn, alias = "--debugInfo:on"
    boolFlag lineDirOn, alias = "--lineDir:on"
    boolFlag stacktraceOn, alias = "--stacktrace:on"
    boolFlag linetraceOn, alias = "--linetrace:on"
    boolFlag sourcemapOn, alias = "--sourcemap:on"
    boolFlag hotCodeReloadingOn, alias = "--hotCodeReloading:on"
    flag output, string,
      alias = "--out:",
      format = concat,
      role = output,
      required = true
    flag paths, seq[string],
      alias = "--path:",
      format = concat,
      repeated = true
    pos source, string,
      role = input,
      position = 0
