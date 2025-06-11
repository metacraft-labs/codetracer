# Thank you, Lord and GOD Jesus!

import
  ../common/ct_logging,
  launch/[ launch ],
  codetracerconf, confutils,
  version

try:
  if not eventuallyWrapElectron():
    # TODO: When confutils gets updated with nim 2 make sure to improve on the copyright banner, as newer versions
    # support having prefix and postfix banners. The banner here is only a prefix banner
    let conf = CodetracerConf.load(
      version="CodeTracer version: " & string(version.CodeTracerVersionStr) & string(when defined(debug): "(debug)" else: ""),
      copyrightBanner="CodeTracer - the user-friendly time-travelling debugger"
    )
    customValidateConfig(conf)
    runInitial(conf)
except Exception as ex:
  errorPrint "Unhandled exception"
  errorPrint getStackTrace(ex)
  errorPrint "Unhandled " & ex.msg