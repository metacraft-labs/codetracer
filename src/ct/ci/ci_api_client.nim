## CI-specific API methods for the CodeTracer Monolith backend.
##
## Wraps the existing ``ApiClient`` from ``api_client.nim`` with
## higher-level procedures that target the ``/api/v1/ci/`` endpoint group.
## Authentication uses a CI API token (``ci:write`` scope) passed via the
## ``Authorization: Bearer <token>`` header.
##
## Endpoint reference (from the Monolith CI controller):
## - POST ``/api/v1/ci/runs``                    -- create a new run
## - POST ``/api/v1/ci/runs/{runId}/start``      -- mark run as Running
## - POST ``/api/v1/ci/runs/{runId}/complete``    -- mark run as Completed
## - POST ``/api/v1/ci/runs/{runId}/cancel``      -- mark run as Cancelled
## - POST ``/api/v1/ci/runs/{runId}/logs``        -- append a log chunk
## - GET  ``/api/v1/ci/runs/{runId}``            -- get run details/status
## - POST ``/api/v1/ci/runs/{runId}/traces``      -- upload trace metadata

import std/[httpclient, json, net, strformat, os, times]
import ../online_sharing/api_client

type
  CreateRunRequest* = object
    ## Payload for POST /api/v1/ci/runs.
    repositoryUrl*: string
    commitSha*: string
    branchName*: string
    baseCommitSha*: string
    label*: string
    processMonitoring*: bool

  CreateRunResponse* = object
    ## Response from POST /api/v1/ci/runs.
    id*: string
    tenantId*: string
    sequenceNumber*: int

  CIRunStatus* = object
    ## Response from GET /api/v1/ci/runs/{runId}.
    id*: string
    status*: string
    label*: string
    repositoryUrl*: string
    commitSha*: string
    branchName*: string
    createdAt*: string

  LogLine* = object
    ## A single log line for the log-append endpoint.
    timestamp*: string
    stream*: string
    text*: string

  # -- Process monitoring event types (M9) -----------------------------------
  # These DTOs mirror the ``CIProcessEventBatch`` and related records in the
  # Monolith's ``CIRunProcessService.cs``.

  ProcessStartEvent* = object
    ## A process exec event assembled from BPFTrace EXEC sub-events.
    pid*: int
    parentPid*: int
    binaryPath*: string
    commandLine*: string
    workingDirectory*: string
    environmentId*: string
    startedAt*: string  # ISO 8601

  ProcessExitEvent* = object
    ## A process exit event from BPFTrace.
    pid*: int
    exitCode*: int
    exitedAt*: string  # ISO 8601
    # Cumulative resource totals (carried for informational purposes;
    # the backend only stores pid, exitCode, exitedAt).
    maxMemoryBytes*: int64
    totalNetRecvBytes*: int64
    totalNetSendBytes*: int64
    totalDiskReadBytes*: int64
    totalDiskWriteBytes*: int64
    cpuTimeNs*: int64

  ProcessMetricsEvent* = object
    ## A periodic resource usage snapshot from BPFTrace INTV events.
    pid*: int
    timestamp*: string  # ISO 8601
    cpuPercent*: float
    memoryBytes*: int64
    diskReadBytes*: int64
    diskWriteBytes*: int64
    netSendBytes*: int64
    netRecvBytes*: int64

  ProcessEnvironment* = object
    ## Content-addressed snapshot of a process's environment variables.
    id*: string  # SHA-256 hex digest of sorted env vars
    variables*: seq[tuple[key: string, value: string]]

  CIApiError* = object of CatchableError
    ## Raised when a CI API call fails after all retries.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

const
  MaxRetries = 3
  InitialBackoffMs = 1000
  MaxBackoffMs = 30_000

proc ciHeaders(token: string): HttpHeaders =
  newHttpHeaders({
    "Authorization": "Bearer " & token,
    "Content-Type": "application/json",
  })

proc ensureCISuccess(response: Response, context: string) =
  ## Raises ``CIApiError`` if the response status is not 2xx.
  let code = response.code.int
  if code < 200 or code >= 300:
    let body = response.body
    raise newException(CIApiError,
      fmt"CI API error: {response.status}" &
      (if body.len > 0: " -- " & body else: "") &
      " (during " & context & ")")

template withRetry(retryContext: string, body: untyped) =
  ## Executes ``body`` with exponential backoff retries on network failure.
  ## CIApiError (non-2xx responses) are NOT retried since they indicate
  ## a problem with the request itself.
  var backoffMs = InitialBackoffMs
  for attempt in 0 .. MaxRetries:
    try:
      body
      break
    except CIApiError:
      raise
    except CatchableError as e:
      if attempt == MaxRetries:
        raise newException(CIApiError,
          "CI API call failed after " & $(MaxRetries + 1) &
          " attempts (" & retryContext & "): " & e.msg)
      let sleepMs = min(backoffMs, MaxBackoffMs)
      sleep(sleepMs)
      backoffMs = backoffMs * 2

# ---------------------------------------------------------------------------
# CI Run lifecycle
# ---------------------------------------------------------------------------

proc createRun*(client: ApiClient, token: string,
                req: CreateRunRequest): CreateRunResponse =
  ## POST /api/v1/ci/runs -- create a new CI run.
  withRetry("createRun"):
    let url = client.baseApiUrl & "ci/runs"
    let reqBody = $ %*{
      "repositoryUrl": req.repositoryUrl,
      "commitSha": req.commitSha,
      "branchName": req.branchName,
      "baseCommitSha": req.baseCommitSha,
      "label": req.label,
      "processMonitoring": req.processMonitoring,
    }
    let response = client.httpClient.request(
      url, httpMethod = HttpPost, headers = ciHeaders(token), body = reqBody)
    ensureCISuccess(response, "createRun")
    let j = parseJson(response.body)
    result = CreateRunResponse(
      id: j["id"].getStr(),
      tenantId: j["tenantId"].getStr(),
      sequenceNumber: j{"sequenceNumber"}.getInt(0),
    )

proc startRun*(client: ApiClient, token: string, runId: string) =
  ## POST /api/v1/ci/runs/{runId}/start -- transition run to Running.
  withRetry("startRun"):
    let url = client.baseApiUrl & fmt"ci/runs/{runId}/start"
    let response = client.httpClient.request(
      url, httpMethod = HttpPost, headers = ciHeaders(token), body = "{}")
    ensureCISuccess(response, "startRun")

proc completeRun*(client: ApiClient, token: string, runId: string,
                  status: string, exitCode: int,
                  durationSeconds: float) =
  ## POST /api/v1/ci/runs/{runId}/complete -- mark run as completed.
  withRetry("completeRun"):
    let url = client.baseApiUrl & fmt"ci/runs/{runId}/complete"
    let reqBody = $ %*{
      "status": status,
      "exitCode": exitCode,
      "durationSeconds": durationSeconds,
    }
    let response = client.httpClient.request(
      url, httpMethod = HttpPost, headers = ciHeaders(token), body = reqBody)
    ensureCISuccess(response, "completeRun")

proc cancelRun*(client: ApiClient, token: string, runId: string) =
  ## POST /api/v1/ci/runs/{runId}/cancel -- request run cancellation.
  withRetry("cancelRun"):
    let url = client.baseApiUrl & fmt"ci/runs/{runId}/cancel"
    let response = client.httpClient.request(
      url, httpMethod = HttpPost, headers = ciHeaders(token), body = "{}")
    ensureCISuccess(response, "cancelRun")

proc appendLogs*(client: ApiClient, token: string, runId: string,
                 lines: seq[LogLine], sequence: int,
                 isFinal: bool) =
  ## POST /api/v1/ci/runs/{runId}/logs -- append a chunk of log lines.
  withRetry("appendLogs"):
    let url = client.baseApiUrl & fmt"ci/runs/{runId}/logs"
    var jsonLines = newJArray()
    for line in lines:
      jsonLines.add(%*{
        "timestamp": line.timestamp,
        "stream": line.stream,
        "text": line.text,
      })
    let reqBody = $ %*{
      "lines": jsonLines,
      "sequence": sequence,
      "isFinal": isFinal,
    }
    let response = client.httpClient.request(
      url, httpMethod = HttpPost, headers = ciHeaders(token), body = reqBody)
    ensureCISuccess(response, "appendLogs")

proc getRunStatus*(client: ApiClient, token: string,
                   runId: string): CIRunStatus =
  ## GET /api/v1/ci/runs/{runId} -- retrieve run details.
  withRetry("getRunStatus"):
    let url = client.baseApiUrl & fmt"ci/runs/{runId}"
    let response = client.httpClient.request(
      url, httpMethod = HttpGet, headers = ciHeaders(token))
    ensureCISuccess(response, "getRunStatus")
    let j = parseJson(response.body)
    result = CIRunStatus(
      id: j["id"].getStr(),
      status: j["status"].getStr(),
      label: j{"label"}.getStr(""),
      repositoryUrl: j{"repositoryUrl"}.getStr(""),
      commitSha: j{"commitSha"}.getStr(""),
      branchName: j{"branchName"}.getStr(""),
      createdAt: j{"createdAt"}.getStr(""),
    )

proc reportProcessEvents*(client: ApiClient, token: string, runId: string,
    starts: seq[ProcessStartEvent],
    exits: seq[ProcessExitEvent],
    metrics: seq[ProcessMetricsEvent],
    environments: seq[ProcessEnvironment]) =
  ## POST /api/v1/ci/runs/{runId}/processes -- report a batch of process events.
  ##
  ## Maps the Nim event types to the ``CIProcessEventBatch`` DTO expected by
  ## the Monolith backend (see ``CIRunProcessService.cs``).
  withRetry("reportProcessEvents"):
    let url = client.baseApiUrl & fmt"ci/runs/{runId}/processes"

    var jsonStarts = newJArray()
    for s in starts:
      jsonStarts.add(%*{
        "pid": s.pid,
        "parentPid": s.parentPid,
        "binaryPath": s.binaryPath,
        "commandLine": s.commandLine,
        "workingDirectory": s.workingDirectory,
        "environmentId": s.environmentId,
        "startedAt": s.startedAt,
      })

    var jsonExits = newJArray()
    for e in exits:
      jsonExits.add(%*{
        "pid": e.pid,
        "exitCode": e.exitCode,
        "exitedAt": e.exitedAt,
      })

    var jsonMetrics = newJArray()
    for m in metrics:
      jsonMetrics.add(%*{
        "pid": m.pid,
        "timestamp": m.timestamp,
        "cpuPercent": m.cpuPercent,
        "memoryBytes": m.memoryBytes,
        "diskReadBytes": m.diskReadBytes,
        "diskWriteBytes": m.diskWriteBytes,
        "netSendBytes": m.netSendBytes,
        "netRecvBytes": m.netRecvBytes,
      })

    var jsonEnvs = newJArray()
    for env in environments:
      var varsObj = newJObject()
      for kv in env.variables:
        varsObj[kv.key] = newJString(kv.value)
      jsonEnvs.add(%*{
        "id": env.id,
        "variables": varsObj,
      })

    let reqBody = $ %*{
      "starts": jsonStarts,
      "exits": jsonExits,
      "metrics": jsonMetrics,
      "environments": jsonEnvs,
    }
    let response = client.httpClient.request(
      url, httpMethod = HttpPost, headers = ciHeaders(token), body = reqBody)
    ensureCISuccess(response, "reportProcessEvents")

proc uploadTraceMetadata*(client: ApiClient, token: string, runId: string,
                          recordingId: string,
                          fileName: string, sizeBytes: int64, s3Key: string,
                          contentHash: string,
                          pid: int = 0): string =
  ## POST /api/v1/ci/runs/{runId}/traces -- register trace metadata.
  ## Returns the canonical ``recordingId`` (UUIDv7) the server stored
  ## for this trace.
  ##
  ## M-REC-8: the client-minted UUIDv7 ``recordingId`` is now passed in
  ## the request body so the server records it as the canonical
  ## identity (rather than minting a fresh server-side integer).  The
  ## response echoes back the same value.
  withRetry("uploadTraceMetadata"):
    let url = client.baseApiUrl & fmt"ci/runs/{runId}/traces"
    let reqBody = $ %*{
      "recordingId": recordingId,
      "fileName": fileName,
      "sizeBytes": sizeBytes,
      "s3Key": s3Key,
      "contentHash": contentHash,
      "pid": pid,
    }
    let response = client.httpClient.request(
      url, httpMethod = HttpPost, headers = ciHeaders(token), body = reqBody)
    ensureCISuccess(response, "uploadTraceMetadata")
    let j = parseJson(response.body)
    result = j["recordingId"].getStr()
