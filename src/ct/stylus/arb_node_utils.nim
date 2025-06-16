import std/[httpclient, json, net, strutils, parseutils, times, sets, os]

const DEFAULT_NODE_URL* = "http://localhost:8547"

# TODO: get name from config? Maybe use SQLite?
const CONTRACT_WASM_PATH* = getHomeDir() / ".local" / "share" / "codetracer" / "contract-debug-wasm"
const EVM_TRACE_DIR_PATH* = getTempDir() / "codetracer"

proc jsonRpcRequest(methodParam: string, params: JsonNode): JsonNode {.raises: [IOError, ValueError].} =
  # TODO: add random/uniqie stuff to id

  let id = $now().toTime().toUnix()
  let payload = %*{
    "jsonrpc": "2.0",
    "method": methodParam,
    "params": params,
    "id": id
  }

  var response: Response
  try:
    let client = newHttpClient()
    client.headers = newHttpHeaders({"Content-Type": "application/json"})
    response = client.request(DEFAULT_NODE_URL, httpMethod = HttpPost, body = $payload)
  except:
    raise newException(IOError, "Can't send request to node: " & getCurrentExceptionMsg())

  # TODO: verify id

  try:
    let parsed = parseJson(response.body)

    return parsed["result"]
  except:
    raise newException(ValueError, "Can't parse response JSON: " & getCurrentExceptionMsg())

proc getBlockNumber(): int {.raises: [IOError, ValueError].} =
  let rpcResult = jsonRpcRequest("eth_blockNumber", %[])
  return parseHexInt(rpcResult.getStr())

proc getBlockByNumber(n: int): JsonNode {.raises: [IOError, ValueError].} =
  var num = toHex(n)
  num = num.strip(leading = true, trailing = false, chars = {'0'})

  if num == "":
    num = "0"

  let hexNum = "0x" & num
  return jsonRpcRequest("eth_getBlockByNumber", %[%hexNum, %true])

proc getPermittedToHashes(): HashSet[string] {.raises: [].} =
  var toHashes: HashSet[string]
  init(toHashes)

  try:
    for file in walkDir(CONTRACT_WASM_PATH):
      if file.kind == pcDir:
        let toAddr = splitPath(file.path)[1]
        toHashes.incl(toAddr)
  except:
    discard

  return toHashes

proc filterTransactionsByToHash(transactions: seq[JsonNode], tos: HashSet[string]): seq[JsonNode] {.raises: [].} =
  result = @[]

  for t in transactions:
    try:
      let toAddr = t["to"].getStr()
      if tos.contains(toAddr):
        result.add(t)
    except:
      discard

  return result

proc getValidTransactions(transactions: seq[JsonNode]): seq[JsonNode] {.raises: [].} =
  let toHashes = getPermittedToHashes()
  return filterTransactionsByToHash(transactions, toHashes)

# TODO: think about exceptions
proc getTransactions(maxAge: int): seq[JsonNode] {.raises: [IOError, ValueError].} =
  var collected: seq[JsonNode] = @[]
  var blockNum = getBlockNumber()

  let threshold = int(epochTime()) - maxAge

  while blockNum >= 0:
    let transactionsBlock = getBlockByNumber(blockNum)
    let timestamp = transactionsBlock["timestamp"].getStr()

    var timestampDecimal: int
    discard parseHex(timestamp, timestampDecimal)

    if timestampDecimal < threshold:
      break

    let txs = transactionsBlock["transactions"].getElems()
    collected.add(txs)
    blockNum -= 1

  return collected

proc getTransactionContractAddress*(hash: string): string {.raises: [IOError, ValueError].} =
  try:
    let response = jsonRpcRequest("eth_getTransactionByHash", %[hash])
    return response["to"].getStr()
  except KeyError:
    raise newException(ValueError, "Inalid RPC response: " & getCurrentExceptionMsg())

# Returns the transactions, that can be replayed and are not older than `maxAge` seconds
proc getTracableTransactions*(maxAge: int = 3600): seq[JsonNode] {.raises: [IOError, ValueError].} =
  # TODO: return custom struct
  var transactions = getTransactions(maxAge)
  transactions = getValidTransactions(transactions)

  return transactions
