## extension_selection.nim — `--no-extensions`, as a decision and nothing else.
## PLAT-9, Extensibility-Model.md §7's last bullet.
##
## §7: "The core must remain usable with every extension disabled. A single
## flag (`--no-extensions`) must produce a working debugger, and that path is
## tested, because it is the recovery route when an extension makes the product
## unusable."
##
## ## WHAT THIS MODULE IS, AND WHY IT IS SHAPED LIKE `ui_selection.nim`
##
## `planExtensions` turns `argv` plus an environment value into an
## `ExtensionPlan` and does nothing else: it opens no file, reads no
## configuration, loads no plugin and prints nothing. That is the same split
## PLAT-1 made for `--ui`, and for the same reason — a recovery flag that is
## read AFTER the thing it is recovering from has already been attempted is a
## recovery flag that does not work.
##
## The flag's whole job is to be read before the plugin host exists. Once the
## decision is a value, `newPluginHost(..., extensionsEnabled = plan.enabled)`
## and `newSurfaceHost(..., extensionsEnabled = ...)` carry it, and
## `plugin_host/host.nim` and `plugin_host/surface_host.nim` document exactly
## what `false` guarantees.
##
## ## IT IS A BOOLEAN FLAG, SO IT TAKES NO VALUE
##
## `--no-extensions=false` is refused rather than read as "actually, do load
## them". A recovery flag whose meaning can be inverted by a value the user did
## not mean to type is worse than no flag: the one invocation it exists for is
## the one where the user is guessing.
##
## ## THE NAME IS SPELLED ONCE
##
## `NoExtensionsFlag` lives in `plugin_host/surface_host.nim`, because that is
## where the report that names it to a user is written. This module cannot
## import it — `src/ct` must not pull in the reactive host to parse a command
## line — so `ExtensionsFlag` below is the second spelling, and
## `extension_selection_test.nim` asserts the two agree by reading the other
## file's source. One name, two places, and a test rather than a convention.

import std/strutils

type
  ExtensionSource* = enum
    ## Which layer answered, carried into diagnostics for the same reason
    ## `UiSource` is: "extensions are off" is a confusing message when the user
    ## never typed the flag and an environment variable they forgot they
    ## exported is what turned them off.
    esDefault = "the built-in default"
    esFlag = "the --no-extensions flag"
    esEnv = "the CODETRACER_NO_EXTENSIONS environment variable"

  ExtensionPlanKind* = enum
    epkDecided
    epkUsageError

  ExtensionPlan* = object
    enabled*: bool
      ## Meaningless when `kind == epkUsageError`, and read by nobody then.
    source*: ExtensionSource
    case kind*: ExtensionPlanKind
    of epkDecided:
      ctArgs*: seq[string]
        ## `argv` with `--no-extensions` removed, for confutils. IDENTICAL to
        ## the input when the flag was absent, which is what makes adopting
        ## this flag change nothing for an existing user.
    of epkUsageError:
      message*: string
        ## One line, already prefixed with `ct: `, for stderr.

const
  ExtensionsFlag* = "--no-extensions"
  ExtensionsEnvVar* = "CODETRACER_NO_EXTENSIONS"

  ExtensionsEnvTruthy*: array[4, string] = ["1", "true", "yes", "on"]
    ## The spellings that TURN EXTENSIONS OFF. Anything else — including the
    ## empty string — leaves them on, deliberately: an exported-but-empty
    ## variable is the commonest way a shell hands a program a value it did not
    ## mean to, and the failure direction here must be "your plugins still
    ## load" rather than "your plugins silently vanished".

func extensionsEnvDisables*(value: string): bool =
  ## One predicate, read by `planExtensions` and by anything that wants to
  ## explain the rule (Verification-Harness-Traps §14). Case-insensitive on the
  ## VALUE only; the variable's own name is not.
  let v = value.strip().toLowerAscii()
  for truthy in ExtensionsEnvTruthy:
    if v == truthy: return true
  false

func planExtensions*(args: openArray[string]; envValue = ""): ExtensionPlan =
  ## §5-style resolution order, with two layers instead of four: the flag wins,
  ## then the environment, then the default (extensions on).
  ##
  ## Scanning is deliberately weak, exactly as `scanUiArgs` is: this module
  ## picks one token out of the line and copies every other one through
  ## untouched. confutils owns ct's grammar, and a second parser that believed
  ## it understood the whole line is how the two come to disagree.
  ##
  ## **A bare `--` stops the scan.** Everything after it belongs to a recorded
  ## child program — `ct record prog --no-extensions` must pass the flag to
  ## `prog`, because turning CodeTracer's plugins off is not something a
  ## recorded program's own arguments get to do.
  var enabled = true
  var source = esDefault
  if extensionsEnvDisables(envValue):
    enabled = false
    source = esEnv

  var stripped: seq[string] = @[]
  var stopped = false
  for arg in args:
    if stopped:
      stripped.add arg
      continue
    if arg == "--":
      stopped = true
      stripped.add arg
      continue
    if arg == ExtensionsFlag:
      enabled = false
      source = esFlag
      continue
    if arg.startsWith(ExtensionsFlag & "=") or
       arg.startsWith(ExtensionsFlag & ":"):
      return ExtensionPlan(kind: epkUsageError, enabled: enabled,
        source: source,
        message: "ct: '" & ExtensionsFlag & "' is a flag and takes no value; " &
          "write '" & ExtensionsFlag & "' on its own, or leave it out to " &
          "load your extensions")
    stripped.add arg
  ExtensionPlan(kind: epkDecided, enabled: enabled, source: source,
                ctArgs: stripped)

func describe*(plan: ExtensionPlan): string =
  ## What a user is told when they wonder where their extensions went. It
  ## names the SOURCE, because the answer to "I did not turn them off" is
  ## usually an environment variable.
  case plan.kind
  of epkUsageError: plan.message
  of epkDecided:
    if plan.enabled: "extensions are enabled (" & $plan.source & ")"
    else: "extensions are disabled by " & $plan.source
