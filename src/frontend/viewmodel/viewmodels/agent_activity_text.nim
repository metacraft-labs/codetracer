## viewmodels/agent_activity_text.nim
##
## The Agent Activity panel's words and decisions live in
## `nim_agents/activity_text` (CTF-M1: the signal-free logic of the agent
## viewmodels moved into nim-agents), re-exported here under the old import
## path. What stays is the `ct test` run card's vocabulary, because it reads
## `TestRunSummary`, which is built from CodeTracer's own `ct test` event
## contract (`ct_test/contracts`).

import nim_agents/activity_text
import test_run_summary_vm

export activity_text

# ---------------------------------------------------------------------------
# AA-2 — a `ct test` run's card
# ---------------------------------------------------------------------------

type
  TestRunState* = enum
    ## Three-valued rather than boolean: "running" is not a kind of failure,
    ## and an empty run is not a kind of success.
    trsRunning = "running"
    trsFailed = "failed"
    trsPassed = "passed"

proc testRunState*(summary: TestRunSummary): TestRunState =
  if summary.inProgress: trsRunning
  elif summary.failed > 0 or summary.errored > 0: trsFailed
  else: trsPassed

proc testRunTitle*(summary: TestRunSummary): string =
  ## What the card calls itself.
  ##
  ## The runner's own reported command when there is one, because that is the
  ## thing the reviewer actually asked for; otherwise the provider's id.  Never
  ## a reconstructed command line — a command CodeTracer invented would read as
  ## one that ran.
  if summary.commandLine.len > 0:
    summary.commandLine
  elif summary.providerId.len > 0:
    summary.providerId
  else:
    "ct test"

proc testRowDetailText*(row: TestRunRow): string =
  ## The line an expanded test shows: its status and how long it took.
  ## §2.1.2: "an individual test can be expanded to its status, duration and
  ## captured output."  A duration of zero is omitted rather than printed,
  ## for the same reason a zero count is: it is not a measurement.
  result = "Status: " & $row.outcome
  if row.durationMs > 0:
    result.add " · Duration: " & formatDurationMs(row.durationMs)

proc testRowDurationText*(row: TestRunRow): string =
  if row.durationMs > 0: formatDurationMs(row.durationMs) else: ""
