# Thank you, Lord and GOD Jesus!

import
  launch/[ launch ],
  codetracerconf, confutils,
  version

# M4: Inline library path setup (replaces ct_wrapper.nim + ct_paths.json).
# Read CODETRACER_LD_LIBRARY_PATH and prepend to LD_LIBRARY_PATH so that
# Nix store libraries (SQLite, PCRE, etc.) are found at runtime.
when not defined(js) and not defined(windows):
  import std / os
  block:
    let ctLibPath = getEnv("CODETRACER_LD_LIBRARY_PATH")
    if ctLibPath.len > 0:
      let current = getEnv("LD_LIBRARY_PATH")
      if current.len > 0:
        putEnv("LD_LIBRARY_PATH", ctLibPath & ":" & current)
      else:
        putEnv("LD_LIBRARY_PATH", ctLibPath)

try:
  # TODO: When confutils gets updated with nim 2 make sure to improve on the copyright banner, as newer versions
  # support having prefix and postfix banners. The banner here is only a prefix banner
  let conf = CodetracerConf.load(
    version="CodeTracer version: " & version.CodeTracerVersionStr & (when defined(debug): "(debug)" else: ""),
    copyrightBanner="CodeTracer - the user-friendly time-travelling debugger"
  )
  customValidateConfig(conf)
  runInitial(conf)
except CatchableError as ex:
  echo "Error: Unhandled exception"
  echo getStackTrace(ex)
  echo "Unhandled " & ex.msg
