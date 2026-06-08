# omniscient-db-size / nim / io_heavy
import os, strformat, strutils

let scratch = getTempDir() / "ct-bench-io-" & $getCurrentProcessId()
createDir(scratch)
var sizes: seq[int] = @[]
for i in 0 ..< 64:
  let path = scratch / fmt"chunk_{i:02}.bin"
  let payload = "abcdefgh".repeat(i + 1)
  writeFile(path, payload)
  sizes.add(readFile(path).len)
removeDir(scratch)
var total = 0
for s in sizes:
  total += s
echo total
