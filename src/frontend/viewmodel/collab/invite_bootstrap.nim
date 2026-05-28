## Invite URL and join-bootstrap helpers for collaborative ViewModel sessions.
##
## M6 keeps CI as a control plane only: these helpers model invite URLs,
## selected capability presets, and bootstrap documents without opening a
## ViewOp data path.

import std/[json, strutils, uri]

type
  CollabGrantPreset* = enum
    cgpViewer,
    cgpDriver,
    cgpHost

  CollabInviteDialogResult* = object
    preset*: CollabGrantPreset
    inviteToken*: string
    joinUrl*: string
    grants*: seq[string]
    revoked*: bool

  CollabJoinBootstrap* = object
    replayId*: string
    traceId*: string
    traceIdentity*: string
    roomId*: string
    initialGrants*: seq[string]
    webUiUrl*: string
    nativeJoinUrl*: string
    rendezvousUrl*: string
    transportHints*: seq[string]

  CollabInviteExchange* = proc(inviteToken: string): CollabJoinBootstrap

const CanonicalCollabWebBaseUrl* = "https://web.codetracer.com"

proc presetName*(preset: CollabGrantPreset): string =
  case preset
  of cgpViewer: "Viewer"
  of cgpDriver: "Driver"
  of cgpHost: "Host"

proc parseGrantPreset*(value: string): CollabGrantPreset =
  case value.strip.toLowerAscii
  of "viewer", "":
    cgpViewer
  of "driver":
    cgpDriver
  of "host":
    cgpHost
  else:
    raise newException(ValueError, "unknown collaboration invite preset: " & value)

proc presetGrants*(preset: CollabGrantPreset): seq[string] =
  case preset
  of cgpViewer:
    @["observe", "publishAwareness"]
  of cgpDriver:
    @[
      "observe",
      "publishAwareness",
      "mutateSharedViewState",
      "controlDebugger",
      "manageBreakpoints",
      "manageWatches",
      "manageLayout",
    ]
  of cgpHost:
    @[
      "observe",
      "publishAwareness",
      "mutateSharedViewState",
      "controlDebugger",
      "manageBreakpoints",
      "manageWatches",
      "manageLayout",
      "grantCapabilities",
      "invite",
      "exportSession",
      "hostBackend",
    ]

proc buildCollabJoinUrl*(inviteToken: string;
                         baseUrl = CanonicalCollabWebBaseUrl): string =
  let trimmed = baseUrl.strip(chars = {'/'})
  trimmed & "/collab/join/" & encodeUrl(inviteToken)

proc createInviteDialogResult*(preset: CollabGrantPreset;
                               inviteToken: string;
                               baseUrl = CanonicalCollabWebBaseUrl):
                               CollabInviteDialogResult =
  if inviteToken.len == 0:
    raise newException(ValueError, "invite token is required")
  CollabInviteDialogResult(
    preset: preset,
    inviteToken: inviteToken,
    joinUrl: buildCollabJoinUrl(inviteToken, baseUrl),
    grants: preset.presetGrants,
    revoked: false,
  )

proc revokeInvite*(invite: var CollabInviteDialogResult) =
  invite.revoked = true

proc parseCollabInviteToken*(joinUrl: string): string =
  let parsed = parseUri(joinUrl)
  let parts = parsed.path.strip(chars = {'/'}).split('/')
  if parts.len == 3 and parts[0] == "collab" and parts[1] == "join":
    return decodeUrl(parts[2])
  raise newException(ValueError, "not a CodeTracer collaboration invite URL")

proc isCollabInviteUrl*(joinUrl: string): bool =
  try:
    discard parseCollabInviteToken(joinUrl)
    true
  except ValueError:
    false

proc stringSeq(node: JsonNode): seq[string] =
  if node.isNil or node.kind != JArray:
    return @[]
  for item in node:
    result.add item.getStr

proc parseJoinBootstrap*(raw: string): CollabJoinBootstrap =
  let node = parseJson(raw)
  CollabJoinBootstrap(
    replayId: node{"replayId"}.getStr,
    traceId: node{"traceId"}.getStr,
    traceIdentity: node{"traceIdentity"}.getStr,
    roomId: node{"roomId"}.getStr,
    initialGrants: stringSeq(node{"initialGrants"}),
    webUiUrl: node{"webUiUrl"}.getStr,
    nativeJoinUrl: node{"nativeJoinUrl"}.getStr,
    rendezvousUrl: node{"rendezvousUrl"}.getStr,
    transportHints: stringSeq(node{"transportHints"}),
  )

proc resolveNativeInviteLoadTraceUrl*(loadTraceUrl: string;
                                      exchange: CollabInviteExchange):
                                      CollabJoinBootstrap =
  ## Resolve a standalone-client "load trace URL" when the URL is an M6
  ## collaboration invite. Normal trace download URLs should continue through
  ## the legacy download path and are rejected here.
  let token = parseCollabInviteToken(loadTraceUrl)
  exchange(token)
