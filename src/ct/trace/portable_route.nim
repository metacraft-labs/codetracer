## portable_route — what `ct record --portable` does for the backend the
## dispatcher selected.
##
## NORMATIVE SOURCE: `codetracer-specs/CLI/ct/record.md`, "Portable traces"
## (owner-decided 2026-09-30).  `--portable` asks for a trace that replays
## away from the recording host, or later on it after its files have changed.
## It is a dispatcher-owned option (hence `CODETRACER_PORTABLE`), forwarded to
## whichever backend records, each implementing it with its own mechanism; a
## backend that does not implement it yet REFUSES it by name, because an
## ordinary trace would look portable to the user and fail on the other
## machine.
##
## Implemented today by the MCR backend.  It is forwarded as ct-mcr's own
## environment twin, `CT_PORTABLE=on`, rather than as a flag: the MCR
## recording runs `db-backend-record` -> `ct-native-replay record --backend
## mcr` -> `ct-mcr record -o <out> -- <program> <args>`, and a flag appended
## by `ct` travels behind the program to the recorded program itself, while
## the environment reaches `ct-mcr` intact (`CT_PORTABLE` is `--portable`'s
## CLI-Parameter-Patterns Rule-3 twin).
##
## PURE: a function of the selection and the options, so every row is asserted
## by `src/tests/cli/record_portable_test.nim` without a recording.

import std/strutils
import recorder_env

type
  PortableRoute* = object
    wanted*: bool            ## the recording must be portable
    implied*: string         ## the option that implied it, "" when asked for
    env*: seq[(string, string)]
      ## environment to set for the recording process chain
    refusal*: seq[string]    ## non-empty: print and exit 1, record nothing

const
  PortableEnvVar* = "CODETRACER_PORTABLE"
  McrPortableEnvVar* = "CT_PORTABLE"

proc parseOnOff(v: string): tuple[ok: bool, on: bool] =
  case v.strip().toLowerAscii()
  of "on", "1", "true", "yes": (true, true)
  of "off", "0", "false", "no": (true, false)
  else: (false, false)

proc portableRoute*(viaDispatchTable: bool, recorderLabel: string,
                    nativeBackend: string, portableFlag: bool,
                    envValue: string, upload: bool): PortableRoute =
  ## `viaDispatchTable`: the target is recorded by a dedicated (source-level)
  ## recorder, named `recorderLabel`; otherwise by the native backend
  ## `nativeBackend` (`mcr`, `rr`, `ttd`).  `envValue` is
  ## `CODETRACER_PORTABLE` as found ("" when unset).
  result = PortableRoute()
  var explicitOff = false
  if envValue.strip().len > 0:
    let (ok, on) = parseOnOff(envValue)
    if not ok:
      result.refusal.add("error: " & PortableEnvVar & " must be 'on' or " &
        "'off', got '" & envValue & "'")
      return
    if on: result.wanted = true
    else: explicitOff = true
  if portableFlag:
    # `--portable` on the command line outranks the environment (CLI wins).
    result.wanted = true
    explicitOff = false

  # `--upload` ships the trace to another machine, where a non-portable trace
  # can only be refused: it implies `--portable` (CLI/ct/record.md).  Applied
  # where a backend implements `--portable` -- the MCR backend; for the others
  # the implication would refuse every upload they make today, which is the
  # owner's call to make, not this dispatcher's.
  let mcr = not viaDispatchTable and nativeBackend == "mcr"
  if upload and mcr and not result.wanted:
    if explicitOff:
      result.refusal.add("error: " & PortableEnvVar & "=" & envValue.strip() &
        " contradicts --upload, which ships the trace to another machine " &
        "and so requires a portable trace (--upload implies --portable); " &
        "drop one of the two")
      return
    result.wanted = true
    result.implied = "--upload"

  if not result.wanted:
    return
  if viaDispatchTable:
    # Deliberately says nothing about HOW the recorder stores sources: some
    # source-level recorders already copy them next to the trace, others do
    # not, and none has been checked against what `--portable` promises.
    result.refusal.add("error: --portable is not implemented for " &
      recorderLabel & " recordings yet, so `ct` cannot promise that the " &
      "trace replays on another machine.")
    result.refusal.add("help: record without --portable; see \"Portable " &
      "traces\" in the `ct record` reference.")
    return
  if not mcr:
    result.refusal.add("error: --portable is not implemented for the '" &
      nativeBackend & "' backend yet" &
      (if nativeBackend == "rr": ": the trace is not packed with the files " &
         "it mapped (the `rr pack` mechanism)" else: "") &
      ", so it could not be replayed on another machine.")
    result.refusal.add("help: record with --backend=mcr, which implements " &
      "--portable, or record without it.")
    return
  result.env.add(recorderForwarding(["--portable"]).env)
