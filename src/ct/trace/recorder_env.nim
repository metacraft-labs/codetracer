## recorder_env — how `ct record` hands options to the MCR recorder.
##
## NORMATIVE SOURCE: `codetracer-specs/CLI/ct/record.md`, "Recorder options".
##
## An MCR recording runs `db-backend-record` -> `ct-native-replay record
## --backend mcr` -> `ct-mcr record -o <out> -- <program> <args>`.  Neither
## intermediate tool knows ct-mcr's options: `db-backend-record` files every
## argument it does not recognise as a PROGRAM argument, and `ct-native-replay`
## puts them after `--`.  So a flag `ct` appended for the recorder used to
## reach the recorded PROGRAM instead -- which is what `--use-interpose` did:
## the recorder never saw it, and the program got an unexpected `--interpose`.
##
## The environment passes through both tools unchanged, and every ct-mcr
## option has an environment twin (`CT_<NAME>`, the CLI-Parameter-Patterns
## Rule-3 parity).  So `ct` forwards recorder options ONLY through this table:
## each `ct record` option meant for the recorder names its twin here, and an
## option without one is refused by name rather than appended to anybody's
## argv.  Adding a recorder option to `ct record` means adding its row.
##
## PURE: a function of the option names, asserted by
## `src/tests/cli/recorder_env_test.nim`.

type
  RecorderForwarding* = object
    env*: seq[(string, string)]  ## set these for the recording process chain
    refusal*: seq[string]        ## non-empty: print and exit 1, record nothing

const RecorderEnvTwins* = [
  ## (the `ct record` option, the ct-mcr environment twin, its value)
  ("--portable", "CT_PORTABLE", "on"),
  ("--use-interpose", "CT_INTERPOSE", "on"),
]

proc recorderForwarding*(options: openArray[string]): RecorderForwarding =
  ## The environment that carries `options` (each a `ct record` option name,
  ## e.g. "--use-interpose") to ct-mcr, or a refusal naming any option this
  ## table has no twin for.
  for opt in options:
    var found = false
    for (name, envVar, value) in RecorderEnvTwins:
      if name == opt:
        found = true
        result.env.add((envVar, value))
    if not found:
      result.refusal.add("error: `ct record " & opt & "` has no way to " &
        "reach the MCR recorder: it has no environment twin in " &
        "src/ct/trace/recorder_env.nim, and a flag would reach the recorded " &
        "program instead of the recorder.")
