## request_span_languages.nim
##
## RS-M12 — the language matrix of the Request Panel, as data.
##
## RS-M5..RS-M10 each added ONE language row: a recorder that emits
## web-request spans into a ``.ct`` container, a demo web app, a
## ``record-request-panel-fixture`` recipe and a checked-in fixture under
## ``fixtures/``.  Each row also has its own ViewModel test that knows that
## language's session by heart.
##
## This module is the *registry* those six rows never had: one place that says
## which recorder produced which fixture, what every recorder is REQUIRED to
## do, and — separately and explicitly — what each one is ALLOWED to do
## differently, with the reason.  Two tests consume it:
##
## * ``request_span_conformance_test.nim`` runs the shared assertion set over
##   every fixture and asserts it against this declaration, so a metadata
##   regression in any single recorder fails loudly and centrally;
## * ``no_sidecar_manifests_test.nim`` drives a real recording per language
##   and asserts no sidecar manifest is produced.
##
## Keeping the declaration here rather than inside either test is what makes
## the two agree on what the matrix *is*: adding a seventh language is one
## entry in ``LanguageRows`` plus a fixture, and both tests pick it up.
##
## It is deliberately NOT a ``*_test.nim`` file, so ``just test-vm-native`` /
## ``just test-vm-js`` do not try to run it as a suite.
##
## ## Regenerating a fixture
##
## ``contiguousRows`` and ``concurrentRows`` are exact counts over the
## CHECKED-IN recording, and the BEAM and JavaScript recorders MEASURE those
## bits from the ranges the scheduler actually produced.  Re-recording a
## fixture can therefore legitimately change them by one or two — the same run
## on the same machine gave the Elixir session six contiguous rows once and
## seven another time.  That is not a reason to soften the assertion to a
## range: the fixture is committed precisely so the numbers are stable, and a
## regeneration is exactly the moment a human should look at what changed.
## Update the count here, and say in the commit which recording it came from.

import std/os

type
  SourceFidelity* = enum
    ## How far a row's ``start_step`` resolves — which is what a double-click
    ## in the Request Panel actually lands on.
    sfHandlerColumnAware
      ## The writer opted into column-aware steps, so the container carries
      ## the ``paths.dat`` line-length tables and
      ## ``decodeGlobalPositionIndex`` resolves the step to a ``(file, line)``
      ## of the recorded application.
    sfHandlerLineOnly
      ## Column-UNAWARE writer: ``decodeGlobalPositionIndex`` refuses the
      ## container and a step's ``global_position_index`` is the writer's
      ## line-only encoding (``DefaultLinesPerFile`` lines per path).  That is
      ## what ``ct print`` reconstructs, so a test resolves it the way the
      ## shipped CLI does — and still lands in the application's source.
    sfOrderedCoordinateOnly
      ## The container HAS a step stream, but a request's range is made of
      ## thread events rather than per-line application steps, so it carries
      ## no position of its own.  The seek is still a real, distinct, ordered
      ## coordinate of the recording; it is just not a line the user wrote.
    sfNoStepStream
      ## The container carries no ``steps.dat`` at all.  ``start_step`` /
      ## ``end_step`` are GEIDs — positions in the recording's own event
      ## ordering.

  LanguageRow* = object
    ## One row of the matrix: where its fixture is, which repo produced it,
    ## and exactly what its recorder must do and may differ on.
    id*: string                   ## short id, used to prefix every diagnostic
    fixtureDir*: string
    containerFile*: string
    recorderRepo*: string         ## sibling repo holding the recorder
    fixtureRecipeArgs*: seq[string]
      ## extra arguments ``just record-request-panel-fixture <OUT>`` needs for
      ## this repo (framework / schedule selectors), after ``OUT``.
    framework*: string            ## the ``framework`` metadata value
    rows*: int                    ## settled ``web-request`` spans

    # --- declared differences, each with the reason it is legitimate -------
    publishesOpenRecords*: bool
    openRecordsNote*: string
    emitsRoute*: bool
    routeNote*: string
    responseSizeAlwaysPresent*: bool
    responseSizeNote*: string
    emitsRemoteAddr*: bool
    errorMessageRows*: int
    errorMessageNote*: string
    requiredExtraKeys*: seq[string]
    forbiddenKeys*: seq[string]
    contiguousRows*: int
    concurrentRows*: int
    structuralNote*: string
    slowRowFloorMs*: int
    durationNote*: string
    fidelity*: SourceFidelity
    handlerSourceSuffix*: string  ## only meaningful for the handler fidelities
    fidelityNote*: string

const
  DiscoveryModeKey* = "discovery.mode"
    ## The one key no *managed* recorder may emit: it says the span was
    ## reconstructed from the recording's own syscall payloads rather than
    ## published by a middleware running inside the recorded process.

  BeamKeys* = @["beam.pid", "beam.thread_id"]

  RequiredMetadataKeys* = ["http.method", "http.url", "http.status_code",
                           "http.duration_ms"]
    ## ``codetracer-specs/Trace-Files/CTFS-Request-Span-Streams.md``
    ## § "Well-known metadata keys", the rows marked Required = yes.  Every
    ## recorder must emit all four on every settled web-request span.

  SidecarNames* = ["session_manifest.jsonl", "codetracer_spans.jsonl"]
    ## The two sidecar artifacts RS-M12 retires.  The read-only shim in
    ## ``src/db-backend/src/request_spans.rs`` still PARSES them, so sessions
    ## recorded before the campaign stay openable; what must no longer happen
    ## is a recorder WRITING one.

  SidecarOptInEnv* = "CODETRACER_SPAN_MANIFEST"
    ## The environment variable that used to switch the write path back on
    ## after RS-M5/RS-M6 made it opt-in.  ``no_sidecar_manifests_test.nim``
    ## sets it deliberately and requires that nothing appears anyway — which
    ## is a proof that the write path is GONE, not merely defaulted off.

  LanguageRows*: array[6, LanguageRow] = [
    LanguageRow(
      id: "python", fixtureDir: "python_flask", containerFile: "serve.ct",
      recorderRepo: "codetracer-python-recorder",
      fixtureRecipeArgs: @["flask"],
      framework: "flask", rows: 8,
      publishesOpenRecords: true,
      openRecordsNote: "the WSGI middleware publishes on request arrival",
      emitsRoute: true, routeNote: "werkzeug's matched rule",
      responseSizeAlwaysPresent: false,
      responseSizeNote:
        "_metadata() omits the key when the response reports no length " &
        "(the 304)",
      emitsRemoteAddr: true,
      errorMessageRows: 1,
      errorMessageNote: "only /api/boom raises",
      requiredExtraKeys: @[], forbiddenKeys: @[DiscoveryModeKey],
      contiguousRows: 8, concurrentRows: 0,
      structuralNote: "one wsgiref worker serving one request at a time",
      slowRowFloorMs: 40,
      durationNote: "/api/reports/slow sleeps ~50 ms inside its handler",
      fidelity: sfHandlerColumnAware,
      handlerSourceSuffix: "web/flask/app.py",
      fidelityNote: "column-aware writer; seeks land in the Flask app"),
    LanguageRow(
      id: "ruby", fixtureDir: "ruby_sinatra", containerFile: "ruby.ct",
      recorderRepo: "codetracer-ruby-recorder",
      fixtureRecipeArgs: @["sinatra"],
      framework: "sinatra", rows: 8,
      publishesOpenRecords: true,
      openRecordsNote: "the Rack middleware publishes on request arrival",
      emitsRoute: true, routeNote: "sinatra.route",
      responseSizeAlwaysPresent: false,
      responseSizeNote:
        "the key is omitted for the raising handler and for the 304",
      emitsRemoteAddr: true,
      errorMessageRows: 1,
      errorMessageNote: "only /api/boom raises",
      requiredExtraKeys: @[], forbiddenKeys: @[DiscoveryModeKey],
      contiguousRows: 8, concurrentRows: 0,
      structuralNote: "one Rack worker serving one request at a time",
      slowRowFloorMs: 40,
      durationNote: "/api/reports/slow sleeps ~50 ms inside its handler",
      fidelity: sfHandlerLineOnly,
      handlerSourceSuffix: "web/sinatra/app.rb",
      fidelityNote:
        "the Ruby recorder does not opt into column-aware steps, so steps " &
        "resolve through ct print's line-only reconstruction"),
    LanguageRow(
      id: "php", fixtureDir: "php_builtin", containerFile: "app.ct",
      recorderRepo: "codetracer-php-recorder",
      fixtureRecipeArgs: @[],
      framework: "plain", rows: 8,
      publishesOpenRecords: true,
      openRecordsNote:
        "PHP_RINIT publishes the open record, PHP_RSHUTDOWN settles it",
      emitsRoute: true,
      routeNote: "annotated by the demo router through codetracer_span_annotate",
      responseSizeAlwaysPresent: true,
      responseSizeNote:
        "ct_span_settle() emits the key on every span, 0 for the 304",
      emitsRemoteAddr: true,
      errorMessageRows: 1,
      errorMessageNote: "only /api/boom throws",
      requiredExtraKeys: @[], forbiddenKeys: @[DiscoveryModeKey],
      contiguousRows: 8, concurrentRows: 0,
      structuralNote:
        "one worker holding ONE recording for all eight requests — the " &
        "change RS-M7 made",
      slowRowFloorMs: 40,
      durationNote: "/api/reports/slow sleeps ~50 ms inside its handler",
      fidelity: sfHandlerLineOnly,
      handlerSourceSuffix: "web/app.php",
      fidelityNote:
        "the PHP extension registers plain (path, line) steps, so steps " &
        "resolve through ct print's line-only reconstruction"),
    LanguageRow(
      id: "elixir", fixtureDir: "elixir_plug", containerFile: "app.ct",
      recorderRepo: "codetracer-beam-recorder",
      fixtureRecipeArgs: @["plug"],
      framework: "plug", rows: 12,
      publishesOpenRecords: true,
      openRecordsNote:
        "the Plug opens the span on entry and settles it from before_send",
      emitsRoute: true, routeNote: "the Plug.Router path pattern",
      responseSizeAlwaysPresent: true,
      responseSizeNote: "stop_metadata/3 emits all four keys unconditionally",
      emitsRemoteAddr: false,
      errorMessageRows: 0,
      errorMessageNote:
        "the Plug has no error hook: /boom is answered 500 by " &
        "Plug.ErrorHandler, which the middleware only ever sees as a status",
      requiredExtraKeys: BeamKeys, forbiddenKeys: @[DiscoveryModeKey],
      contiguousRows: 7, concurrentRows: 4,
      structuralNote:
        "MEASURED by the replay pass over the recorded ranges: the " &
        "four-request rendezvous cohort genuinely overlaps, and one further " &
        "row has another BEAM process's events interleaved into its range",
      slowRowFloorMs: 400,
      durationNote:
        "the cohort blocks ~3.3 s in the barrier and /slow sleeps ~400 ms",
      fidelity: sfOrderedCoordinateOnly,
      handlerSourceSuffix: "",
      fidelityNote:
        "instrument_erlang_sources only instruments .erl, so an Elixir app " &
        "recorded through `mix run` reaches the container as call/return " &
        "records and a span's step range holds only the thread events that " &
        "bracket it"),
    LanguageRow(
      id: "js", fixtureDir: "js_express", containerFile: "index.ct",
      recorderRepo: "codetracer-js-recorder",
      fixtureRecipeArgs: @["sequential"],
      framework: "express", rows: 7,
      publishesOpenRecords: true,
      openRecordsNote: "the Express middleware publishes on entry",
      emitsRoute: true, routeNote: "the matched Express route pattern",
      responseSizeAlwaysPresent: true,
      responseSizeNote: "settle() emits all four keys unconditionally",
      emitsRemoteAddr: false,
      errorMessageRows: 1,
      errorMessageNote:
        "codetracerExpressErrors() saw only /api/boom throw",
      requiredExtraKeys: @[], forbiddenKeys: @[DiscoveryModeKey],
      contiguousRows: 5, concurrentRows: 0,
      structuralNote:
        "MEASURED from the event loop: the POST (whose body parser awaits) " &
        "and the awaiting /api/reports/slow handler each resume on a " &
        "different async context inside their own range, so neither is an " &
        "uninterrupted run of one exec stream",
      slowRowFloorMs: 40,
      durationNote: "/api/reports/slow awaits ~50 ms",
      fidelity: sfHandlerColumnAware,
      handlerSourceSuffix: "web/express/app.js",
      fidelityNote:
        "column-aware writer, and node_modules is not instrumented, so a " &
        "range is made of real per-line steps of app.js"),
    LanguageRow(
      id: "native", fixtureDir: "native_nginx", containerFile: "nginx.ct",
      recorderRepo: "codetracer-native-recorder",
      fixtureRecipeArgs: @[],
      framework: "nginx", rows: 5,
      publishesOpenRecords: false,
      openRecordsNote:
        "the spans are DISCOVERED by a post-pass over the recorded " &
        "recv/writev payloads; by the time it runs no request is in flight, " &
        "so there is nothing to publish open",
      emitsRoute: false,
      routeNote:
        "an nginx location block is not a route pattern the discoverer can " &
        "read off the wire",
      responseSizeAlwaysPresent: true,
      responseSizeNote:
        "the bytes nginx actually wrote, from the writev capture",
      emitsRemoteAddr: false,
      errorMessageRows: 0,
      errorMessageNote: "nothing in nginx reports an application error",
      requiredExtraKeys: @[DiscoveryModeKey], forbiddenKeys: @[],
      contiguousRows: 5, concurrentRows: 0,
      structuralNote:
        "the matcher follows one socket conversation on one thread, and " &
        "concurrency is recomputed from GEID-range overlap — a " &
        "non-threaded worker never had two requests in flight",
      slowRowFloorMs: 0,
      durationNote:
        "meta.dat reports tickSource: none, so the wall times come from " &
        "nginx's own vDSO time(2) readings at ONE-SECOND resolution: a " &
        "sub-second request truthfully has duration 0, and fabricating a " &
        "number the recording does not contain would be worse",
      fidelity: sfNoStepStream,
      handlerSourceSuffix: "",
      fidelityNote: "a ct-mcr container carries no steps.dat at all"),
  ]

proc workspaceRoot*(): string =
  ## ``<workspace>/codetracer/src/tests/gui/tests/request-panel`` -> the
  ## workspace directory that holds the recorder siblings.
  result = currentSourcePath.parentDir
  for _ in 0 .. 5:
    result = result.parentDir

proc fixturesRoot*(): string =
  currentSourcePath.parentDir / "fixtures"

proc sidecarsUnder*(root: string): seq[string] =
  ## Every sidecar artifact anywhere under ``root``.
  if not dirExists(root): return
  for path in walkDirRec(root, yieldFilter = {pcFile, pcLinkToFile}):
    if path.extractFilename in SidecarNames:
      result.add(path)
