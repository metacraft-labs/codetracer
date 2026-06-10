# Thank you, Lord and GOD Jesus!

import
  launch/[launch, help_delegate],
  ../frontend/viewmodel/agent_evidence,
  cli/e2e_tests,
  codetracerconf, confutils,
  version

# M4: Inline library path setup (replaces ct_wrapper.nim + ct_paths.json).
# Read CODETRACER_LD_LIBRARY_PATH and prepend to LD_LIBRARY_PATH so that
# Nix store libraries (SQLite, PCRE, etc.) are found at runtime.
when not defined(js):
  import std / os

when not defined(js) and not defined(windows):
  block:
    # IMPORTANT: ct has Linux file capabilities (cap_bpf+cap_perfmon+
    # cap_dac_read_search — applied by scripts/build-once.sh).  When a
    # binary runs in glibc's secure-execution mode (any non-empty
    # capability set qualifies), the dynamic linker strips LD_LIBRARY_PATH
    # from environ before user code sees it (see `man ld.so` →
    # "Secure-execution mode").  As a result, getEnv("LD_LIBRARY_PATH")
    # here returns the empty string even when the calling shell exported
    # it explicitly, which used to silently drop the sibling-repo
    # additions baked in by scripts/detect-siblings.sh (notably the
    # codetracer-trace-format-nim path that wazero needs to dlopen
    # libcodetracer_trace_writer.so).
    #
    # We therefore re-export LD_LIBRARY_PATH from two env vars that are
    # NOT touched by the secure-execution scrub:
    #   * CODETRACER_LD_LIBRARY_PATH — Nix-store libs (SQLite, PCRE,
    #     OpenSSL, …) that the dev shell bakes in for ct itself.
    #   * CODETRACER_RECORDER_LD_LIBRARY_PATH — extra library directories
    #     that recorder subprocesses dlopen at runtime
    #     (trace-format-nim / trace-format-rust). detect-siblings.sh
    #     populates this var precisely so the LD_LIBRARY_PATH scrub does
    #     not strand wazero & friends.
    let ctLibPath = getEnv("CODETRACER_LD_LIBRARY_PATH")
    let recorderLibPath = getEnv("CODETRACER_RECORDER_LD_LIBRARY_PATH")
    let current = getEnv("LD_LIBRARY_PATH")
    var composed = ""
    proc appendSegment(composed: var string, segment: string) =
      if segment.len == 0: return
      if composed.len == 0:
        composed = segment
      else:
        composed = composed & ":" & segment
    appendSegment(composed, ctLibPath)
    appendSegment(composed, recorderLibPath)
    appendSegment(composed, current)
    if composed.len > 0:
      putEnv("LD_LIBRARY_PATH", composed)

try:
  when not defined(js):
    let args = commandLineParams()
    if args.len > 0 and args[0] == "test":
      quit(runE2eTestCli(args[1 .. ^1]))

    # M7 / M8: the help-delegate ``ct-complete`` / ``ct-completions``
    # subcommands take *raw* arguments that may legitimately start
    # with a single or double dash (e.g. ``ct-complete shell --b`` --
    # the user is mid-typing a flag for the ``shell`` subcommand).
    # confutils would otherwise try to parse those tokens as flags
    # for ``ct`` itself and reject them with "Unrecognized option".
    # We intercept the dispatch *before* confutils sees argv so the
    # raw argument list reaches the help-delegate intact.
    if args.len > 0:
      case args[0]
      of "agent":
        let dispatch = dispatchAgentEvidenceCli(args)
        if dispatch.handled:
          echo dispatch.output
          quit(dispatch.exitCode)
      of "ct-complete":
        runCtComplete(args[1 .. ^1])
        quit(QuitSuccess)
      of "ct-completions":
        let shell = if args.len >= 2: args[1] else: ""
        runCtCompletions(shell)
        quit(QuitSuccess)
      else:
        discard

  # TODO: When confutils gets updated with nim 2 make sure to improve on the copyright banner, as newer versions
  # support having prefix and postfix banners. The banner here is only a prefix banner
  let conf = CodetracerConf.load(
    version = "CodeTracer version: " & version.CodeTracerVersionStr & (
        when defined(debug): "(debug)" else: ""),
    copyrightBanner = "CodeTracer - the user-friendly time-travelling debugger"
  )
  customValidateConfig(conf)
  runInitial(conf)
except CatchableError as ex:
  echo "Error: Unhandled exception"
  echo getStackTrace(ex)
  echo "Unhandled " & ex.msg
