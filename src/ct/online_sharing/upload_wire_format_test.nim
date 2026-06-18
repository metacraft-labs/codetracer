## M-REC-8 wire-format flip tests for the online-sharing client.
##
## Pins the JSON body keys and URL path components that the Nim client
## sends to the trace-sharing server.  Post-M-REC-8 the canonical
## identifier on the wire is ``recordingId`` (the client-minted UUIDv7
## ``recording_id``) — *not* the pre-M-REC-8 integer ``traceId``.
## ``controlId`` and ``downloadKey`` remain server-issued access tokens
## for the uploaded copy and intentionally keep their pre-existing
## names; this test does not touch them.
##
## See ``codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.md``
## §6.7 for the wire-format change.  These tests fail at compile time
## if the request-building helpers stop accepting a ``recordingId``
## argument, and at runtime if the serialized body or path emits the
## legacy ``traceId`` key.
##
## Run with:
##   # ``-d:ssl`` is required because ``api_client.nim`` brings in
##   # ``std/net``'s ``newContext``; the test does not actually open
##   # any TLS connections.  ``CT_LD_LIBRARY_PATH`` carries the
##   # Nix-store OpenSSL .so used at runtime by ``-d:useOpenssl3``.
##   LD_LIBRARY_PATH="$CT_LD_LIBRARY_PATH:$LD_LIBRARY_PATH" \
##     nim r --hints:off --warnings:off --mm:refc -d:ssl -d:useOpenssl3 \
##       --nimcache:/tmp/ct-nim-cache/upload_wire_format_test \
##       src/ct/online_sharing/upload_wire_format_test.nim

import std / [unittest, json, strutils]

import ./api_client

const
  SampleRecordingId = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"
  SampleBaseApiUrl = "https://web.codetracer.com/api/v1/"
  SampleTenantId = "tenant-123"

suite "M-REC-8 — online-sharing client wire format":

  test "upload-url request body carries recordingId (no traceId)":
    let body = buildUploadUrlBody(
      recordingId = SampleRecordingId,
      fileName = "trace.zip",
      contentType = "application/zip",
      contentLength = 4242,
    )
    # M-REC-8 invariant: the UUIDv7 recording-id flows over the wire as
    # `recordingId`, not as the legacy integer `traceId` minted
    # server-side.
    check body.hasKey("recordingId")
    check body["recordingId"].getStr == SampleRecordingId
    check body["fileName"].getStr == "trace.zip"
    check body["contentType"].getStr == "application/zip"
    check body["contentLength"].getInt == 4242
    check not body.hasKey("traceId")
    check not body.hasKey("trace_id")

  test "upload-url request body round-trips through JSON":
    let body = buildUploadUrlBody(
      recordingId = SampleRecordingId,
      fileName = "trace.zip",
      contentType = "application/zip",
      contentLength = 1,
    )
    let serialized = $body
    # Wire form: the JSON key is exactly `recordingId`.
    check "\"recordingId\"" in serialized
    check SampleRecordingId in serialized
    check "\"traceId\"" notin serialized
    let parsed = parseJson(serialized)
    check parsed["recordingId"].getStr == SampleRecordingId

  test "upload-url path keeps the legacy tenant/traces shape":
    # The path template still uses the literal `traces/` segment — only
    # the *id* in the next segment changes namespace.  This test guards
    # the M-REC-8 invariant: only the id parameter flips, not the
    # surrounding URL grammar.
    let path = buildUploadUrlPath(SampleBaseApiUrl, SampleTenantId)
    check path ==
      "https://web.codetracer.com/api/v1/tenants/tenant-123/traces/upload-url"

  test "confirm-upload path embeds the UUIDv7 recordingId":
    let path = buildConfirmUploadPath(SampleBaseApiUrl, SampleRecordingId)
    # Path component is the bare UUIDv7 — no `trace-` prefix, no integer
    # encoding.
    check path ==
      "https://web.codetracer.com/api/v1/traces/" &
        SampleRecordingId & "/confirm-upload"
    check SampleRecordingId in path
    # Pre-M-REC-8 the path had `/traces/<int>/...`; an integer-shaped
    # segment must not appear in the post-M-REC-8 form.
    check "/traces/0/" notin path
    check "/traces/1/" notin path

  test "download-url path embeds the UUIDv7 recordingId":
    let path = buildDownloadUrlPath(SampleBaseApiUrl, SampleRecordingId)
    check path ==
      "https://web.codetracer.com/api/v1/traces/" &
        SampleRecordingId & "/download-url"
    check SampleRecordingId in path

  test "parseDownloadShareUrl extracts recordingId from the URL path":
    # Round-trip the sharing-server's download URL shape
    # (``/{orgSlug}/{recordingId}/download``) and assert the parser
    # returns the second-to-last component as ``recordingId``.  The
    # field name on the returned tuple is the M-REC-8 invariant; the
    # legacy ``traceId`` field was renamed.
    let url = "https://web.codetracer.com/acme/" &
      SampleRecordingId & "/download"
    let parsed = parseDownloadShareUrl(url)
    check parsed.orgSlug == "acme"
    check parsed.recordingId == SampleRecordingId

  test "parseDownloadShareUrl accepts URL without trailing /download":
    let url = "https://web.codetracer.com/acme/" & SampleRecordingId
    let parsed = parseDownloadShareUrl(url)
    check parsed.orgSlug == "acme"
    check parsed.recordingId == SampleRecordingId

suite "M31 — client-controlled omniscient-DB upload mode":
  ## Pins the CS-M7 ``/finalize`` body extension that lets the recorder
  ## client signal how the cluster prepares the M18 / M19 omniscient
  ## artefacts for the uploaded slice.  See
  ## ``codetracer-specs/Planned-Features/Value-Origin-Tracking.milestones.org``
  ## §M31 — the deliverable ``CLI surface: ct trace upload --omniscient-db=
  ## {off|on|lazy|pre-prepared} flag wired through to the finalize body``
  ## and the verification ``test_ct_trace_upload_cli_passes_through_
  ## omniscient_db_flag``.

  const
    SampleSessionId = "01949fcc-7d92-7e9c-bbbb-cccccccccccc"
    SamplePlatform = "linux-x86_64"

  test "finalize body omits omniscientDbMode when mode is unset (legacy round-trip)":
    # Default ``off`` matches CS-M7 legacy behaviour so pre-M31
    # recorders continue to round-trip unchanged.  We model "no
    # client preference" as an empty wire string and assert the JSON
    # key is absent in that case.
    let body = buildFinalizeBody(
      totalSlices = 3, totalEvents = 0, platform = SamplePlatform,
      omniscientDbMode = "")
    check body["totalSlices"].getInt == 3
    check body["totalEvents"].getInt == 0
    check body["platform"].getStr == SamplePlatform
    check not body.hasKey("omniscientDbMode")
    let serialized = $body
    check "\"omniscientDbMode\"" notin serialized
    # Snake-case must not leak — the wire grammar is camelCase per
    # the CS-M7 / M31 contract.
    check "\"omniscient_db_mode\"" notin serialized

  test "finalize body carries omniscientDbMode for each non-default mode":
    # Round-trip the three non-default modes that trigger server-side
    # behaviour (``on`` / ``lazy`` / ``pre-prepared``).  Each value is
    # the canonical wire spelling per spec §6.8.6.
    for wireMode in ["on", "lazy", "pre-prepared"]:
      let body = buildFinalizeBody(
        totalSlices = 5, totalEvents = 0, platform = SamplePlatform,
        omniscientDbMode = wireMode)
      check body.hasKey("omniscientDbMode")
      check body["omniscientDbMode"].getStr == wireMode
      # The standard CS-M7 fields must continue to round-trip
      # alongside the new field.
      check body["totalSlices"].getInt == 5
      check body["platform"].getStr == SamplePlatform
      let parsed = parseJson($body)
      check parsed["omniscientDbMode"].getStr == wireMode

  test "finalize body explicit off-mode round-trips through the JSON body":
    # ``off`` is the default both client-side and server-side, but if
    # the client *does* pin it explicitly (e.g. to override a
    # tenant-policy preference per the M31 cutover-dial deliverable)
    # the field must travel the wire as the literal lowercase
    # ``"off"`` token.
    let body = buildFinalizeBody(
      totalSlices = 1, totalEvents = 0, platform = SamplePlatform,
      omniscientDbMode = "off")
    check body["omniscientDbMode"].getStr == "off"

  test "finalize path keeps the CS-M7 traces/{sessionId}/finalize shape":
    # M31 only extends the body — the URL grammar is unchanged.  This
    # guards against an accidental rename of the finalize endpoint
    # while the body extension is in flight.
    let path = buildFinalizePath(SampleBaseApiUrl, SampleSessionId)
    check path ==
      "https://web.codetracer.com/api/v1/traces/" &
        SampleSessionId & "/finalize"
