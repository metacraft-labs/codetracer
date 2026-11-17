## viewmodels/generated_code_presenter.nim
##
## THE OPERATION'S SURFACE HALF, SHARED: what every front-end does once a
## producer has a listing — `GUI/Debugging-Features/Generated-Code-Listing.md`
## §7 (the Low Level Code pane shows it) and §13.4 (the Nim producer's
## inputs).
##
## LANE: `vm-unit` AND `vm-unit-js`. No host: the host hands over how to read
## a file of the recording (`RecordedReader`) and which files it has.
##
## ## WHY THIS IS NOT IN THE DESKTOP ANY MORE
##
## Until 2026-11-12 the desktop's `ui/generated_code.showGeneratedCode` held
## this — the listing turned into the pane's rows, installed with its
## anchors, the operation's state moved — and no other surface had it. A
## terminal, a GPUI window or an editor that wanted the same listing would
## have had to copy it, which is how surfaces come to disagree. So it is
## here, and each surface only routes its gesture to `showGeneratedCode`.
import std/strutils

import ../store/types
import ./generated_code_vm
import ./generated_code_operation
import ./low_level_code_vm
import ./nim_c_producer

const NoHighLevelLine* = -1
  ## A generated row's `LowLevelInstruction.highLevelLine`: the listing's
  ## rows are mapped by their anchors, not by a line of their own.

type
  RecordedText* = tuple[ok: bool, text, message: string]
  RecordedFetch* = proc(path: string; done: proc(r: RecordedText))
    ## A file of the recording, whole (the session's source provider at
    ## generation 0, as the Debug-mode editor reads it). Asynchronous, as
    ## every provider may be (the desktop's answers over IPC); a native host
    ## that reads at once calls `done` before it returns.

proc recordedPathsOf*(node: FilesystemEntryNode; acc: var seq[string]) =
  ## The files under `node`, a recording's file tree (`FilesystemVM.rootEntry`):
  ## what `nimCListingOf` picks the generated C from.
  if not node.isFolder and node.path.len > 0:
    acc.add node.path
  for c in node.children:
    recordedPathsOf(c, acc)

proc rowBase(listing: GeneratedListing): int =
  ## What a row's offset column counts from. A compiler's opcode listing
  ## numbers its opcodes from 0 (Noir's `StepId`); a generated SOURCE file is
  ## read by its line numbers, from 1 — what `#line` and a C compiler's
  ## diagnostics name. The anchors are keyed by row INDEX, not by this.
  if listing.producer == NimCProducer: 1 else: 0

proc rowsOf*(listing: GeneratedListing): seq[LowLevelInstruction] =
  ## The listing's rows as the Low Level Code pane draws them: the row's text,
  ## its compiler annotation, and its offset — its index, or for a generated
  ## source file its line number (`rowBase`).
  let base = rowBase(listing)
  for r in listing.rows:
    result.add LowLevelInstruction(
      name: r.text, args: "", other: r.annotation, offset: r.index + base,
      highLevelPath: "", highLevelLine: NoHighLevelLine)

proc present*(gvm: GeneratedCodeVM; pane: LowLevelCodeVM;
              t: GeneratedCodeTarget; listing: GeneratedListing;
              failure, path: string; line: int) =
  ## Show `listing` — or, when it could not be built, `failure` — in the Low
  ## Level Code pane, anchored to `path:line`, and move the operation's state
  ## (`GeneratedCodeVM`) with it. §8: a build that fails still opens the
  ## surface, carrying the reason, never an empty listing.
  if not gvm.isNil:
    gvm.noteBuildStarted(t, path, line)
    if failure.len > 0:
      gvm.noteBuildFailed(failure)
    else:
      gvm.openListing(listing, line)
  if pane.isNil:
    return
  if failure.len > 0:
    discard pane.showGeneratedListing(@[], @[], listing.support, path, line,
                                      failure)
  else:
    discard pane.showGeneratedListing(rowsOf(listing), listing.anchors,
                                      listing.support, path, line,
                                      listing.listingAbsence)
    # `showGeneratedListing` labels rows as Noir's opcodes (`StepId(n)`);
    # another producer's rows are plain numbers.
    if listing.producer != "noir-acir-compile":
      pane.setNoirProject(false)

type GeneratedC = tuple[path, text, map: string]
  ## A generated C file and its Source Map v3 ("" when it has none).

proc fetchWithMap(path: string; fetch: RecordedFetch;
                  done: proc(got: GeneratedC; ok: bool)) =
  ## `path` and the `.c.map` beside it (`nim_c_producer.mapPathOf`): the
  ## codetracer compiler anchors its C by the map, a stock compiler by
  ## `#line` directives, so a missing map is not a failure.
  fetch(path, proc(r: RecordedText) =
    if not r.ok:
      done((path: path, text: "", map: ""), false)
      return
    let text = r.text
    fetch(mapPathOf(path), proc(m: RecordedText) =
      done((path: path, text: text, map: (if m.ok: m.text else: "")), true)))

proc fetchAll(paths: seq[string]; fetch: RecordedFetch; at: int;
              acc: seq[GeneratedC]; done: proc(got: seq[GeneratedC])) =
  ## `paths` read one after another (a provider may serve one request at a
  ## time), the ones that could not be read left out.
  if at >= paths.len:
    done(acc)
    return
  fetchWithMap(paths[at], fetch, proc(got: GeneratedC; ok: bool) =
    var next = acc
    if ok:
      next.add got
    fetchAll(paths, fetch, at + 1, next, done))

proc nimCListingOf*(stop: StopLocation; path: string;
                    recordedFiles: openArray[string]; fetch: RecordedFetch;
                    done: proc(listing: GeneratedListing; failure: string)) =
  ## §13.4: the generated C of Nim source `path`, from the recording. The
  ## stop's own C file when the debugger is in `path` (the engine names it,
  ## `StopLocation.cPath`); otherwise the recording's generated C file whose
  ## directives name `path` most (`nimCFileFor`). Every file read through
  ## `fetch`, so a recording is read as the editor reads it.
  proc finish(c: GeneratedC) =
    if c.path.len == 0:
      done(GeneratedListing(), "no generated C file of this recording " &
        "maps back to " & path)
      return
    let listing = nimCListing(c.text, path, c.map)
    if listing.anchors.len == 0:
      done(listing, c.path & " carries neither #line directives nor a " &
        "source map (a .c.map beside it), so its " &
        "C cannot be mapped back: compile with --lineDir:on, or with " &
        "CodeTracer's Nim and --sourcemap:on")
    else:
      done(listing, "")
  var generated: seq[string] = @[]
  for f in recordedFiles:
    if isGeneratedNimC(f):
      generated.add f
  proc search() =
    if generated.len == 0:
      done(GeneratedListing(), "this recording carries no generated C " &
        "(a native recording of a Nim program bundles its nimcache's " &
        "`*.nim.c` files)")
      return
    fetchAll(generated, fetch, 0, @[], proc(got: seq[GeneratedC]) =
      let chosen = nimCFileFor(path, got)
      var found: GeneratedC = (path: "", text: "", map: "")
      for c in got:
        if c.path == chosen:
          found = c
      finish(found))
  if stop.cPath.len > 0 and stop.path == path:
    fetchWithMap(stop.cPath, fetch, proc(got: GeneratedC; ok: bool) =
      if ok: finish(got)
      else: search())
  else:
    search()

proc showGeneratedCode*(gvm: GeneratedCodeVM; pane: LowLevelCodeVM;
                        targetId, path: string; line: int;
                        stop: StopLocation; recordedFiles: openArray[string];
                        fetch: RecordedFetch;
                        shown: proc(failure: string)): string =
  ## THE OPERATION for a target this module produces, at `path:line`: build
  ## the listing and show it (`present`), then `shown` with what it could
  ## not do ("" when the listing is in the pane). Answers at once with why it
  ## cannot start — a target its host produces (the desktop's Noir
  ## artefact) — else "".
  var t: GeneratedCodeTarget
  if not targetById(targetId, t):
    return "`" & targetId & "` is not a generated-code target"
  case t.id
  of NimCTargetId:
    nimCListingOf(stop, path, recordedFiles, fetch,
      proc(listing: GeneratedListing; failure: string) =
        present(gvm, pane, t, listing, failure, path, line)
        if not shown.isNil:
          shown(failure))
    ""
  else:
    "the " & t.displayName & " target is produced by its host"

proc firstTargetOf*(path: string): string =
  ## The id of `path`'s language's first rung (`nim.c` for a Nim file), or
  ## "" for a language with none — what a "View Generated Source" gesture
  ## means in a file.
  let ts = targetsForPath(path)
  if ts.len > 0: ts[0].id else: ""

proc isNimSource*(path: string): bool =
  path.endsWith(".nim")
