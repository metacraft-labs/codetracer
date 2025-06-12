import std/[json, os, osproc, streams, strutils]

# TODO: get name from config? Maybe use SQLite?
const CONTRACT_WASM_PATH = getHomeDir() / ".local" / "share" / "codetracer" / "contract-debug-wasm"

proc doDeploy(): string =
  # TODO: get endpoint and private key and other params from args
  let process = startProcess(
    "cargo",
    args=["stylus", "deploy", "--endpoint=http://localhost:8547", "--private-key=0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659"],
    options={poEchoCmd, poUsePath, poStdErrToStdOut}
  )
  defer: process.close()

  let outStream = process.outputStream

  var output = ""

  while process.running:
    output.add(outStream.readAll())

  let exitCode = process.peekExitCode()

  if exitCode != 0:
    echo "Stylus deployment failed! Output:"
    echo output
    # TODO: maybe specific exception
    raise newException(CatchableError, "Stylus deployment failed!")

  let lines = output.splitLines()
  for line in lines:
    if not line.contains("deployed code at address:"):
      continue

    let addrStartInd = line.find("0x")
    return line[addrStartInd .. addrStartInd + 41]

  # Cool, when deployment fails, the exit code of cargo stylus deploy is 0...
  # TODO: maybe specific exception
  raise newException(CatchableError, "Stylus deployment failed!")


proc doDebugBuild(): string =
  # TODO: get endpoint and private key and other params from args
  let process = startProcess(
    "cargo",
    args=["build", "--target", "wasm32-unknown-unknown"],
    options={poEchoCmd, poUsePath, poStdErrToStdOut}
  )
  defer: process.close()

  let outStream = process.outputStream

  var output = ""

  while process.running:
    output.add(outStream.readAll())

  let exitCode = process.peekExitCode()

  if exitCode != 0:
    echo "Debug build failed! Output:"
    echo output
    # TODO: maybe specific exception
    raise newException(CatchableError, "Debug build failed!")

  let pwd = getCurrentDir()
  let wasmDebugTargetDir = pwd / "target" / "wasm32-unknown-unknown" / "debug"

  var possibleFiles: seq[string] = @[]
  for file in walkFiles(wasmDebugTargetDir / "*.wasm"):
    let wasm = readFile(file)
    if wasm.contains("vm_hooks"):
      possibleFiles.add(file)

  if possibleFiles.len == 0:
    # TODO: maybe specific exception
    raise newException(CatchableError, "No Stylus WASM files found in " & wasmDebugTargetDir)

  if possibleFiles.len > 1:
    # TODO: make select the wasm file
    raise newException(CatchableError, "Multiple Stylus WASM files found in " & wasmDebugTargetDir)

  return possibleFiles[0]

proc saveContractDebugWasm(deploymentAddr: string, wasmWithDebug: string) =
  let currDir = CONTRACT_WASM_PATH / deploymentAddr
  let currFile = currDir / "debug.wasm"

  createDir(currDir)
  copyFile(wasmWithDebug, currFile)

  echo "Debug executable for ", deploymentAddr, " saved at ", currFile


proc deployStylus*() =
  let deploymentAddr = doDeploy()
  let wasmWithDebug = doDebugBuild()

  saveContractDebugWasm(deploymentAddr, wasmWithDebug)
