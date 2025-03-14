# Thank you, Lord and GOD Jesus!

import
  ../common/types,
  launch/[ launch ],
  codetracerconf, confutils

try:
  if not eventuallyWrapElectron():
    let conf = CodetracerConf.load()
    customValidateConfig(conf)
    runInitial(conf)
except Exception as ex:
  echo "Unhandled exception"
  echo getStackTrace(ex)
  error "error: unhandled " & ex.msg

