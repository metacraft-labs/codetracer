## Pure URL helpers for M6 collaboration invite joins.

import std/[strutils, uri]

proc parseCollabInviteUrl*(url: string): tuple[baseUrl: string, inviteToken: string] =
  ## Parses M6 collaboration invite URLs:
  ## ``https://web.codetracer.com/collab/join/{inviteToken}``.
  let parsed = parseUri(url)
  let parts = parsed.path.strip(chars = {'/'}).split('/')
  if parsed.scheme.len == 0 or parsed.hostname.len == 0:
    raise newException(ValueError, "Invalid collaboration invite URL: " & url)
  if parts.len == 3 and parts[0] == "collab" and parts[1] == "join":
    result.baseUrl = parsed.scheme & "://" & parsed.hostname
    if parsed.port.len > 0:
      result.baseUrl &= ":" & parsed.port
    result.inviteToken = decodeUrl(parts[2])
    return
  raise newException(ValueError, "Invalid collaboration invite URL: " & url)

proc buildCollabInviteExchangePath*(baseApiUrl: string): string =
  baseApiUrl & "collab/invites/exchange"
