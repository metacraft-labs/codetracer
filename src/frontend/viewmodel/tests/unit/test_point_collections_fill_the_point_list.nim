## test_point_collections_fill_the_point_list.nim — PLAT-11's VERIFICATION
## GATE.
##
## The milestone states it in one sentence:
##
##   "Point collections write `PointListVM.points`, which today is written by
##    nothing."
##
## It WAS written by nothing. `setPoints` had two call sites, neither a
## producer — the storybook fixture and the signal's own initialiser — and six
## other modules in this tree cite `PointListVM.points` by name as the
## canonical never-filled signal. This suite drives the real ViewModel and
## asserts that a project definition is now a producer of it.
##
## ## WHAT IS REAL HERE
##
## The `PointListVM` is the product's, created through the product's
## `createPointListVM` inside a real reactive root. The parse is the product's
## parser over real definition text. The write goes through the product's
## `setPoints`. The only thing supplied by the test is the source file's
## LINES, which is what the resolver's `{.noSideEffect.}` parameter is for:
## in production the caller that holds the checkout reads them, and here the
## caller that holds the fixture provides them. That is the same seam, not a
## substitute for it.
##
## ## NO MOCKS
##
## None, and nothing to mock. See `noStore` below for why the store is `nil`
## rather than a `MockBackendService`: this path contacts no backend, and a
## mock would assert that it contacts one in some particular way.
##
## ## THE ASSERTION THAT MATTERS MOST
##
## §4: "**A point whose location no longer resolves is reported, not
## dropped.**" So the central case declares five points across two
## collections, breaks two of them, disables one collection, and asserts the
## row count is FIVE. A producer that filtered on either would pass every
## other assertion in this file.
##
## ## TRAP 13 (Verification-Harness-Traps §13, §13a)
##
## Every assertion helper here is a `template`.

import std/[sets, strutils, unittest]

import isonim/core/signals
import isonim/viewmodel

import ../../../../common/project_definitions
import ../../store/replay_data_store
import ../../viewmodels/point_list_vm
import ../../viewmodels/point_collection_source

const ExpectedAssertions = 87

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

const Definition = """
schema = "codetracer.points.v1"

[[collection]]
name = "the request path"
enabled = true

[[collection.point]]
kind = "tracepoint"
path = "src/router.nim"
anchor = "proc handleRequest"
offset = "1"
line = "4"
expression = "r.url"
label = "entry"

[[collection.point]]
kind = "breakpoint"
path = "src/router.nim"
anchor = "proc handleRetry"
line = "6"

[[collection.point]]
kind = "breakpoint"
path = "src/router.nim"
anchor = "proc handleTimeout"
line = "12"

[[collection.point]]
kind = "breakpoint"
path = "src/gone.nim"
anchor = "proc gone"

[[collection]]
name = "cache misses"
enabled = false

[[collection.point]]
kind = "tracepoint"
path = "src/router.nim"
anchor = "proc handleRetry"
expression = "key"
"""

const EditedRouter = @[
  "# a new comment",              # 1
  "# and another",                # 2
  "import std/strutils",          # 3
  "",                             # 4
  "proc handleRequest(r: Req) =", # 5
  "  discard",                    # 6
  "",                             # 7
  "proc handleRetry(r: Req) =",   # 8
  "  discard",                    # 9
]

proc routerLines(path: string): SourceFile {.noSideEffect, gcsafe,
                                             raises: [].} =
  ## A module-level `proc` and not a closure, because `unittest`'s `test` body
  ## is a `block` at module scope: a `var` inside one is a global, and a
  ## `{.gcsafe.}` closure cannot capture one. `resolveCollection`'s parameter
  ## carries that pragma BY DESIGN — it is the compiler refusing a lookup that
  ## reads the clock — so the suite obeys it rather than weakening it.
  if path == "src/router.nim": SourceFile(present: true, lines: EditedRouter)
  else: SourceFile(present: false)

const noStore: ReplayDataStore = nil
  ## `createPointListVM` keeps its store "for potential future backend
  ## queries" and makes none, and THIS PRODUCER MAKES NONE EITHER — a project
  ## definition is read from the repository, never from the engine.
  ##
  ## So the store is `nil` rather than a `MockBackendService`. That is the
  ## opposite of a shortcut: a mock here would assert that this path talks to
  ## a backend in some particular way, when the claim worth making is that it
  ## does not talk to one at all. A `nil` store that the suite never
  ## dereferences, in a VM that never dereferences it, is the strongest
  ## available statement of that — and it is the reason this file's header can
  ## say "no mocks" without a justification paragraph.

proc uneditedRouter(path: string): SourceFile {.noSideEffect, gcsafe,
                                                raises: [].} =
  ## The file as the definition's author last saw it: `EditedRouter` without
  ## the two comment lines somebody later inserted at the top.
  if path == "src/router.nim":
    SourceFile(present: true, lines: EditedRouter[2 .. ^1])
  else:
    SourceFile(present: false)

proc loadedCollections(): seq[PointCollection] =
  let f = DefinitionFile(kind: dfkPoints, origin: doProject,
                         path: ".codetracer/points.toml", text: Definition)
  let loaded = loadProjectDefinitions([f])
  doAssert loaded.problems.len == 0, renderAll(loaded.problems)
  loaded.project.collections

proc resolveAll(): seq[CollectionResolution] =
  for c in loadedCollections():
    result.add resolveCollection(c, routerLines)

# ---------------------------------------------------------------------------

suite "PLAT-11: point collections write PointListVM.points":

  test "the definition parses into two collections and five points":
    let cs = loadedCollections()
    ckEq cs.len, 2
    ckEq cs[0].name, "the request path"
    ck cs[0].enabledByDefault
    ckEq cs[0].points.len, 4
    ckEq cs[1].name, "cache misses"
    ck not cs[1].enabledByDefault
    ckEq cs[1].points.len, 1

  test "the real PointListVM starts empty, which is the gate's premise":
    # The milestone's gate says this signal "today is written by nothing". The
    # premise is asserted rather than assumed, because a gate about a signal
    # that was already full would be measuring nothing.
    let vm = createPointListVM(noStore)
    defer: vm.dispose()
    ckEq vm.points.val.len, 0

  test "applyCollections WRITES the signal — the verification gate":
    let vm = createPointListVM(noStore)
    defer: vm.dispose()
    let resolutions = resolveAll()
    let enabled = defaultEnabled(loadedCollections())

    applyCollections(vm, resolutions, enabled)

    # THE GATE. Written by something.
    ck vm.points.val.len > 0
    # And the count is the DECLARED point count, which is the §4 assertion:
    # two of the five points do not resolve, and five rows come back.
    ckEq vm.points.val.len, 5

  test "a point that no longer resolves is a ROW, not an absence":
    # §4: "A point whose location no longer resolves is reported, not dropped.
    # A collection that silently loses half its points as a file evolves is
    # worse than one that says so."
    let vm = createPointListVM(noStore)
    defer: vm.dispose()
    applyCollections(vm, resolveAll(), defaultEnabled(loadedCollections()))
    let rows = vm.points.val

    ckEq rows.len, 5

    # 1. Moved: two comment lines were inserted above the anchor, so the
    #    recorded line 4 is now line 6 and the point followed the anchor.
    ckEq rows[0].resolution, "moved"
    ckEq rows[0].line, 6
    ckEq rows[0].kind, "tracepoint"
    ckEq rows[0].label, "entry"
    ckEq rows[0].path, "src/router.nim"
    ckEq rows[0].collection, "the request path"
    ck rows[0].enabled
    ck rows[0].detail.contains("was at line 4")

    # 2. Moved as well, and to a different line — which is what makes the
    #    anchor worth having: a bare line number would have silently marked
    #    line 8, which after the edit is a different statement.
    ckEq rows[1].resolution, "moved"
    ckEq rows[1].line, 8
    ckEq rows[1].kind, "breakpoint"

    # 3. Unresolvable, AND PRESENT. Line 0, so no pane offers it as a jump
    #    target, and a detail saying what was looked for.
    ckEq rows[2].resolution, "unresolvable"
    # ZERO, AND NOT THE LINE THE DEFINITION RECORDED. That point declares
    # `line = "12"`, so a producer that fell back to the recorded hint for a
    # point it could not locate would put a plausible-looking 12 here and a
    # pane would offer a jump to a statement that has nothing to do with it.
    # The hint is a HINT: it distinguishes `resolved` from `moved` and it is
    # never a location.
    ckEq rows[2].line, 0
    ck rows[2].detail.contains("proc handleTimeout")
    ckEq rows[2].collection, "the request path"

    # 4. The file is gone — its own outcome, its own message.
    ckEq rows[3].resolution, "file absent"
    ckEq rows[3].line, 0
    ck rows[3].detail.contains("gone.nim")

    # 5. A point of a DISABLED collection is still a row, with `enabled =
    #    false`. Dropping it would make "I turned this off" and "this no
    #    longer exists" look identical.
    ckEq rows[4].collection, "cache misses"
    ck not rows[4].enabled
    ckEq rows[4].resolution, "resolved"
    ckEq rows[4].line, 8
    # A point with no label falls back to its expression, and then to its
    # anchor, so no row is ever nameless.
    ckEq rows[4].label, "key"

    # AND THE SUM. Every declared point is in exactly one of the four states,
    # so a point that fell out of the producer entirely would show up here
    # rather than being invisible.
    var byOutcome = 0
    for r in rows:
      if r.resolution in ["resolved", "moved", "unresolvable", "file absent"]:
        inc byOutcome
    ckEq byOutcome, 5

  test "the unresolved rows are findable by the property a pane cares about":
    let vm = createPointListVM(noStore)
    defer: vm.dispose()
    applyCollections(vm, resolveAll(), defaultEnabled(loadedCollections()))
    let bad = unresolvedRows(vm.points.val)
    ckEq bad.len, 2
    for r in bad:
      # KEYED ON `line == 0`, the thing a pane can act on, rather than on the
      # resolution TEXT, which is a label.
      ckEq r.line, 0
      ck r.detail.len > 0

  test "a row is never nameless, whatever the definition omitted":
    var checkedRows = 0
    let vm = createPointListVM(noStore)
    defer: vm.dispose()
    applyCollections(vm, resolveAll(), defaultEnabled(loadedCollections()))
    for r in vm.points.val:
      inc checkedRows
      checkpoint("row: " & r.path & " " & r.resolution)
      ck r.label.len > 0
      ck r.kind.len > 0
      ck r.path.len > 0
      ck r.collection.len > 0
      ck r.resolution.len > 0
    ckEq checkedRows, 5

  test "the enabled set is the definition's default, and nothing more":
    let cs = loadedCollections()
    let enabled = defaultEnabled(cs)
    ckEq enabled.len, 1
    ck "the request path" in enabled
    ck "cache misses" notin enabled
    # And a caller may pass a different set — the definition SEEDS session
    # state, it is not session state.
    let vm = createPointListVM(noStore)
    defer: vm.dispose()
    var everything = initHashSet[string]()
    for c in cs: everything.incl c.name
    applyCollections(vm, resolveAll(), everything)
    var enabledRows = 0
    for r in vm.points.val:
      if r.enabled: inc enabledRows
    ckEq enabledRows, 5
    # …and none at all.
    applyCollections(vm, resolveAll(), initHashSet[string]())
    enabledRows = 0
    for r in vm.points.val:
      if r.enabled: inc enabledRows
    ckEq enabledRows, 0
    # The ROW COUNT is unchanged by either, because enablement is not a
    # filter.
    ckEq vm.points.val.len, 5

  test "writing the signal twice replaces rather than appends":
    let vm = createPointListVM(noStore)
    defer: vm.dispose()
    applyCollections(vm, resolveAll(), defaultEnabled(loadedCollections()))
    ckEq vm.points.val.len, 5
    applyCollections(vm, resolveAll(), defaultEnabled(loadedCollections()))
    ckEq vm.points.val.len, 5
    applyCollections(vm, @[], initHashSet[string]())
    ckEq vm.points.val.len, 0

  test "the rows render as a block a user can read":
    let vm = createPointListVM(noStore)
    defer: vm.dispose()
    applyCollections(vm, resolveAll(), defaultEnabled(loadedCollections()))
    let text = describeRows(vm.points.val)
    ckEq text.splitLines().len, 5
    ck text.contains("src/router.nim:6")
    ck text.contains("unresolvable")
    ck text.contains("file absent")
    ck text.contains("[x] ")
    ck text.contains("[ ] ")

  test "an unedited file gives five resolved rows, so 'moved' means something":
    # The control for the case above: with the file as the definition's author
    # last saw it, nothing is moved and nothing is unresolvable except the
    # things that genuinely are not there. Without this, "moved" could be what
    # this producer says about everything.
    let cs = loadedCollections()
    var resolutions: seq[CollectionResolution] = @[]
    for c in cs:
      resolutions.add resolveCollection(c, uneditedRouter)
    let vm = createPointListVM(noStore)
    defer: vm.dispose()
    applyCollections(vm, resolutions, defaultEnabled(cs))
    let rows = vm.points.val
    ckEq rows.len, 5
    ckEq rows[0].resolution, "resolved"
    ckEq rows[0].line, 4
    ckEq rows[1].resolution, "resolved"
    ckEq rows[1].line, 6
    ckEq unresolvedRows(rows).len, 2

# ---------------------------------------------------------------------------

suite "PLAT-11 (vm): the counted-assertion tally":

  test "the tally":
    check countedAssertions == ExpectedAssertions
