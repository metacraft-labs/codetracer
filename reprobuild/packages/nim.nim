import repro_project_dsl

defineCliInterface nim, "nim":
  dependencyPolicy automaticMonitor

  template commonNimCompilerFlags() =
    flag defines is seq[string],
      alias = "-d:",
      format = concat,
      repeated = true
    flag mm is string,
      alias = "--mm:",
      format = concat
    boolFlag hintsOff is bool, alias = "--hints:off"
    boolFlag warningsOff is bool, alias = "--warnings:off"
    flag disabledHints is seq[string],
      alias = "--hint[",
      format = concat,
      repeated = true
    flag disabledWarnings is seq[string],
      alias = "--warning[",
      format = concat,
      repeated = true
    boolFlag debugInfo is bool, alias = "--debugInfo"
    boolFlag lineDirOn is bool, alias = "--lineDir:on"
    boolFlag stacktraceOn is bool, alias = "--stacktrace:on"
    boolFlag linetraceOn is bool, alias = "--linetrace:on"

  template nativeNimCompilerFlags() =
    boolFlag hintsOn is bool, alias = "--hints:on"
    boolFlag warningsOn is bool, alias = "--warnings:on"
    boolFlag boundChecksOn is bool, alias = "--boundChecks:on"
    flag dynlibOverrides is seq[string],
      alias = "--dynlibOverride:",
      format = concat,
      repeated = true
    flag passL is seq[string],
      alias = "--passL:",
      format = concat,
      repeated = true
    flag nimcache is string,
      alias = "--nimcache:",
      format = concat

  template jsNimCompilerFlags() =
    boolFlag debugInfoOn is bool, alias = "--debugInfo:on"
    boolFlag sourcemapOn is bool, alias = "--sourcemap:on"
    boolFlag hotCodeReloadingOn is bool, alias = "--hotCodeReloading:on"

  template nimOutputAndSource() =
    flag output is string,
      alias = "--out:",
      format = concat,
      role = output,
      required = true
    flag paths is seq[string],
      alias = "--path:",
      format = concat,
      repeated = true
    pos source is string,
      role = input,
      position = 0

  subcmd "c":
    commonNimCompilerFlags()
    nativeNimCompilerFlags()
    nimOutputAndSource()

  subcmd "js":
    commonNimCompilerFlags()
    jsNimCompilerFlags()
    nimOutputAndSource()
