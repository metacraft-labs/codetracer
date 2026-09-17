## viewmodels/point_collection_source.nim — PLAT-11's verification gate.
##
## The milestone's gate is one sentence:
##
##   "Point collections write `PointListVM.points`, which today is written by
##    nothing."
##
## It was true. `setPoints` had two call sites, neither a producer: the
## storybook fixture and the signal's own initialiser. Six other modules in
## this tree cite `PointListVM.points` BY NAME as the canonical example of a
## signal nothing fills — `tui/app/source_binding.nim`, `views/call_stack.nim`,
## `variables_binding.nim`, `timeline_binding.nim`, `origin_binding.nim` and
## `views/variables.nim`. This file is the first producer.
##
## ## AND THE SECOND, 2026-09-17: THE ENGINE
##
## `points` is `ReplayDataStore.pointList.rows` now, and
## `ReplayDataStore.applyTracepointResults` writes a row per spec of a
## `ct/run-tracepoints` sweep. The two producers do not fight: the sweep MERGES
## by `(path, line)`, so running a sweep over a collection's points annotates
## those rows with what the engine found instead of replacing the list with the
## subset that was swept. `applyCollections` below routes through `setPoints`,
## which routes through `applyPointRows`, so both ends meet in the store.
##
## ## WHAT IT DOES AND WHAT IT REFUSES TO DO
##
## It turns resolved collections into rows. It performs no I/O, parses
## nothing, and — this is the part that matters — **it does not filter**.
##
## Project-Definitions.md §4: "A point whose location no longer resolves is
## reported, not dropped. A collection that silently loses half its points as
## a file evolves is worse than one that says so."
##
## So `rowsOf` emits exactly one row per declared point, whatever became of
## it, carrying `resolution` and `detail` so the pane can render an
## unresolvable point as an unresolvable point rather than as an absence.
## `test_point_collections_fill_the_point_list.nim` asserts the row count
## against the declared point count over a file edited four different ways,
## and a mutation arm removes the filter-less-ness to prove the assertion can
## fail.
##
## ## ENABLEMENT IS THE DEFINITION'S DEFAULT, NOT A DECISION MADE HERE
##
## §4: collections "may be enabled and disabled as a unit, and several may be
## active at once". The definition states the default (`enabled` in
## `points.toml`); the user's own toggle is session state and belongs to
## whatever owns the session, not to a conversion function. `rowsOf` takes the
## enabled set as an argument so the two cannot be confused.

import std/[sets, strutils]

import ../../../common/project_definitions

import ./point_list_vm

export point_list_vm.PointListEntry

func rowOf*(r: PointResolution; collection: string; enabled: bool):
    PointListEntry =
  ## ONE resolved point as ONE row. Total: there is no outcome for which this
  ## returns nothing.
  PointListEntry(
    kind: $r.point.kind,
    label: (if r.point.label.len > 0: r.point.label
            elif r.point.expression.len > 0: r.point.expression
            else: r.point.anchor.text),
    path: r.point.path,
    # 0 for an unresolvable point, which is what `resolve` already returns.
    # Not clamped to 1, not defaulted to the anchor's recorded line hint: a
    # row that carries a plausible-looking line for a point that could not be
    # found is the silent mislocation the whole anchor mechanism exists to
    # prevent, arriving one layer later.
    line: r.line,
    enabled: enabled,
    collection: collection,
    resolution: describe(r.outcome),
    detail: r.detail)

func rowsOf*(resolutions: openArray[CollectionResolution];
             enabledCollections: HashSet[string]): seq[PointListEntry] =
  ## Every point of every collection, in declaration order.
  ##
  ## NO `continue`, NO filter, NO `if isUsable`. The absence of those three is
  ## the deliverable; see this module's header.
  ##
  ## A point of a DISABLED collection is still a row, with `enabled = false`.
  ## Dropping it would make "disable the collection" and "the collection no
  ## longer exists" look identical in the pane, and a user who disabled
  ## something needs to be able to find it again.
  for cr in resolutions:
    let on = cr.collection.name in enabledCollections
    for pr in cr.points:
      result.add rowOf(pr, cr.collection.name, on)

proc applyCollections*(vm: PointListVM;
                       resolutions: openArray[CollectionResolution];
                       enabledCollections: HashSet[string]) =
  ## Write `PointListVM.points`. THE GATE.
  ##
  ## `setPoints` rather than assigning `vm.points.val` directly, so the
  ## producer goes through the same door the storybook fixture does and a
  ## reactive consumer sees one write rather than a torn sequence.
  vm.setPoints rowsOf(resolutions, enabledCollections)

func defaultEnabled*(collections: openArray[PointCollection]): HashSet[string] =
  ## The set a session starts with: every collection whose definition said
  ## `enabled = true`.
  ##
  ## A function over the definitions rather than a field somewhere, because
  ## "which collections are on" is session state that the definition only
  ## SEEDS — §4's "may be enabled and disabled as a unit" is a thing the user
  ## does afterwards, and a seed that pretended to be the state would be
  ## overwritten by the first toggle and then wrong.
  result = initHashSet[string]()
  for c in collections:
    if c.enabledByDefault: result.incl c.name

func unresolvedRows*(rows: openArray[PointListEntry]): seq[PointListEntry] =
  ## The rows a pane should mark. A fold rather than a predicate re-derived at
  ## each call site (Verification-Harness-Traps §14), and it keys on `line ==
  ## 0` — the property a pane actually cares about, which is "can I jump
  ## here" — rather than on the `resolution` TEXT, which is a label.
  for r in rows:
    if r.line == 0: result.add r

func describeRows*(rows: openArray[PointListEntry]): string =
  ## One line per row, for a log or a `--verbose` run. Every declared point
  ## appears, which is the property this whole file exists to have.
  var lines: seq[string] = @[]
  for r in rows:
    lines.add (if r.enabled: "[x] " else: "[ ] ") & r.kind & " " & r.path &
      (if r.line > 0: ":" & $r.line else: "") &
      " (" & r.collection & ", " & r.resolution & ")" &
      (if r.detail.len > 0: " — " & r.detail else: "")
  lines.join("\n")
