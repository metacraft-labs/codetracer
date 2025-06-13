import std/[httpclient, json, os, osproc, times, streams]
import arb_node_utils
import ../../common/[paths, types]
import ../trace/record

proc getEvmTrace(hash: string): string =
  # TODO: get endpoint and private key and other params from args
  let process = startProcess(
    "cargo",
    args=["stylus", "trace", "--use-native-tracer", "--tx", hash],
    options={poEchoCmd, poUsePath, poStdErrToStdOut}
  )
  defer: process.close()

  let outStream = process.outputStream

  var output = ""

  while process.running:
    output.add(outStream.readAll())

  let exitCode = process.peekExitCode()

  if exitCode != 0:
    echo "Can't get EVM trace! Output:"
    echo output
    # TODO: maybe specific exception
    raise newException(CatchableError, "Can't get EVM trace!")

  # TODO: maybe validate output?

  let outputDir = EVM_TRACE_DIR_PATH / hash
  let outputFile = outputDir / "evm_trace.json"

  createDir(outputDir)
  writeFile(outputFile, output)

  return outputFile

proc getContractWasmPath(deploymentAddr: string): string =
  return CONTRACT_WASM_PATH / deploymentAddr / "debug.wasm"

proc recordStylus*(hash: string): Trace =
  let wasm = getContractWasmPath(getTransactionContractAddress(hash))
  let evmTrace = getEvmTrace(hash)

  echo "WASM: ", wasm, " EVM: ", evmTrace

  return record("", ".", "", "", evmTrace, wasm, @[])

proc replayStylus*(hash: string) =
  # TODO: don't rerecord transactions
  let recordedTrace = recordStylus(hash)

  let process = startProcess(codetracerExe, args = @["replay", "--id=" & $recordedTrace.id], options = {poParentStreams})
  discard process.waitForExit()
