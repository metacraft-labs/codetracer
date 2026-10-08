## OAuth browser-based authentication flow.
##
## Replaces the C# ``AuthenticateModule``. The flow:
## 1. Start a TCP listener on localhost (ephemeral port).
## 2. Open the user's browser to the CI platform's auth page, passing the
##    callback port as a query parameter.
## 3. After the user authenticates, the CI platform redirects the browser
##    to ``http://127.0.0.1:{port}/?desktop-cli-token={token}``.
## 4. Extract the token from the HTTP GET request.
## 5. Save it to the remote config file.
## 6. Send a 302 redirect back to the CI platform's success page.
##
## Constants match ``AuthConstants.cs`` in the CI platform codebase:
## - ``DesktopPortQuery``  = ``"desktop-port"``
## - ``DesktopTokenQuery`` = ``"desktop-cli-token"``

import std/[browsers, net, os, strformat, strutils, uri]
import remote_config

const
  DesktopPortQuery = "desktop-port"
  DesktopTokenQuery = "desktop-cli-token"
  AuthDesktopPath = "/auth/desktop"
  AuthDesktopResultPath = "/auth/desktop/result"
  MaxHeaderBytes = 8192

proc extractQueryParam(httpRequest: string, paramName: string): string =
  ## Parses the first line of an HTTP request (``GET /?key=val&... HTTP/1.1``)
  ## and extracts the named query parameter value.
  let firstLine = httpRequest.split({'\r', '\n'})[0]
  # Expected format: "GET /?param1=val1&param2=val2 HTTP/1.1"
  let parts = firstLine.split(' ')
  if parts.len < 2:
    return ""
  let path = parts[1]
  let qPos = path.find('?')
  if qPos < 0:
    return ""
  let query = path[qPos + 1 .. ^1]
  for segment in query.split('&'):
    let eqPos = segment.find('=')
    if eqPos > 0:
      let key = segment[0 ..< eqPos]
      if key.cmpIgnoreCase(paramName) == 0:
        return decodeUrl(segment[eqPos + 1 .. ^1])
  return ""

proc authDesktopUrlFor*(baseRemoteAddress: string, port: int): string =
  ## The sign-in page `ct login` opens: ``{base}/auth/desktop?desktop-port=N``.
  let base = baseRemoteAddress.strip().strip(leading = false, chars = {'/'})
  fmt"{base}{AuthDesktopPath}?{DesktopPortQuery}={port}"

proc authenticate*(remoteConfig: RemoteConfig, baseRemoteAddress: string) =
  ## Runs the full browser-based OAuth flow.
  ## Blocks until the browser callback is received or the user cancels.
  let server = newSocket()
  defer: server.close()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()

  let port = server.getLocalAddr()[1].int

  # Build the auth URL that the browser will navigate to.
  let authUrl = authDesktopUrlFor(baseRemoteAddress, port)

  echo "Opening browser for authentication..."
  echo "If the browser does not open, navigate to:"
  echo "  " & authUrl

  try:
    openDefaultBrowser(authUrl)
  except CatchableError:
    # Non-fatal: the user can manually open the URL.
    discard

  # Wait for the browser callback.
  var client: Socket
  new(client)
  server.accept(client)
  defer: client.close()

  var headerBuf = newString(MaxHeaderBytes)
  let bytesRead = client.recv(headerBuf, MaxHeaderBytes)
  if bytesRead <= 0:
    raise newException(IOError, "No data received from browser callback.")
  headerBuf.setLen(bytesRead)

  # Extract the bearer token from the query string.
  let token = extractQueryParam(headerBuf, DesktopTokenQuery)
  if token.len == 0:
    # Send error redirect.
    let errorRedirect = fmt"{baseRemoteAddress}{AuthDesktopResultPath}?status=error"
    let errorResponse = fmt"HTTP/1.1 302 Found\r\nLocation: {errorRedirect}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    client.send(errorResponse)
    raise newException(ValueError,
      "Authentication failed: no token received in browser callback.")

  # Save the token to config.
  remoteConfig.saveConfigValue(BearerTokenKey, token)

  # Send success redirect back to the browser.
  let successRedirect = fmt"{baseRemoteAddress}{AuthDesktopResultPath}?status=success"
  let successResponse = fmt"HTTP/1.1 302 Found\r\nLocation: {successRedirect}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  client.send(successResponse)

  echo "Authentication successful. Token saved."
