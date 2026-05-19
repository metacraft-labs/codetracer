## M-REC-6 launcher env-var guard.
##
## ``CODETRACER_RECORDING_ID`` (UUIDv7 recording-id) is the only
## supported entry point for telling the launcher which recording to
## open.  The previous name ``CODETRACER_TRACE_ID`` is intentionally
## *not* aliased so callers that still set it surface as a hard error
## instead of being silently ignored.
##
## The guard lives in its own module so the launch path and the
## ``launch_env_var_test`` regression test can both call the same
## source-of-truth proc — no inline mirror, no drift.

import std/os

const LegacyRecordingIdEnvVar* = "CODETRACER_TRACE_ID"
  ## Retired in favour of ``CODETRACER_RECORDING_ID`` (M-REC-6).

const CurrentRecordingIdEnvVar* = "CODETRACER_RECORDING_ID"
  ## UUIDv7 recording-id string consumed by the Electron index process
  ## in ``src/frontend/index/args.nim``.

const LegacyRecordingIdEnvVarMessage* =
  "error: " & LegacyRecordingIdEnvVar & " is retired in favour of " &
  CurrentRecordingIdEnvVar & " (UUIDv7 recording-id).  " &
  "Remove the legacy variable from the environment."
  ## Single-source error string — both the production launcher and the
  ## regression test assert on this exact text.

proc refuseLegacyRecordingIdEnv*(
    emit: proc (msg: string) {.closure.} = nil) =
  ## Fail loudly if the legacy ``CODETRACER_TRACE_ID`` env var is set.
  ##
  ## On Linux/macOS this proc is invoked from ``runInitial`` in
  ## ``launch.nim`` before any subcommand dispatch so the misconfigured
  ## environment is detected as early as possible.
  ##
  ## ``emit`` is the sink for the error message.  The production
  ## launcher passes the ``errorMessage`` template (which writes to
  ## stdout via ``echo``); the regression test passes a closure that
  ## captures the message for assertions.  When ``emit`` is ``nil``
  ## the message is written to ``stderr`` so a stray ``import`` from
  ## any test harness still surfaces a diagnostic.
  if getEnv(LegacyRecordingIdEnvVar, "").len > 0:
    if emit != nil:
      emit(LegacyRecordingIdEnvVarMessage)
    else:
      stderr.writeLine(LegacyRecordingIdEnvVarMessage)
    quit(1)
