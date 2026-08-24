## native_backend_selection.nim
##
## Which native recording backend `ct record --backend <value>` selects, and
## what happens when the host cannot honour the value — milestone **NTR-2**,
## decision **Q6**, of
## `codetracer-specs/Planned-Features/Native-Target-Recognition.md`.
##
## ## The defect this module removes
##
## `nativeRecordingBackendForHost` used to be four lines that coerced anything
## it did not like to `mcr`:
##
## ```nim
## when defined(macosx):   "mcr"
## elif defined(windows):  if normalized == "ttd": "ttd" else: "mcr"
## elif defined(linux):    if normalized == "rr":  "rr"  else: "mcr"
## else:                   "mcr"
## ```
##
## So `--backend rr` on macOS, `--backend ttd` on Linux and `--backend typo`
## anywhere all produced an MCR recording with no diagnostic at all — a script
## asking for an rr recording got an MCR one and believed it had what it asked
## for.  That contradicts `codetracer-specs/CLI/ct-mcr/record.md`'s standing
## rule to *"refuse to start when the requested configuration cannot be
## honored, rather than silently downgrading"*.
##
## **This is a breaking change**, deliberately: an invocation that succeeded
## before now fails.  That is the point — it was succeeding at the wrong thing.
##
## One value is exempt, and it is exempt for a measured reason rather than a
## tidy one: `db`, the desktop's materialized-recorder sentinel, which the
## product itself puts on the `ct record` command line.  See
## `MaterializedBackendNames`.
##
## ## Why the host is a parameter
##
## `when defined(macosx)` cannot be tested from Linux, so the old shape could
## only ever be exercised on one third of the matrix.  The rule is a pure
## function of `(requested, host)` here, so one table test covers every host
## from any host, and the compile-time host is applied exactly once, at the
## edge.

import std/[strutils]

const
  BackendMcr* = "mcr"
  BackendRr* = "rr"
  BackendTtd* = "ttd"

  NativeRecordingBackends* = [BackendMcr, BackendRr, BackendTtd]
    ## Every value that names a native recording backend at all.  A value
    ## outside this set is a *misspelling*; a value inside it that this host
    ## cannot run is *unavailable here*.  The two get different first lines,
    ## because "did I typo it or is it simply not available?" is the question a
    ## user actually has.

  MaterializedBackendNames* = ["db", "materialized"]
    ## **Not** native backends, and not misspellings either: these are the
    ## desktop's spelling for "record with the dedicated, materialized-trace
    ## recorder".  `recordBackendWireName` emits `db` and
    ## `recordBackendChoiceFromWireName` reads back both
    ## (`src/frontend/viewmodel/viewmodels/welcome_screen_vm.nim`), and
    ## `src/frontend/index/traces.nim:1066,1199` puts it on the `ct record`
    ## command line for **every** recording whose target the GUI did not
    ## classify as native.
    ##
    ## That set is *not* the same set as the core's
    ## `usesMaterializedTraces`, and the difference is not hypothetical: the
    ## GUI classifies a file with an unrecognised extension (`myapp.bin`,
    ## `a.out`) as `recordTargetAuto` and a `.lua` script as
    ## `recordTargetMaterializedLive`, sending `--backend db` for both, while
    ## the core resolves them to `LangC` / `LangLua`, neither of which uses a
    ## materialized trace.  Those recordings therefore arrive on the **native**
    ## path carrying `db`.  Refusing them would break a GUI recording the user
    ## never typed a flag for, so the sentinel is accepted, the default applies,
    ## and a note says so — which is the same "the flag names nothing this
    ## recorder can act on" treatment it already gets on the materialized path,
    ## made visible instead of silent.

  HostMacos* = "macos"
  HostLinux* = "linux"
  HostWindows* = "windows"
  HostOther* = "other"

type
  NativeBackendSelection* = object
    ok*: bool
    backend*: string
      ## Meaningful only when `ok`.
    errorLines*: seq[string]
      ## The refusal, already formatted.  Empty when `ok`.
    noteLines*: seq[string]
      ## A diagnostic that is **not** a refusal: the value was understood and
      ## deliberately not acted on.  Empty unless the materialized sentinel was
      ## passed on the native path.

proc hostRecordingPlatform*(): string =
  ## The host this build runs on, in the spelling the diagnostic prints.
  when defined(macosx): HostMacos
  elif defined(windows): HostWindows
  elif defined(linux): HostLinux
  else: HostOther

proc backendsValidOn*(host: string): seq[string] =
  ## MCR is the default native recorder on every host.  Linux can additionally
  ## select rr and Windows TTD; macOS has only MCR.  Order matters: it is the
  ## order the diagnostic lists them in, so it must be stable.
  case host
  of HostLinux: @[BackendMcr, BackendRr]
  of HostWindows: @[BackendMcr, BackendTtd]
  of HostMacos: @[BackendMcr]
  else: @[BackendMcr]

proc hostProviding*(backend: string): string =
  ## Where a backend that is not available here *is* available.  `mcr` returns
  ## `""` because it is available everywhere and therefore never appears in the
  ## "available elsewhere" parenthetical.
  case backend
  of BackendRr: HostLinux
  of BackendTtd: HostWindows
  else: ""

proc defaultNativeRecordingBackend*(): string =
  ## The default when `--backend` is not given.  Stated once, here, so the
  ## `--backend mcr` *pin* can be asserted independently of it: a mutation that
  ## flips this default must leave the pin's assertion green.
  BackendMcr

proc availableElsewhere(host: string): string =
  ## "rr is available on linux; ttd is available on windows" — every backend
  ## this host cannot honour, and where it can be.
  let valid = backendsValidOn(host)
  var parts: seq[string] = @[]
  for backend in NativeRecordingBackends:
    if backend in valid:
      continue
    let provider = hostProviding(backend)
    if provider.len > 0:
      parts.add(backend & " is available on " & provider)
  parts.join("; ")

proc resolveNativeRecordingBackend*(requested: string, host: string):
    NativeBackendSelection =
  ## Q6, implemented.  An empty `requested` takes the default; a value the host
  ## can honour is used as given — including `mcr`, which is therefore a **pin**
  ## rather than a coincidence of the default; anything else is refused.
  let normalized = requested.strip.toLowerAscii
  if normalized.len == 0:
    return NativeBackendSelection(ok: true, backend: defaultNativeRecordingBackend())

  if normalized in MaterializedBackendNames:
    # See `MaterializedBackendNames`.  This arm exists because the product
    # itself puts this value on the command line, so refusing it would fail a
    # recording the user never passed a flag for.  It is a note rather than
    # silence: Q6's rule is that a value is never *silently* not honoured.
    return NativeBackendSelection(
      ok: true,
      backend: defaultNativeRecordingBackend(),
      noteLines: @[
        "note: --backend " & normalized &
          " names the materialized-trace recorder, and this target is native.",
        "      recording with " & defaultNativeRecordingBackend() &
          " instead; pass --lang to record it as a materialized-trace language."])

  let valid = backendsValidOn(host)
  if normalized in valid:
    return NativeBackendSelection(ok: true, backend: normalized)

  let known = normalized in NativeRecordingBackends
  var lines: seq[string] = @[]
  if known:
    lines.add("error: --backend " & normalized &
      " cannot be honoured on this host.")
  else:
    lines.add("error: --backend " & normalized &
      " is not a recognized recording backend.")
  lines.add("       requested: " & normalized)
  lines.add("       host:      " & host)
  lines.add("       valid on " & host & ": " & valid.join(", "))
  let elsewhere = availableElsewhere(host)
  if elsewhere.len > 0:
    # Without this a user on macOS reading "valid on macos: mcr" cannot tell
    # whether `rr` was misspelled or merely unavailable here.
    lines.add("       (" & elsewhere & ")")
  NativeBackendSelection(ok: false, errorLines: lines)
