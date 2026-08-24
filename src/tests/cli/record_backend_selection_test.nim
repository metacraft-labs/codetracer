## record_backend_selection_test.nim
##
## `ct record --backend <value>`, asserted as a table — milestone **NTR-2**,
## decision **Q6**, of
## `codetracer-specs/Planned-Features/Native-Target-Recognition.md`.
##
## ## What was broken
##
## `nativeRecordingBackendForHost` coerced anything it did not like to `mcr`.
## `--backend rr` on macOS, `--backend ttd` on Linux and `--backend typo`
## anywhere all produced an MCR recording, with no diagnostic and a zero exit —
## a script that asked for an rr recording got an MCR one and had no way to
## find out.  `codetracer-specs/CLI/ct-mcr/record.md` has required the opposite
## since before this initiative existed: *"refuse to start when the requested
## configuration cannot be honored, rather than silently downgrading"*.
##
## **This is a breaking change and is meant to be one.**  An invocation that
## succeeded before now fails, because it was succeeding at the wrong thing.
##
## ## Why the table is over HOSTS
##
## The old rule was `when defined(macosx) / elif defined(windows) / elif
## defined(linux)`, so two thirds of it could never be exercised by any one CI
## machine — which is a large part of why the coercion survived.  The rule is
## now a pure function of `(requested, host)`, so every row of every host is
## asserted from whichever host happens to run this file, and the compile-time
## host is applied in exactly one place.
##
## ## The `--backend mcr` pin has its own assertions
##
## Q6 records that refusing an unhonourable value is *what makes `--backend
## mcr` meaningful*: once nothing is coerced, `mcr` is a **pin** rather than a
## coincidence of the default.  A pin that is only ever checked by "it equals
## the default" is not tested at all, so the pin is asserted separately, and
## the milestone requires a mutation flipping the default to leave the pin
## green and the default assertion red.  `defaultNativeRecordingBackend` exists
## as its own function so that mutation is a one-line, honest one.
##
## Mocking justification (workspace policy on mock objects): none. There is no
## mock in this file. It calls the production selection function directly; the
## host is a parameter of that function rather than a thing to be faked.
##
## Compile and run:
##   nim c -r src/tests/cli/record_backend_selection_test.nim

import std/[strutils, unittest]
import ../../ct/trace/native_backend_selection

type
  HonourableRow = object
    host: string
    requested: string
    expected: string

  RefusalRow = object
    host: string
    requested: string
    recognized: bool     ## is this a backend name at all, or a misspelling?
    mustMention: seq[string]

const HonourableRows = [
  # The default, on every host, is MCR.
  HonourableRow(host: HostLinux, requested: "", expected: "mcr"),
  HonourableRow(host: HostMacos, requested: "", expected: "mcr"),
  HonourableRow(host: HostWindows, requested: "", expected: "mcr"),
  HonourableRow(host: HostOther, requested: "", expected: "mcr"),
  # `mcr` as an explicit PIN, on every host.
  HonourableRow(host: HostLinux, requested: "mcr", expected: "mcr"),
  HonourableRow(host: HostMacos, requested: "mcr", expected: "mcr"),
  HonourableRow(host: HostWindows, requested: "mcr", expected: "mcr"),
  HonourableRow(host: HostOther, requested: "mcr", expected: "mcr"),
  # The one extra value each host can honour.
  HonourableRow(host: HostLinux, requested: "rr", expected: "rr"),
  HonourableRow(host: HostWindows, requested: "ttd", expected: "ttd"),
  # Case and surrounding whitespace were already normalised and must stay so.
  HonourableRow(host: HostLinux, requested: "RR", expected: "rr"),
  HonourableRow(host: HostLinux, requested: "  mcr  ", expected: "mcr"),
  HonourableRow(host: HostWindows, requested: "Ttd", expected: "ttd"),
]

const RefusalRows = [
  # The three cases Q6 names by name.
  RefusalRow(host: HostMacos, requested: "rr", recognized: true,
             mustMention: @["rr", "macos", "mcr", "linux", "windows"]),
  RefusalRow(host: HostLinux, requested: "ttd", recognized: true,
             mustMention: @["ttd", "linux", "mcr, rr", "windows"]),
  RefusalRow(host: HostLinux, requested: "nonsense", recognized: false,
             mustMention: @["nonsense", "linux", "mcr, rr", "windows"]),
  # ... and the same two shapes on every other host, so no host is left with
  # an untested refusal path.
  RefusalRow(host: HostMacos, requested: "ttd", recognized: true,
             mustMention: @["ttd", "macos", "windows"]),
  RefusalRow(host: HostMacos, requested: "nonsense", recognized: false,
             mustMention: @["nonsense", "macos"]),
  RefusalRow(host: HostWindows, requested: "rr", recognized: true,
             mustMention: @["rr", "windows", "mcr, ttd", "linux"]),
  RefusalRow(host: HostWindows, requested: "nonsense", recognized: false,
             mustMention: @["nonsense", "windows", "mcr, ttd"]),
  RefusalRow(host: HostOther, requested: "rr", recognized: true,
             mustMention: @["rr", "other", "mcr", "linux"]),
  RefusalRow(host: HostOther, requested: "ttd", recognized: true,
             mustMention: @["ttd", "other", "windows"]),
  # A near miss, which is the shape a user actually types.
  RefusalRow(host: HostLinux, requested: "mrc", recognized: false,
             mustMention: @["mrc", "linux"]),
]

suite "NTR-2 / Q6: --backend refuses what the host cannot honour":

  test "every value a host can honour is used as given":
    for row in HonourableRows:
      checkpoint("host " & row.host & ", --backend '" & row.requested & "'")
      let selection = resolveNativeRecordingBackend(row.requested, row.host)
      check selection.ok
      check selection.backend == row.expected
      check selection.errorLines.len == 0

  test "--backend mcr PINS mcr, independently of what the default is":
    # The property Q6 says the flag exists for.  Asserted against the literal
    # string rather than against `defaultNativeRecordingBackend()`, so a
    # mutation flipping the default leaves this green and reddens only the
    # default assertion below.  If both go red, the pin is not being tested.
    for host in [HostLinux, HostMacos, HostWindows, HostOther]:
      checkpoint("host: " & host)
      let selection = resolveNativeRecordingBackend("mcr", host)
      check selection.ok
      check selection.backend == "mcr"

  test "the default native recorder is MCR":
    check defaultNativeRecordingBackend() == "mcr"
    for host in [HostLinux, HostMacos, HostWindows, HostOther]:
      checkpoint("host: " & host)
      let selection = resolveNativeRecordingBackend("", host)
      check selection.ok
      check selection.backend == "mcr"

  test "every value a host cannot honour is refused, never downgraded":
    for row in RefusalRows:
      checkpoint("host " & row.host & ", --backend '" & row.requested & "'")
      let selection = resolveNativeRecordingBackend(row.requested, row.host)
      # 1. Refused. Not coerced to mcr, which is what used to happen.
      check not selection.ok
      check selection.backend == ""
      check selection.errorLines.len > 0

      let text = selection.errorLines.join("\n")
      checkpoint("diagnostic:\n" & text)

      # 2. The first line distinguishes "unavailable here" from "misspelled",
      #    which is the question the user actually has.
      if row.recognized:
        check selection.errorLines[0].contains("cannot be honoured on this host")
      else:
        check selection.errorLines[0].contains(
          "is not a recognized recording backend")

      # 3. It names the requested value, the host, the values valid on that
      #    host, and where the requested one IS available.
      check text.startsWith("error: --backend " & row.requested.strip.toLowerAscii)
      check "requested: " in text
      check "host:" in text
      check "valid on " & row.host & ": " in text
      for fragment in row.mustMention:
        checkpoint("  must mention: " & fragment)
        check fragment in text

  test "the desktop's `db` sentinel is accepted and noted, never refused":
    # REGRESSION GUARD.  `db` is not a native backend and not a misspelling: it
    # is what `recordBackendWireName` emits and what
    # `src/frontend/index/traces.nim:1066,1199` puts on the `ct record` command
    # line for EVERY recording whose target the GUI did not classify as native.
    #
    # The GUI's classification and the core's `usesMaterializedTraces` are
    # different functions and they disagree — a file with an unrecognised
    # extension (`myapp.bin`, `a.out`) is `recordTargetAuto` to the GUI and
    # `LangC` to the core, and a `.lua` script is `recordTargetMaterializedLive`
    # to the GUI and `LangLua` to the core.  Both therefore reach the NATIVE
    # path carrying `--backend db`.  Refusing there fails a recording the user
    # never passed a flag for, which was measured against the shipped `ct`
    # during the NTR-2 review, so the sentinel takes the default and says so.
    for host in [HostLinux, HostMacos, HostWindows, HostOther]:
      for spelling in ["db", "materialized", "DB", "  db  "]:
        checkpoint("host " & host & ", --backend '" & spelling & "'")
        let selection = resolveNativeRecordingBackend(spelling, host)
        check selection.ok
        check selection.backend == defaultNativeRecordingBackend()
        check selection.errorLines.len == 0
        # Accepted, but never SILENTLY accepted — that is the half of Q6 this
        # arm still owes.
        check selection.noteLines.len > 0
        let note = selection.noteLines.join("\n")
        check note.startsWith("note: --backend " & spelling.strip.toLowerAscii)
        check "materialized" in note
        check defaultNativeRecordingBackend() in note

  test "an honourable native backend produces no note":
    # The note must be specific to the sentinel; a plain `--backend rr` that the
    # host can honour has nothing to say.
    for row in HonourableRows:
      checkpoint("host " & row.host & ", --backend '" & row.requested & "'")
      check resolveNativeRecordingBackend(row.requested, row.host).noteLines.len == 0

  test "the refusal text is exactly what the design specifies":
    # Q6 writes the diagnostic out in full, so that it cannot degrade into
    # "unsupported backend" one refactor later.  Both examples, verbatim.
    let macosRr = resolveNativeRecordingBackend("rr", HostMacos)
    check macosRr.errorLines == @[
      "error: --backend rr cannot be honoured on this host.",
      "       requested: rr",
      "       host:      macos",
      "       valid on macos: mcr",
      "       (rr is available on linux; ttd is available on windows)",
    ]

    let linuxNonsense = resolveNativeRecordingBackend("nonsense", HostLinux)
    check linuxNonsense.errorLines == @[
      "error: --backend nonsense is not a recognized recording backend.",
      "       requested: nonsense",
      "       host:      linux",
      "       valid on linux: mcr, rr",
      "       (ttd is available on windows)",
    ]

  test "the per-host value sets are what the design says they are":
    check backendsValidOn(HostMacos) == @["mcr"]
    check backendsValidOn(HostLinux) == @["mcr", "rr"]
    check backendsValidOn(HostWindows) == @["mcr", "ttd"]
    check backendsValidOn(HostOther) == @["mcr"]
    # Every host can honour the default, or the default would be unreachable.
    for host in [HostLinux, HostMacos, HostWindows, HostOther]:
      check defaultNativeRecordingBackend() in backendsValidOn(host)

  test "every recognized backend is honourable on exactly the host that names it":
    # Keeps `hostProviding` and `backendsValidOn` from drifting apart: the
    # parenthetical would otherwise be able to say "rr is available on linux"
    # while linux refused it.
    for backend in NativeRecordingBackends:
      checkpoint("backend: " & backend)
      let provider = hostProviding(backend)
      if provider.len == 0:
        # `mcr` is available everywhere and so never appears in the
        # "available elsewhere" parenthetical.
        check backend == "mcr"
        for host in [HostLinux, HostMacos, HostWindows, HostOther]:
          check backend in backendsValidOn(host)
      else:
        check backend in backendsValidOn(provider)
        check resolveNativeRecordingBackend(backend, provider).ok

  test "this host reports a platform the rule has a row for":
    # `hostRecordingPlatform()` is the single place the compile-time host is
    # applied.  A host whose name had no row would silently take the
    # `HostOther` arm, so it is checked rather than assumed.
    let host = hostRecordingPlatform()
    checkpoint("host: " & host)
    check host in [HostLinux, HostMacos, HostWindows, HostOther]
    check backendsValidOn(host).len > 0
    check resolveNativeRecordingBackend("", host).ok
    check resolveNativeRecordingBackend("mcr", host).ok

  test "--backend and --lang are independent axes":
    # Design §5.1: `--backend` names which native recorder records, never what
    # the target is; `--lang` names what the target is, never which backend
    # records it.  They sit next to each other in the options table and are
    # easy to conflate, so the independence is asserted rather than assumed:
    # the backend rule takes no language input at all, and its output is a
    # function of `(requested, host)` alone.
    for host in [HostLinux, HostMacos, HostWindows]:
      for requested in ["", "mcr", "rr", "ttd", "nonsense"]:
        checkpoint("host " & host & ", --backend '" & requested & "'")
        let first = resolveNativeRecordingBackend(requested, host)
        let second = resolveNativeRecordingBackend(requested, host)
        check first == second
