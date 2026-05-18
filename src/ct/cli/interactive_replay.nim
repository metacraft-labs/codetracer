import
  std/[strutils, strformat, sequtils, algorithm, rdstdin],
  ../../common/[ trace_index, types, lang, recording_id ],
  ../launch/cleanup,
  ../utilities/env,
  ../codetracerconf,
  json_serialization

const
  TRACE_CMD_COLUMN_WIDTH = 70
  TRACE_WORKDIR_COLUMN_WIDTH = 40

func limitColumnLeft(text: string, width: int): string =
  if text.len > width:
    ".." & text[text.len - (width - 2) .. ^1]
  else:
    text


func limitColumnRight(text: string, width: int): string =
  if text.len > width:
    text[0 .. (width - 2) - 1] & ".."
  else:
    text


const
  TRACE_ID_SHORT_WIDTH = 12
    ## How many leading hex chars of the UUIDv7 we print in ``ct list``.
    ## ``MIN_RECORDING_ID_PREFIX_LEN`` (8) is the minimum the resolver
    ## accepts, but 12 chars gives users room to disambiguate same-ms
    ## bursts without copying the full 36-char form.

func shortRecordingId*(recordingId: string): string =
  ## Render a recording-id for human-readable list output.  Returns the
  ## first ``TRACE_ID_SHORT_WIDTH`` characters followed by an ellipsis so
  ## the displayed value is visually distinct from a "real" copy-paste
  ## value but is still long enough to be re-typed as a short prefix.
  if recordingId.len <= TRACE_ID_SHORT_WIDTH:
    return recordingId
  recordingId[0 ..< TRACE_ID_SHORT_WIDTH] & ".."

func traceInText*(trace: Trace): string =
  let displayCmd = limitColumnRight(trace.program & " " & trace.args.join(" "), TRACE_CMD_COLUMN_WIDTH)
  let displayWorkdir = limitColumnLeft("ran in " & trace.workdir, TRACE_WORKDIR_COLUMN_WIDTH)
  # M-REC-6: the id column shows the short prefix form.  We append the
  # full UUIDv7 at the end of the line so users can copy-paste it without
  # squeezing every column.
  let idColumn = shortRecordingId(trace.recordingId)
  alignLeft(idColumn, TRACE_ID_SHORT_WIDTH + 2) & " | " &
  alignLeft(displayCmd, TRACE_CMD_COLUMN_WIDTH) & " | " &
  alignLeft(displayWorkdir, TRACE_WORKDIR_COLUMN_WIDTH) & " | " &
  alignLeft(toName(trace.lang), 15) & " | " & alignLeft(trace.date, 15) & " | " &
  trace.recordingId


func tracesInText*(traces: seq[Trace]): string =
  traces.reversed.mapIt(traceInText(it)).join("\n")


func tracesInJson*(traces: seq[Trace]): string =
  Json.encode(traces)


proc interactiveTraceSelectMenu*(command: StartupCommand): Trace =
  let recordCore = envLoadRecordCore()
  let action = if command == StartupCommand.upload: "upload" else: "replay"
  # ordered by id
  # returns the newest(biggest id) first
  let traces = trace_index.all(test=false)
  let limitedTraces = if traces.len > 10:
      traces[0 ..< 10]
    else:
      traces

  echo &"Select a trace to {action}, entering its UUIDv7 id (full or 8+ char short prefix):"
  echo ""

  for trace in limitedTraces:
    echo traceInText(trace)

  if traces.len > 10:
    echo "..(older traces not shown)"

  echo ""

  while true:
    var raw: string = ""
    try:
      raw = readLineFromStdin(&"{action}: ")
    except:
      echo "Interrupt detected. Exiting!"
      cleanup()
      quit(0)

    try:
      # M-REC-6: accept the canonical 36-char UUIDv7 or an 8+ hex-char
      # short prefix.  Ambiguous prefixes print the candidate list and
      # re-prompt rather than exiting (consistent with the surrounding
      # try/retry loop).
      let recordingIdInput = raw.strip
      if recording_id.isCanonicalUuidV7(recordingIdInput):
        let trace = trace_index.find(recordingIdInput, test = false)
        if not trace.isNil:
          return trace
        echo fmt"trace with id {recordingIdInput} not found, please try again"
        continue
      let res = trace_index.findByRecordingIdPrefix(recordingIdInput, test = false)
      if res.isOk:
        return res.trace
      case res.error
      of trace_index.rieTooShort:
        echo fmt"recording-id prefix '{recordingIdInput}' is too short; need at least " &
          $trace_index.MIN_RECORDING_ID_PREFIX_LEN & " hex chars; please try again"
      of trace_index.rieNotFound:
        echo fmt"no recording matches prefix '{recordingIdInput}', please try again"
      of trace_index.rieAmbiguous:
        echo fmt"ambiguous prefix '{recordingIdInput}' matches " &
          $res.matches.len & " recordings:"
        for m in res.matches:
          echo "  " & m
        echo "please try again with a longer prefix"
    except CatchableError:
      echo "error: ", getCurrentExceptionMsg()
      echo "please try again"
