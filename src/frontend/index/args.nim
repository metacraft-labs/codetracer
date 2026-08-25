import
  std / [ jsffi, sequtils, strutils ],
  electron_vars, config, review_dataset,
  ../types,
  ../lib/[ jslib, electron_lib ],
  ../../common/ct_logging

proc reviewSessionUnlink*(path: cstring)
    {.importjs: "try { require('fs').unlinkSync(#); } catch (_) {}".}
  ## Remove the resolved-session handoff file `ct` wrote for this window,
  ## after it has been read into memory (RV-6).  Swallowing the error is the
  ## point: the file is a courtesy copy with no remaining reader, and a
  ## read-only temp directory must not turn into a failed review.

# <traceId>
# --port <port>
# --frontend-socket-port <frontend-socket-port>
# --frontend-socket-parameters <frontend-socket-parameters>
# --backend-socket-port <backend-socket-port>
# --caller-pid <callerPid>
# # eventually if needed --backend-socket-host <backend-socket-host>
proc parseArgs* =
  data.startOptions.screen = true
  data.startOptions.loading = false
  data.startOptions.record = false
  data.startOptions.stylusExplorer = electronProcess.env[cstring"CODETRACER_LAUNCH_MODE"] == cstring"arb.explorer"

  data.startOptions.folder = electronprocess.cwd()

  # Check CODETRACER_TEST for all launch modes (trace, deepreview, welcome, edit, etc.)
  # so that test-mode behaviour (e.g. skipping the install dialog) is always available.
  if electronProcess.env.hasKey(cstring"CODETRACER_TEST") and
      electronProcess.env[cstring"CODETRACER_TEST"] == cstring"1":
    data.startOptions.inTest = true

  # M-REC-6: legacy ``CODETRACER_TRACE_ID`` is retired.  The Electron
  # index process refuses to start if the legacy variable is still set,
  # so a stale caller surfaces immediately instead of silently being
  # ignored.  ``CODETRACER_RECORDING_ID`` is the new name; payload is a
  # UUIDv7 recording-id string.
  if electronProcess.env.hasKey(cstring"CODETRACER_TRACE_ID"):
    errorPrint(
      "args: CODETRACER_TRACE_ID is retired; use CODETRACER_RECORDING_ID " &
      "(UUIDv7 recording-id)")
    quit(1)
  if electronProcess.env.hasKey(cstring"CODETRACER_RECORDING_ID"):
    # Store the UUIDv7 recording-id read from the env var into
    # ``startOptions.recordingID``.  The launcher in
    # ``src/ct/launch/launch.nim`` sets this variable when forwarding a
    # subprocess-spawned Electron instance to a specific recording.
    data.startOptions.recordingID = electronProcess.env[cstring"CODETRACER_RECORDING_ID"]
    callerProcessPid = electronProcess.env[cstring"CODETRACER_CALLER_PID"].parseJsInt
    return
  else:
    discard

  if electronProcess.env.hasKey(cstring"CODETRACER_TEST_STRATEGY"):
    data.startOptions.rawTestStrategy = electronProcess.env[cstring"CODETRACER_TEST_STRATEGY"]
    infoPrint "RAW TEST STRATEGY:", data.startOptions.rawTestStrategy

  # Filter out flags injected by Electron/Playwright that are not
  # CodeTracer arguments (--no-sandbox, --inspect, --remote-debugging-port,
  # --remote-debugging-pipe, etc.).
  proc isDebuggerFlag(arg: cstring): bool =
    let s = $arg
    s == "--no-sandbox" or
      s.startsWith("--inspect") or
      s.startsWith("--remote-debugging")

  let argsExceptNoSandbox = electronProcess.argv.filterIt(not isDebuggerFlag(it))

  # TODO electron or just node? server code compatibility
  if argsExceptNoSandbox.len > 2:
    var args = argsExceptNoSandbox[2 .. ^1]
    var i = 0
    while i < args.len:
      let arg = args[i]
      if arg == cstring"--bypass":
        data.startOptions.screen = false
        data.startOptions.loading = true
      elif arg == cstring"--test":
        data.startOptions.screen = false
        data.startOptions.inTest = true
      elif arg == cstring"--diff":
        if i + 1 < args.len:
          data.startOptions.diff = cast[Diff](JSON.parse(fs.readFileSync(args[i + 1], cstring"utf8")))
          data.startOptions.withDiff = true
          i += 2
          continue
        else:
          errorPrint "expected --diff <structuredDiffJson>"
          break
      elif arg == cstring"--diff-index":
        if i + 1 < args.len:
          data.startOptions.rawDiffIndex = fs.readFileSync(args[i + 1], cstring"utf-8")
          i += 2
          continue
        else:
          errorPrint "expected --diff-index <indexDiffJson>"
          break
      elif arg == cstring"--deepreview":
        # Load a DeepReview JSON export file for offline review mode.
        # The JSON structure matches the DeepReviewData type produced
        # by ct-native-replay's json_export module.
        #
        # The read itself lives in `index/review_dataset.nim` because AA-3
        # performs the *same* read later, for a dataset an evidence tool call
        # in the session feed names.  One reader means the launch path and the
        # feed path cannot come to disagree about what a dataset is or where
        # `review.json` lives inside a collected directory.
        if i + 1 < args.len:
          let read = readReviewDatasetFile(args[i + 1])
          if not read.ok:
            # Previously an unreadable dataset threw out of `parseArgs` and
            # killed the main process with a stack trace naming neither the
            # file nor the problem.  `ct review` already refuses a path that
            # does not exist, so reaching here means the file is corrupt —
            # which is worth saying out loud before failing.
            errorPrint "could not read the review dataset at ",
              args[i + 1], ": ", read.message
            break
          data.startOptions.deepReview = read.data
          data.startOptions.withDeepReview = true
          # M-REC-2: empty UUIDv7 string means "no recording".  Was ``-1`` pre-M-REC-2.
          data.startOptions.recordingID = cstring""
          i += 2
          continue
        else:
          errorPrint "expected --deepreview <deepreviewJson>"
          break
      elif arg == cstring"--review-session":
        # RV-6: the agent session the review's dataset referenced, already
        # resolved by `ct` (see `src/ct/review_session.nim` for why the
        # resolution happens there and not here — reaching an ACP agent needs
        # a stdio child process, which `nim-acp` cannot spawn on this, the
        # JavaScript, backend).
        #
        # The document always carries an explicit `state`, so a failed
        # resolution arrives as a failure rather than as an empty
        # conversation.  Like `--deepreview`, this is an internal ct ->
        # Electron argument, not a user-facing flag.
        if i + 1 < args.len:
          data.startOptions.reviewSession = cast[DeepReviewSessionTranscript](
            JSON.parse(fs.readFileSync(args[i + 1], cstring"utf8")))
          # Read once, then unlinked.  This file is the *only* place a
          # review's conversation content is ever written to disk, and the
          # whole point of storing a reference rather than a transcript
          # (DeepReview-GUI.md §2.1) is that conversation content does not
          # accumulate in files that outlive the thing showing them.  It is
          # already in memory by this line, so the copy on disk has no
          # remaining reader.  Best-effort: failing to remove it must not stop
          # the review opening.
          reviewSessionUnlink(args[i + 1])
          i += 2
          continue
        else:
          errorPrint "expected --review-session <resolvedSessionJson>"
          break
      elif arg == cstring"--no-record":
        data.startOptions.record = false
      elif arg == cstring"--welcome-screen":
        data.startOptions.welcomeScreen = true
        # M-REC-2: empty UUIDv7 string means "no recording".  Was ``-1`` pre-M-REC-2.
        data.startOptions.recordingID = cstring""
      elif arg == cstring"edit":
        data.startOptions.edit = true
        if i + 1 >= args.len:
          errorPrint "expected edit <path>"
          break
        let rawEditPath = args[i + 1]
        let nameStr = $rawEditPath
        # Check for absolute path: Unix (/) or Windows drive letter (e.g. D:\)
        let isAbsolute = nameStr.len > 0 and (nameStr[0] == '/' or
          (nameStr.len >= 3 and nameStr[1] == ':' and (nameStr[2] == '\\' or nameStr[2] == '/')))
        let absoluteEditPath =
          if isAbsolute:
            rawEditPath
          else:
            nodePath.join(electronprocess.cwd(), rawEditPath)
        let file = fs.lstatSync(absoluteEditPath)
        var folder = cstring""
        if cast[bool](file.isFile()):
          data.startOptions.name = absoluteEditPath
          folder = nodePath.dirname(absoluteEditPath) & cstring"/"
        else:
          data.startOptions.name = cstring""
          folder = absoluteEditPath
        if folder[folder.len - 1] != '/' and folder[folder.len - 1] != '\\':
          folder = folder & cstring"/"
        data.startOptions.folder = folder
        break
      elif arg == cstring"--shell-ui":
        data.startOptions.shellUi = true
        data.startOptions.folder = electronprocess.cwd()
        # M-REC-2: empty UUIDv7 string means "no recording".  Was ``-1`` pre-M-REC-2.
        data.startOptions.recordingID = cstring""
        break
      elif arg == cstring"--port":
        if i + 1 < args.len:
          data.startOptions.port = args[i + 1].parseJsInt
          i += 2
          continue
        else:
          errorPrint "expected --port <port>"
          break
      elif arg == cstring"--frontend-socket-port":
        if i + 1 < args.len:
          data.startOptions.frontendSocket.port = args[i + 1].parseJsInt
          i += 2
          continue
        else:
          errorPrint "expected --frontend-socket-port <frontend-socket-port>"
          break
      elif arg == cstring"--frontend-socket-parameters":
        if i + 1 < args.len:
          data.startOptions.frontendSocket.parameters = args[i + 1]
          i += 2
          continue
        else:
          errorPrint "expected --frontend-socket-parameters <frontend-socket-parameters>"
          break
      elif arg == cstring"--backend-socket-port":
        if i + 1 < args.len:
          data.startOptions.backendSocket.port = args[i + 1].parseJsInt
          i += 2
          continue
        else:
          errorPrint "expected --backend-socket-port <backend-socket-port>"
          break
      elif arg == cstring"--idle-timeout-ms":
        if i + 1 < args.len:
          data.startOptions.idleTimeoutMs = args[i + 1].parseJsInt
          i += 2
          continue
        else:
          errorPrint "expected --idle-timeout-ms <milliseconds>"
          break
      elif arg == cstring"--caller-pid":
        if i + 1 < args.len:
          callerProcessPid = args[i + 1].parseJsInt
          i += 2
          continue
        else:
          errorPrint "expected --caller-pid <caller-pid>"
          break
      elif arg.len == 36 and ($arg)[14] == '7' and ($arg)[8] == '-':
        # M-REC-2: positional argument that looks like a canonical
        # UUIDv7 (36 chars, version nibble '7' at position 14, hyphen
        # at position 8) is treated as the recording-id.  Pre-M-REC-2
        # this used ``!arg.isNaN`` to gate on integer-looking args.
        # Loose check; the database lookup is the source of truth.
        data.startOptions.screen = false
        data.startOptions.loading = true
        data.startOptions.record = false
        data.startOptions.recordingID = arg
        data.startOptions.folder = electronprocess.cwd()
      else:
        discard
      i += 1
  else:
    # M-REC-2: empty UUIDv7 string means "no recording".
    data.startOptions.recordingID = cstring""
    data.startOptions.welcomeScreen = true
    data.startOptions.folder = electronprocess.cwd()
