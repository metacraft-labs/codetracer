import std/[ os ]
import arb_node_utils
import ../../common/[ trace_index, types ]
import ../trace/record

proc getContractWasmPath(deploymentAddr: string): string {.raises: [].} =
  return CONTRACT_WASM_PATH / deploymentAddr / "debug.wasm"

# NOTE: remove CatchableError if using custom exception
proc recordStylus*(hash: string): Trace {.raises: [IOError, ValueError, OSError, CatchableError, Exception].} =
  let wasm = getContractWasmPath(getTransactionContractAddress(hash))

  echo "WASM with debug info: ", wasm, " tx hash: ", hash

  result = record("", ".", "", hash, "", "", wasm, @[])
  updateField(result.id, "program", hash, false)
  result.program = hash

# NOTE: remove CatchableError if using custom exception
proc replayStylus*(hash: string) {.raises: [IOError, ValueError, OSError, CatchableError, Exception].} =
  # TODO: don't rerecord transactions
  let recordedTrace = recordStylus(hash)
  # for now it prints `traceId:<traceId>` which is read by index(from ct arb explorer) which starts the replay in its instance
  #   for example
  #   traceId:479  
