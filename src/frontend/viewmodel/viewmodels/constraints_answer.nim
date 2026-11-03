## viewmodels/constraints_answer.nim — what a project's circuit costs, as a
## host measures it, and when there is no measurement, the sentence that says
## why.
##
## ONE RULE, EVERY HOST, as `test_catalog_answer` is for the Test Results
## pane. The desktop's main process answers `CODETRACER::ns9-panes` with it
## (`index/ns9_panes.nim`, running `nargo` with node's `child_process`), and
## the terminal and the GPUI window fill their own Constraints pane with it
## (`host/native_constraints_host.nim`, with `std/osproc`). Each host does only
## what its platform must — say whether the marker file exists, run
## `nargo info --json` in the folder and report how that went, and read the
## `.nr` sources the rows are placed against — and what the pane is told is
## decided here, once. Until PLAT-62 these sentences were written inline in
## `ns9_panes`, where a second front-end could only have copied them.
##
## The ORDER of the arms is the order a user can act on: no folder, a folder
## that is not a Noir crate, a `nargo` that is not installed, a measurement
## that failed, a report.
##
## Pure; C and JavaScript backends.

import std/strutils

import ../../../common/noir_constraints
import ../../../ct_test/frameworks/noir_test_syntax
from ./no_project_folder import NoProjectFolderText

export noir_constraints, NoirSourceFile, NoirProjectMarker

const
  NotANoirCrateText* =
    "This project has no " & NoirProjectMarker & ", so it is not a Noir " &
    "crate and has no circuit to measure. Constraint counts are produced " &
    "per language; Noir is the first producer CodeTracer has."
  NargoMissingText* =
    "`nargo` is not on this machine's PATH, so the circuit cannot be " &
    "measured. Install the Noir toolchain to see constraint counts."
  NargoFailedStem* = "nargo info could not measure this project: "
  NargoInfoProvenance* = "nargo info --json, run just now"
  NargoInfoArgs = ["info", "--json"]
    ## The command every host runs, in the project's folder.

type
  NargoInfoRun* = object
    ## How a host's `nargo info --json` went.
    started*: bool
      ## False when the program could not be started at all.
    missing*: bool
      ## The program is not installed (ENOENT, not on PATH).
    exitCode*: int
    output*: string
      ## Its standard output.
    message*: string
      ## Its standard error, or why it could not start.

  ConstraintsAnswer* = object
    ## What a host tells the pane.
    hasReport*: bool
    report*: ConstraintReport
    absence*: string
      ## "" when `hasReport`.

proc absenceBeforeRun*(folder: string; hasMarker: bool): string =
  ## Why there is nothing to run for `folder`, or "" when `nargo` should run.
  if folder.len == 0:
    return NoProjectFolderText
  if not hasMarker:
    return NotANoirCrateText
  ""

proc absenceOfRun*(run: NargoInfoRun): string =
  ## Why a finished run is not a report, or "" when its output is one.
  if run.missing:
    return NargoMissingText
  if not run.started:
    return NargoFailedStem & run.message
  if run.exitCode != 0:
    let said = run.message.strip()
    return NargoFailedStem &
           (if said.len > 0: said[0 ..< min(said.len, 400)]
            else: "nargo info exited with status " & $run.exitCode)
  ""

proc constraintsAnswer*(folder: string; hasMarker: bool;
                        run: NargoInfoRun): ConstraintsAnswer =
  ## The answer for `folder`, once `run` has finished (ignored when the
  ## folder needs no run).
  let before = absenceBeforeRun(folder, hasMarker)
  if before.len > 0:
    return ConstraintsAnswer(absence: before)
  let failed = absenceOfRun(run)
  if failed.len > 0:
    return ConstraintsAnswer(absence: failed)
  let report = parseNargoInfoJson(run.output, NargoInfoProvenance)
  if report.absence.len > 0:
    return ConstraintsAnswer(absence: report.absence)
  ConstraintsAnswer(hasReport: true, report: report)
