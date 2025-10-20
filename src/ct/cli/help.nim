import
  std/[ osproc ],
  ../../common/[paths]

proc displayHelp*: void =
  # echo "help: TODO"
  let process = startProcess(codetracerExe, args = @["--help"], options = {poParentStreams, poUsePath})
  let code = waitForExit(process)
  quit(code)
