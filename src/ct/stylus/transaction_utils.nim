import httpclient, json, strformat, strutils, sequtils, parseutils, times

const rpcUrl = "https://arb1.arbitrum.io/rpc"

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