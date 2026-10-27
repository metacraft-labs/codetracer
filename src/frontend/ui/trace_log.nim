## Trace Log Panel — tabular tracepoint-result inspector.
##
## ---------------------------------------------------------------------------
## The pane is the generic view (``viewmodel/views/isonim_trace_log_view.nim``)
## over the session's ``TraceLogVM``, mounted by the panel host
## (``ui/panel_host``) into the container GoldenLayout creates; the host also
## reports the rows it shows (``TraceLogVM.setViewport``), which reads their
## locals by window. The rows are the latest tracepoint run's stops: this
## module turns the trace service's sessions into ``TraceLogEntry`` rows
## whenever its results change (``trace.onTraceResultsChanged``), mounted or
## not. The ``TraceLogComponent`` keeps its identity for the layout.
## ---------------------------------------------------------------------------

import
  ui_imports, strutils,
  ../[ types, communication ],
  ../../common/ct_event

import ./presented_value
from ../viewmodel/store/types as vmtypes import TraceLogEntry
from ../viewmodel/viewmodels/trace_log_vm import TraceLogVM, setEntries
from ../viewmodel/session_vm import SessionViewModel
import ./panel_host
from ./trace import onTraceResultsChanged

# ---------------------------------------------------------------------------
# Legacy → VM translation helpers.
# ---------------------------------------------------------------------------

proc safeStr(s: cstring): string =
  ## Convert a possibly-null cstring to an empty string.  Mirrors the
  ## helper used by request_panel / step_list / repl / low_level_code
  ## — E2E paths can land a null cstring in the legacy record, and a
  ## naive ``$`` would throw inside ``cstrToNimstr``.
  if s.isNil:
    ""
  else:
    $s

proc localsToText(locals: seq[(cstring, Value)]): string =
  ## Mirror of the legacy column-4 renderer in ``trace_log.nim`` (see
  ## the ``data: cstring"locals"`` column definition that was dropped
  ## with ``method render``).  Literal string values render as bare
  ## text (e.g. ``$msg`` arguments to ``log``); error values are
  ## prefixed with ``name=`` and surrounded by an
  ## ``<span class="error-trace">`` marker so CSS can style them; all
  ## other values render as ``name=<the presenter's answer>``.  The IsoNim
  ## view emits this string verbatim into a ``trace-col-locals``
  ## ``<div>`` — CSS handles the colour rules for ``error-trace``.
  ## PLAT-2: THE VALUE HALF IS THE PIPELINE'S; THE ROW SHAPE IS THIS PANE'S.
  ##
  ## `name=<span class="error-trace">msg</span>` used to be built HERE, which
  ## put HTML inside a value: the markup travelled with the string into
  ## `ProgramEvent.content`, through the event log, into a DataTable cell and
  ## out again — and the terminal front-end, which renders the same values,
  ## had no way to strip it. The error is now a `PresentationClass` the
  ## presenter reports (`pcError`), and the span is applied by this pane, which
  ## is the only layer that has a DOM.
  var parts: seq[string] = @[]
  for (rawName, value) in locals:
    let name = safeStr(rawName)
    let presentation = eventLogValue(value)
    if presentation.root.class == pcError:
      parts.add(name & "=<span class=\"error-trace\">" &
                presentation.root.text & "</span>")
    elif (not value.isNil) and value.isLiteral and value.kind == types.String:
      # A `log("…")` argument is the message itself, not `msg="…"`. Kept: it is
      # a fact about what a TRACEPOINT ROW is, not about how a string renders.
      parts.add(safeStr(value.text))
    else:
      parts.add(name & "=" & presentation.root.text)
  parts.join(" ")

proc legacyStopToVm(stop: Stop;
                    minRRTicks, maxRRTicks: int): TraceLogEntry =
  ## Map the legacy ``Stop`` ref-object to the platform-neutral
  ## ``TraceLogEntry`` value type the ViewModel layer consumes.
  TraceLogEntry(
    rrTicks: stop.rrTicks,
    minRRTicks: minRRTicks,
    maxRRTicks: maxRRTicks,
    path: safeStr(stop.path),
    line: stop.line,
    functionName: safeStr(stop.functionName),
    localsText: localsToText(stop.locals),
    # A sweep answers without the locals (Q4): the VM reads the rows' locals
    # by window. A hit that carried them is already read.
    localsLoaded: stop.locals.len > 0,
    eventId: stop.event,
    tracepointId: stop.tracepointId,
  )

proc collectLatestSessionEntries(): seq[TraceLogEntry] =
  ## The latest tracepoint run's stops, as rows. Empty before any run.
  result = @[]
  if data.isNil or data.services.trace.isNil or
     data.services.trace.traceSessions.len == 0:
    return
  let session = data.services.trace.traceSessions[^1]
  let minTicks = data.minRRTicks
  let maxTicks = data.maxRRTicks
  for _, sessionResults in session.results:
    for stop in sessionResults:
      result.add(legacyStopToVm(stop, minTicks, maxTicks))

proc syncTraceLogFromService*() =
  ## Put the latest run's stops in the session's ``TraceLogVM`` — what the
  ## pane shows, whether or not it is mounted.
  let session = panelSession()
  if session.isNil or session.traceLogVM.isNil:
    return
  session.traceLogVM.setEntries(collectLatestSessionEntries())

proc initTraceLogVMFromSession*(vm: TraceLogVM) =
  ## The session's ``TraceLogVM`` is installed: show the runs already made.
  syncTraceLogFromService()

onTraceResultsChanged(syncTraceLogFromService)

method register*(self: TraceLogComponent, api: MediatorWithSubscribers) =
  ## The pane subscribes to nothing: its rows are the session's
  ## ``TraceLogVM``.
  self.api = api
