## record_portable_test.nim
##
## `ct record --portable`, asserted as a table — codetracer-specs
## `CLI/ct/record.md`, "Portable traces" (owner-decided 2026-09-30).
##
## ## What it pins
##
## `--portable` asks for a trace that replays on another machine, or later on
## this one after its files change.  The dispatcher forwards it to the backend
## it selects, and a backend that does not implement it refuses it BY NAME:
## an ordinary trace would look portable to the user and then fail on the
## other machine.  The MCR backend implements it, and receives it as ct-mcr's
## environment twin `CT_PORTABLE=on` -- the only spelling that survives the
## `db-backend-record` -> `ct-native-replay` -> `ct-mcr record -o <out> --
## <program> <args>` chain, where a flag would land behind the program and be
## handed to the recorded program instead of the recorder.
##
## `--upload` ships the trace elsewhere, so it implies `--portable` where a
## backend implements it; `CODETRACER_PORTABLE=off` together with it is a
## refusal naming both.  Where a backend does not implement it yet, the upload
## goes ahead with a named warning (owner, 2026-10-01).
##
## The other half -- that ct-mcr honours `CT_PORTABLE=on` by bundling every
## mapped file -- is asserted by codetracer-native-recorder's
## `ct_cli/tests/test_record_portable_linux.nim`.
##
## Mocking justification (workspace policy on mock objects): none. The
## production decision function is called directly; its inputs are values.
##
## Compile and run:
##   nim c -r src/tests/cli/record_portable_test.nim

import std/[strutils, unittest]
import ../../ct/trace/portable_route

proc route(dispatch = false, label = "Python", backend = "mcr",
           flag = false, env = "", upload = false): PortableRoute =
  portableRoute(dispatch, label, backend, flag, env, upload)

suite "ct record --portable":
  test "absent: nothing is forwarded and nothing is refused":
    for backend in ["mcr", "rr", "ttd"]:
      let r = route(backend = backend)
      check not r.wanted
      check r.env.len == 0
      check r.refusal.len == 0
    let d = route(dispatch = true)
    check not d.wanted and d.env.len == 0 and d.refusal.len == 0

  test "MCR: the flag reaches ct-mcr as CT_PORTABLE=on":
    let r = route(flag = true)
    check r.wanted
    check r.implied == ""
    check r.env == @[("CT_PORTABLE", "on")]
    check r.refusal.len == 0

  test "MCR: CODETRACER_PORTABLE is the flag's environment twin":
    for v in ["on", "1", "true", "yes", "ON"]:
      let r = route(env = v)
      check r.wanted
      check r.env == @[("CT_PORTABLE", "on")]
    for v in ["off", "0", "false", "no"]:
      let r = route(env = v)
      check not r.wanted
      check r.env.len == 0
    let bad = route(env = "maybe")
    check bad.refusal.len == 1
    check "CODETRACER_PORTABLE must be 'on' or 'off'" in bad.refusal[0]

  test "the command line outranks the environment":
    let r = route(flag = true, env = "off")
    check r.wanted
    check r.env == @[("CT_PORTABLE", "on")]

  test "MCR: --upload implies --portable, and says so":
    let r = route(upload = true)
    check r.wanted
    check r.implied == "--upload"
    check r.env == @[("CT_PORTABLE", "on")]

  test "MCR: CODETRACER_PORTABLE=off with --upload is refused naming both":
    let r = route(upload = true, env = "off")
    check r.refusal.len == 1
    check "CODETRACER_PORTABLE=off contradicts --upload" in r.refusal[0]
    check r.env.len == 0

  test "ttd refuses --portable by name":
    let r = route(backend = "ttd", flag = true)
    check r.refusal.len >= 1
    check "'ttd' backend" in r.refusal[0]
    check "not implemented" in r.refusal[0]
    check r.env.len == 0

  test "rr: --portable is accepted, and an upload is strict":
    # Every rr recording is packed by ct-native-replay (`rr pack`), so
    # --portable needs nothing forwarded and is never refused.
    let r = route(backend = "rr", flag = true)
    check r.wanted and r.refusal.len == 0 and r.env.len == 0
    let u = route(backend = "rr", upload = true)
    check u.wanted and u.implied == "--upload" and u.warning.len == 0
    let off = route(backend = "rr", upload = true, env = "off")
    check off.refusal.len == 1
    check "contradicts --upload" in off.refusal[0]

  test "a source-level recorder refuses --portable by name":
    let r = route(dispatch = true, label = "Python", flag = true)
    check r.refusal.len >= 1
    check "not implemented for Python recordings" in r.refusal[0]
    check r.env.len == 0

  test "--upload where --portable is not implemented: uploads, with a named warning":
    # Owner, 2026-10-01: "warn now, implement per backend".  Not refused, not
    # silent: the warning names the backend and says what it means.
    block:
      let r = route(backend = "ttd", upload = true)
      check r.refusal.len == 0
      check not r.wanted
      check r.env.len == 0
      check r.warning.len == 1
      check "'ttd' backend" in r.warning[0]
      check "replays only where" in r.warning[0]
    let d = route(dispatch = true, label = "Ruby", upload = true)
    check d.refusal.len == 0 and d.warning.len == 1
    check "Ruby recordings" in d.warning[0]
    # MCR implements it: strict, and no warning.
    check route(upload = true).warning.len == 0
    # Without an upload nothing is warned about.
    check route(backend = "ttd").warning.len == 0
    # Asked for explicitly, --portable stays strict where it is not implemented.
    check route(backend = "ttd", flag = true, upload = true).refusal.len >= 1
