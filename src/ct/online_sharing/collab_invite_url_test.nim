## M6 standalone-client collaboration invite URL tests.
##
##   nim c -r src/ct/online_sharing/collab_invite_url_test.nim

import std/[json, unittest]

import collab_invite_url, collab_native_session
import ../../frontend/viewmodel/collab/reducer

suite "online sharing collaboration invite URLs":

  test "collab invite URL parser returns exchange base and token":
    let parsed = parseCollabInviteUrl(
      "https://web.codetracer.com/collab/join/native-token")

    check parsed.baseUrl == "https://web.codetracer.com"
    check parsed.inviteToken == "native-token"
    check buildCollabInviteExchangePath("https://web.codetracer.com/api/v1/") ==
      "https://web.codetracer.com/api/v1/collab/invites/exchange"

  test "native load-trace invite starts active collaboration runtime":
    let runtime = startNativeCollabRuntime(NativeCollabBootstrap(
      replayId: "replay-native",
      traceId: "trace-native",
      traceIdentity: "trace-native",
      roomId: "room-native",
      initialGrants: @["observe", "publishAwareness", "mutateSharedViewState"],
      webUiUrl: "https://web.codetracer.com/collab/join/native-token",
      nativeJoinUrl: "https://web.codetracer.com/collab/join/native-token",
      rendezvousUrl: "https://web.codetracer.com/api/v1/collab/rooms/room-native/rendezvous",
      transportHints: @[
        "control-plane-only",
        "control-plane-rendezvous",
        "browser-channel",
        "viewops-not-accepted"]))
    let session = runtime.activeSession
    let registered = registeredNativeCollabRuntime("room-native")

    check runtime.isActive
    check not registered.isNil
    check registered.activeSession.roomId == runtime.activeSession.roomId
    check registeredNativeCollabRuntimeCount() >= 1
    check session.entered
    check session.roomId == "room-native"
    check "observe" in session.initialGrants
    check "mutateSharedViewState" in session.initialGrants
    check "viewops-not-accepted" in session.transportHints
    check runtime.transport.active
    check runtime.transport.kind == "control-plane-rendezvous"
    check not runtime.transport.acceptsViewOps
    check session.transportStarted
    check not session.acceptsViewOpsThroughCi
    check session.toJson["kind"].getStr == "nativeCollabSession"
    check runtime.sessionCore.collaborationEnabled
    check runtime.sessionCore.peerTransportStarted
    check runtime.observeNativeCollabState["sessionId"].getStr == "room-native"

    let result = runtime.setNativeSelectedPath("locals.native")
    check result.status == asApplied
    let state = runtime.observeNativeCollabState()
    check state["selectedPath"].getStr == "locals.native"
    check state["localOperationCount"].getInt == 1
