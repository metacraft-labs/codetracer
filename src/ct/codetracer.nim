# Thank you, Lord and GOD Jesus!

import
  ../common/types,
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
  echo "Unhandled exception"
  echo getStackTrace(ex)
  error "error: unhandled " & ex.msg

