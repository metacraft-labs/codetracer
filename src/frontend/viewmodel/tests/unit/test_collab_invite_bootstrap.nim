## M6 invite URL and join-bootstrap tests.
##
##   nim c -r src/frontend/viewmodel/tests/unit/test_collab_invite_bootstrap.nim

import std/[json, strutils, unittest]

import ../../collab/[codec, invite_bootstrap, join_session, session_core, types]

suite "collaborative ViewModel M6 invite bootstrap":

  test "test_collab_invite_dialog_creates_join_url":
    var invite = createInviteDialogResult(cgpDriver, "ct_invite_test_token")

    check invite.preset == cgpDriver
    check invite.joinUrl == "https://web.codetracer.com/collab/join/ct_invite_test_token"
    check "mutateSharedViewState" in invite.grants
    check "controlDebugger" in invite.grants
    check not invite.revoked

    invite.revokeInvite()
    check invite.revoked

  test "integration_collab_native_load_trace_url_joins_invite":
    let bootstrap = resolveNativeInviteLoadTraceUrl(
      "https://web.codetracer.com/collab/join/native-token-1",
      proc(inviteToken: string): CollabJoinBootstrap =
        check inviteToken == "native-token-1"
        CollabJoinBootstrap(
          replayId: "replay-1",
          traceId: "trace-1",
          traceIdentity: "trace-identity-1",
          roomId: "room-1",
          initialGrants: @["observe", "publishAwareness"],
          webUiUrl: buildCollabJoinUrl(inviteToken),
          nativeJoinUrl: buildCollabJoinUrl(inviteToken),
          rendezvousUrl: "https://web.codetracer.com/api/v1/collab/rooms/room-1/rendezvous",
          transportHints: @[
            "control-plane-only",
            "control-plane-rendezvous",
            "browser-channel",
            "viewops-not-accepted"],
        ))

    check bootstrap.roomId == "room-1"
    check bootstrap.nativeJoinUrl == "https://web.codetracer.com/collab/join/native-token-1"
    check "viewops-not-accepted" in bootstrap.transportHints

  test "test_collab_webui_invite_bootstrap_parses_join_document":
    let invite = createInviteDialogResult(cgpViewer, "browser-b-token")
    let token = parseCollabInviteToken(invite.joinUrl)
    let bootstrapJson = %*{
      "replayId": "replay-browser-a",
      "traceId": "trace-browser-a",
      "traceIdentity": "trace-browser-a",
      "roomId": "room-browser-a",
      "initialGrants": ["observe", "publishAwareness"],
      "webUiUrl": invite.joinUrl,
      "nativeJoinUrl": invite.joinUrl,
      "rendezvousUrl": "https://web.codetracer.com/api/v1/collab/rooms/room-browser-a/rendezvous",
      "transportHints": ["control-plane-only", "control-plane-rendezvous", "browser-channel", "viewops-not-accepted"],
    }
    let bootstrap = parseJoinBootstrap($bootstrapJson)

    check token == "browser-b-token"
    check bootstrap.roomId == "room-browser-a"
    check bootstrap.webUiUrl == invite.joinUrl
    check bootstrap.initialGrants == @["observe", "publishAwareness"]

  test "test_collab_late_join_bootstrap_marks_snapshot_and_tail_required":
    let bootstrapJson = %*{
      "replayId": "replay-late",
      "traceId": "trace-late",
      "traceIdentity": "trace-late",
      "roomId": "room-late",
      "principalId": "local-user",
      "initialGrants": ["observe", "publishAwareness", "mutateSharedViewState"],
      "webUiUrl": "https://web.codetracer.com/collab/join/late-token",
      "nativeJoinUrl": "https://web.codetracer.com/collab/join/late-token",
      "rendezvousUrl": "https://web.codetracer.com/api/v1/collab/rooms/room-late/rendezvous",
      "transportHints": ["snapshot-required", "tail-required", "viewops-not-accepted"],
    }
    let bootstrap = parseJoinBootstrap($bootstrapJson)

    check "snapshot-required" in bootstrap.transportHints
    check "tail-required" in bootstrap.transportHints
    check "viewops-not-accepted" in bootstrap.transportHints

  test "test_collab_viewer_invite_observes_but_cannot_drive":
    let invite = createInviteDialogResult(cgpViewer, "viewer-token")

    check "observe" in invite.grants
    check "publishAwareness" in invite.grants
    check "controlDebugger" notin invite.grants
    check "mutateSharedViewState" notin invite.grants

  test "test_collab_invite_flow_bootstrap_marks_ci_control_plane_only":
    let bootstrapJson = %*{
      "replayId": "replay-no-ci-viewops",
      "traceId": "trace-no-ci-viewops",
      "traceIdentity": "trace-no-ci-viewops",
      "roomId": "room-no-ci-viewops",
      "initialGrants": ["observe"],
      "webUiUrl": "https://web.codetracer.com/collab/join/no-ci-viewops-token",
      "nativeJoinUrl": "https://web.codetracer.com/collab/join/no-ci-viewops-token",
      "rendezvousUrl": "https://web.codetracer.com/api/v1/collab/rooms/room-no-ci-viewops/rendezvous",
      "transportHints": ["control-plane-only", "control-plane-rendezvous", "browser-channel", "viewops-not-accepted"],
    }
    let bootstrap = parseJoinBootstrap($bootstrapJson)

    check "control-plane-only" in bootstrap.transportHints
    check "control-plane-rendezvous" in bootstrap.transportHints
    check "browser-channel" in bootstrap.transportHints
    check "viewops-not-accepted" in bootstrap.transportHints
    for hint in bootstrap.transportHints:
      check not hint.toLowerAscii.contains("p2p")
    check bootstrap.rendezvousUrl.contains("/collab/rooms/")

  test "test_collab_join_session_installs_snapshot_tail_and_viewer_policy":
    let core = createCollaborativeSessionCore(
      sessionId = "local-before-join",
      traceIdentity = "local-trace",
      localPrincipalId = "local-user",
      localActorId = "actor-web-b",
      localReplicaId = "replica-web-b",
      backendOwnerId = "local-user")
    let snapshot = initSharedSessionDocument(
      sessionId = "room-late",
      traceIdentity = "trace-late",
      authorityPrincipalId = "ci-control-plane",
      backendOwnerId = "ci-control-plane").snapshot
    let bootstrap = %*{
      "replayId": "replay-late",
      "traceId": "trace-late",
      "traceIdentity": "trace-late",
      "roomId": "room-late",
      "principalId": "local-user",
      "initialGrants": ["observe", "publishAwareness", "mutateSharedViewState"],
      "webUiUrl": "https://web.codetracer.com/collab/join/late-token",
      "nativeJoinUrl": "https://web.codetracer.com/collab/join/late-token",
      "rendezvousUrl": "https://web.codetracer.com/api/v1/collab/rooms/room-late/rendezvous",
      "transportHints": ["control-plane-only", "control-plane-rendezvous", "browser-channel", "viewops-not-accepted"],
      "snapshot": snapshot.toJson,
      "tail": [
        {
          "protocolVersion": 1,
          "sessionId": "room-late",
          "principalId": "local-user",
          "actorId": "actor-web-b",
          "replicaId": "replica-web-b",
          "actorSeq": 1,
          "opId": "actor-web-b:1",
          "lamport": 1,
          "capabilityIds": [],
          "targetPath": "statePane.selectedPath",
          "kind": "vokSetRegister",
          "payload": {"value": "locals.answer"}
        }
      ],
    }

    let activation = core.startCollabJoinSession(bootstrap)

    check activation.activated
    check activation.snapshotInstalled
    check activation.tailApplied == 1
    check activation.tailRejected == 0
    check activation.transportStarted
    check not activation.acceptsViewOpsThroughCi
    check not activation.canDrive
    check core.collaborationEnabled
    check core.peerTransportStarted
    check core.document.state.sessionId == "room-late"
    check core.document.state.statePane.selectedPath.value == "locals.answer"
