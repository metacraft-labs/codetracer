import nimcrypto, zip/zipfiles, std/[ sequtils, strutils, strformat, os, httpclient, mimetypes, uri, net, json ]
from stew / byteutils import toBytes
import ../../common/[ config ]

proc generateSecurePassword*(): string =
  var key: array[32, byte]
  discard randomBytes(key)

  result = key.mapIt(it.toHex(2)).join("")
  return result

proc pkcs7Pad*(data: seq[byte], blockSize: int): seq[byte] =
  let padLen = blockSize - (data.len mod blockSize)
  result = data & repeat(cast[byte](padLen), padLen)

proc pkcs7Unpad*(data: seq[byte]): seq[byte] =
  if data.len == 0:
    raise newException(ValueError, "Data is empty, cannot unpad")

  let padLen = int64(data[^1])  # Convert last byte to int64 safely
  if padLen <= 0 or padLen > data.len:
    raise newException(ValueError, "Invalid padding")

  result = data[0 ..< data.len - padLen]


proc encryptZip(zipFile, password: string) =
  var iv: seq[byte] = password.toBytes()[0..15]

  var aes: CBC[aes256]
  aes.init(password.toOpenArrayByte(0, len(password) - 1), iv)

  var zipData = readFile(zipFile).toBytes()
  var paddedData = pkcs7Pad(zipData, 16)
  var encrypted = newSeq[byte](paddedData.len)

  aes.encrypt(paddedData, encrypted.toOpenArray(0, len(encrypted) - 1))
  writeFile(zipFile & ".enc", encrypted)

proc zipFileWithEncryption*(inputFile: string, outputZip: string, password: string) =
  var zip: ZipArchive
  if not zip.open(outputZip, fmWrite):
    raise newException(IOError, "Failed to create zip file: " & outputZip)

  for file in walkDirRec(inputFile):
    let relPath = file.relativePath(inputFile)
    zip.addFile(relPath, file)

  zip.close()
  encryptZip(outputZip, password)

proc getUploadUrl(): string =
  let config = loadConfig(folder=getCurrentDir(), inTest=false)
  var client = newHttpClient()
  var uploadUrl = ""

  try:
    uploadUrl = client.getContent(fmt"{parseUri(config.baseUrl) / config.getUploadUrlApi}")
  except CatchableError as e:
    echo fmt"error: can't retrieve upload URL: {e.msg}"
    uploadUrl = ""

  client.close()
  return uploadUrl

proc uploadEncryptedZip*(file: string): (string, int) =
  let getUrlResponse = getUploadUrl()

  if getUrlResponse == "":
    echo "error: Failed to get upload URL"
    return ("", 1)

  let uploadUrl = parseJson(getUrlResponse)["UploadUrl"].getStr().strip()
  let config = loadConfig(folder=getCurrentDir(), inTest=false)
  let mimes = newMimetypes()

  var exitCode = 0
  var response = ""
  var client = newHttpClient()
  var data = newMultipartData()

  data.addFiles({"file": file & ".enc"}, mimeDb = mimes)

  try:
    discard client.putContent(uploadUrl, multipart=data)
    exitCode = 0
  except CatchableError as e:
    echo fmt"error: can't upload to API: {e.msg}"
    response = ""
    exitCode = 1
  finally:
    client.close()
  
  (getUrlResponse, exitCode)

export toBytes
