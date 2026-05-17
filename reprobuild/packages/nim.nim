import repro_project_dsl

defineCliInterface nim, "nim":
  subcmd "c":
    flag defines, seq[string],
      alias = "-d:",
      format = concat,
      repeated = true
    flag mm, string,
      alias = "--mm:",
      format = concat
    boolFlag hintsOff, alias = "--hints:off"
    boolFlag hintsOn, alias = "--hints:on"
    boolFlag warningsOff, alias = "--warnings:off"
    boolFlag warningsOn, alias = "--warnings:on"
    flag disabledHints, seq[string],
      alias = "--hint[",
      format = concat,
      repeated = true
    flag disabledWarnings, seq[string],
      alias = "--warning[",
      format = concat,
      repeated = true
    boolFlag debugInfo, alias = "--debugInfo"
    boolFlag lineDirOn, alias = "--lineDir:on"
    boolFlag stacktraceOn, alias = "--stacktrace:on"
    boolFlag linetraceOn, alias = "--linetrace:on"
    boolFlag boundChecksOn, alias = "--boundChecks:on"
    flag dynlibOverrides, seq[string],
      alias = "--dynlibOverride:",
      format = concat,
      repeated = true
    flag passL, seq[string],
      alias = "--passL:",
      format = concat,
      repeated = true
    flag nimcache, string,
      alias = "--nimcache:",
      format = concat
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
