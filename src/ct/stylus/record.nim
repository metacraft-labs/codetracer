import std/[os, osproc, streams]
import arb_node_utils
import ../../common/[paths, trace_index, types]
import ../trace/record

# NOTE: remove CatchableError if using custom exception
proc getEvmTrace(hash: string): string {.raises: [OSError, IOError, CatchableError, Exception].} =
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

proc getContractWasmPath(deploymentAddr: string): string {.raises: [].} =
  return CONTRACT_WASM_PATH / deploymentAddr / "debug.wasm"

# NOTE: remove CatchableError if using custom exception
proc recordStylus*(hash: string): Trace {.raises: [IOError, ValueError, OSError, CatchableError, Exception].} =
  let wasm = getContractWasmPath(getTransactionContractAddress(hash))
  let evmTrace = getEvmTrace(hash)

  echo "WASM with debug info: ", wasm, " EVM trace: ", evmTrace

  result = record("", ".", "", "", evmTrace, wasm, @[])
  updateField(result.id, "program", hash, false)
  result.program = hash

# NOTE: remove CatchableError if using custom exception
proc replayStylus*(hash: string) {.raises: [IOError, ValueError, OSError, CatchableError, Exception].} =
  # TODO: don't rerecord transactions
  let recordedTrace = recordStylus(hash)

  let process = startProcess(codetracerExe, args = @["replay", "--id=" & $recordedTrace.id], options = {poParentStreams})
  discard process.waitForExit()
