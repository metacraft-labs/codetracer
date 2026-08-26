## File transfer via presigned S3 URLs.
##
## Replaces the C# ``MonolithFileTransferClient``. Handles PUT upload
## (with ETag extraction) and GET download to disk.

import std/[httpclient, net, os, strutils]

proc putBytes*(url: string, fileData: string): string =
  ## Uploads ``fileData`` to the presigned ``url`` via HTTP PUT.
  ## Returns the ETag header value from the response (needed for upload
  ## confirmation). Raises on HTTP error or missing ETag.
  ##
  ## AS-3 replaced the previous path-taking ``putFile`` with this.  A protected
  ## part's bytes are the *sealed* bytes, which exist only in memory: writing
  ## them to a temporary file so that a path-taking PUT could read them back
  ## would put ciphertext — and, for the moment it takes to write it, a file
  ## whose deletion has to be got right — somewhere neither the caller nor the
  ## reader asked for.  ``artifact_store.partBytesToSend`` reads the file, so a
  ## second procedure that also read files would have been a caller-less
  ## alternative spelling of the same request.
  ##
  ## The C# implementation uses ``StreamContent`` with explicit Content-Length.
  ## We hold the body in memory; see ``Artifact-Store.md`` §8 defect 7 for why
  ## streaming is still open and why the bound is one *part*.
  let fileSize = fileData.len

  let client = newHttpClient(
    sslContext = newContext(verifyMode = CVerifyPeer))
  defer: client.close()

  client.headers = newHttpHeaders({
    "Content-Type": "application/octet-stream",
    "Content-Length": $fileSize,
  })

  let response = client.request(url, httpMethod = HttpPut, body = fileData)
  let code = response.code.int
  if code < 200 or code >= 300:
    raise newException(IOError,
      "Upload failed with status " & response.status)

  # Extract ETag from response headers. The C# code tries both the typed
  # ETag property and raw header lookup.
  result = response.headers.getOrDefault("ETag")
  if result.len == 0:
    result = response.headers.getOrDefault("etag")
  # Strip surrounding quotes if present (S3 returns quoted ETags).
  result = result.strip(chars = {'"'})
  if result.len == 0:
    raise newException(IOError,
      "Upload succeeded but no ETag was returned in response headers.")

proc downloadToFile*(url: string, filePath: string) =
  ## Downloads the file at presigned ``url`` and saves it to ``filePath``.
  ## Creates parent directories if needed.
  let dir = parentDir(filePath)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)

  let client = newHttpClient(
    sslContext = newContext(verifyMode = CVerifyPeer))
  defer: client.close()

  # Nim's httpclient.downloadFile streams directly to disk.
  client.downloadFile(url, filePath)
