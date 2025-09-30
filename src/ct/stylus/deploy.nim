import std/[json, os, osproc, re, streams, strutils, tables]
import arb_node_utils

# NOTE: remove CatchableError if using custom exception
proc doDeploy(): string {.raises: [OSError, IOError, CatchableError, Exception].} =
  # TODO: get endpoint and private key and other params from args
  let process = startProcess(
    "cargo",
    args=[
      "stylus", "deploy",
      "--endpoint=" & DEFAULT_NODE_URL,
      "--private-key=0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659",
      "--no-verify" # Don't run in docker container
    ],
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

    echo ""
    echo line
    echo ""

    let addrStartInd = line.find("0x")
    return line[addrStartInd .. addrStartInd + 41]

  # Cool, when deployment fails, the exit code of cargo stylus deploy is 0...
  # TODO: maybe specific exception
  raise newException(CatchableError, "Stylus deployment failed!")

# NOTE: remove CatchableError if using custom exception
proc doDebugBuild(): string {.raises: [OSError, IOError, CatchableError, Exception].} =
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

# NOTE: remove CatchableError if using custom exception
proc doSignatureMap(): Table[string, string] {.raises: [OSError, IOError, CatchableError, Exception].} =
  let process = startProcess(
    "cargo",
    args=["expand", "--lib"],
    options={poEchoCmd, poUsePath, poStdErrToStdOut}
  )
  defer: process.close()

  let outStream = process.outputStream

  var output = ""

  while process.running:
    output.add(outStream.readAll())

  output.add(outStream.readAll())

  let exitCode = process.peekExitCode()

  if exitCode != 0:
    echo "Can't extract event signatures! cargo expand output:"
    echo output
    return

  let signatureRegex = re"Event with signature `(.*)` and selector `(.*)`.\n```solidity\n(.*)\n```"
  var matches = @["", "", ""]

  for eventComment in output.findAll(signatureRegex):
    discard eventComment.match(signatureRegex, matches)
    result[matches[1]] = matches[2]

proc saveContractDebugWasm(deploymentAddr: string, wasmWithDebug: string, signatureMapJson: string) {.raises: [OSError, IOError].} =
  let debugDataDir = CONTRACT_DEBUG_DATA_PATH / deploymentAddr
  let debugWasmFile = debugDataDir / "debug.wasm"
  let signatureMapFile = debugDataDir / "signature_map.json"

  createDir(debugDataDir)

  copyFile(wasmWithDebug, debugWasmFile)
  echo "Debug executable for ", deploymentAddr, " saved at ", debugWasmFile

  writeFile(signatureMapFile, signatureMapJson)
  echo "Signature map for ", deploymentAddr, " saved at ", signatureMapFile


# NOTE: remove CatchableError if using custom exception
proc deployStylus*() {.raises: [OSError, IOError, CatchableError, Exception].} =
  let wasmWithDebug = doDebugBuild()
  let signatureMapJson = $(%doSignatureMap())
  let deploymentAddr = doDeploy()

  saveContractDebugWasm(deploymentAddr, wasmWithDebug, signatureMapJson)
