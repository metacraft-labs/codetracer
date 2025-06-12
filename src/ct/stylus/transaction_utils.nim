import std/[httpclient, json, strformat, strutils, sequtils, parseutils, times, sets, os]

const rpcUrl = "https://arb1.arbitrum.io/rpc"

const CONTRACT_WASM_PATH = getHomeDir() / ".local" / "share" / "codetracer" / "contract-debug-wasm"

proc jsonRpcRequest(methodParam: string, params: JsonNode): JsonNode =
  let payload = %*{
    "jsonrpc": "2.0",
    "method": methodParam,
    "params": params,
    "id": 1
  }

  let client = newHttpClient()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  let response = client.request(rpcUrl, httpMethod = HttpPost, body = $payload)
  let parsed = parseJson(response.body)

  return parsed["result"]

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