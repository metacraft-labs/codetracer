import std/[httpclient, json, os, osproc, times, streams]

# TODO: get name from config? Maybe use SQLite?
const CONTRACT_WASM_PATH = getHomeDir() / ".local" / "share" / "codetracer" / "contract-debug-wasm"
const EVM_TRACE_DIR_PATH = getTempDir() / "codetracer"

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

proc getTransactionContractAddress(hash: string): string =
  let id = $now().toTime().toUnix() & "_" & hash
  let rpcPayload = %*{
    "jsonrpc": "2.0",
    "method": "eth_getTransactionByHash",
    "params": [hash],
    "id": id
  }

  let client = newHttpClient()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  let response = client.request("http://localhost:8547", httpMethod = HttpPost, body = $rpcPayload)
  let parsed = parseJson(response.body)

  # TODO: validate response id
  let rpcResult = parsed["result"]

  return rpcResult["to"].getStr()

proc getContractWasmPath(deploymentAddr: string): string =
  return CONTRACT_WASM_PATH / deploymentAddr / "debug.wasm"

proc record*(hash: string) =
  let wasm = getContractWasmPath(hash)
  let evmTrace = getEvmTrace(hash)

  echo "WASM: ", wasm, " EVM: ", evmTrace

  # TODO: create codetrace trace

