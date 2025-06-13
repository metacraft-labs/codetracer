import std/[httpclient, json, strformat, strutils, sequtils, parseutils, times, sets, os]

const DEFAULT_NODE_URL* = "http://localhost:8547"

# TODO: get name from config? Maybe use SQLite?
const CONTRACT_WASM_PATH* = getHomeDir() / ".local" / "share" / "codetracer" / "contract-debug-wasm"
const EVM_TRACE_DIR_PATH* = getTempDir() / "codetracer"

proc jsonRpcRequest(methodParam: string, params: JsonNode): JsonNode =
  # TODO: add random/uniqie stuff to id

  let id = $now().toTime().toUnix()
  let payload = %*{
    "jsonrpc": "2.0",
    "method": methodParam,
    "params": params,
    "id": id
  }

  let client = newHttpClient()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  let response = client.request(DEFAULT_NODE_URL, httpMethod = HttpPost, body = $payload)

  # TODO: verofy id

  let parsed = parseJson(response.body)

  return parsed["result"]

proc getTransactionContractAddress*(hash: string): string =
  let response = jsonRpcRequest("eth_getTransactionByHash", %[hash])
  echo response
  return response["to"].getStr()

proc getBlockNumber(): int =
  let rpcResult = jsonRpcRequest("eth_blockNumber", %[])
  return parseHexInt(rpcResult.getStr())

proc getBlockByNumber(n: int): JsonNode =
  var num = toHex(n)
  let strippedNum = num.strip(leading = true, trailing = false, chars = {'0'})
  let hexNum = "0x" & strippedNum
  return jsonRpcRequest("eth_getBlockByNumber", %[%hexNum, %true])

proc getPermittedToHashes(): HashSet[string] =

  var toHashes: HashSet[string]
  init(toHashes)

  for file in walkDir(CONTRACT_WASM_PATH):

    if file.kind == pcDir:
      let toAddr = splitPath(file.path)[1]
      toHashes.incl(toAddr)

proc filterTransactionsByToHash(transactions: seq[JsonNode], tos: HashSet[string]): seq[JsonNode] =

  var transactions: seq[JsonNode]

  for t in transactions:
    let toAddr = t["to"].getStr()
    if tos.contains(toAddr):
      transactions.add(t)

  return transactions

proc getValidTransactions(transactions: seq[JsonNode]): seq[JsonNode] =
  let toHashes = getPermittedToHashes()
  return filterTransactionsByToHash(transactions, toHashes)

# Returns the transactions for the last `t` seconds
proc getBlocksByTimestamp(t: int): seq[JsonNode] =
  var collected: seq[JsonNode] = @[]
  var blockNum = getBlockNumber()

  # const secondsInAnHour = 3600

  let threshold = int(epochTime()) - t

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
