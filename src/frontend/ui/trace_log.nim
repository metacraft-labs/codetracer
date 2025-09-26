import
  ui_imports, colors, events, trace, typetraits, strutils,
  datatable,
  ../[ types, communication ],
  ../../common/ct_event

proc refreshTraces(self: TraceLogComponent) =
  if self.table.context.isNil:

    # get the table dom container
    let id = cstring(&"#trace-log-table-{self.id}")
    let element = jqFind(cstring(id))

    if not element.isNil:
      var results: seq[Stop] = @[]

      # get the last trace session results
      if self.service.traceSessions.len > 0:
        for updateId, sessionResults in self.service.traceSessions[^1].results:
          for sessionResult in sessionResults:
            results.add(sessionResult)

          self.traceUpdateID = updateId
      else:
        results = @[]

      self.table.context = element.DataTable(
        js{
          data: results,
          deferRender: true,
          scrollY: 200,
          scroller: true,
          order: @[[0.toJs, (cstring"asc").toJs]],
          colResize: js{
            isEnabled: true,
            saveState: true
          },
          bInfo: false,
          createdRow: rowTimestamp,
          columns: @[
            js{
              className: cstring"direct-location-rr-ticks",
              data: cstring"rrTicks",
              render: proc(rrTicks: int64): cstring =
                renderRRTicksLine(rrTicks, self.data.minRRTicks, self.data.maxRRTicks, "event-rr-ticks-line")
            },
            js{
              className: cstring"trace-location",
              render: proc(content: cstring, t: js, stop: Stop): cstring =
                let path = stop.path
                let tokens = ($path).rsplit("/", 1)
                let filename = if tokens.len == 2: tokens[1] else: $path
                let line = stop.line
                cstring(fmt"{filename}:{line}")
            },
            js{
              className: cstring"trace-function-name",
              data: cstring"functionName"
            },
            js{
              className: cstring"trace-values",
              data: cstring"locals",
              render: proc(data: seq[(cstring, Value)]): cstring =
                var res = cstring""
                for (name, value) in data:
                  if value.kind != types.Error:
                    if value.isLiteral and value.kind == types.String:
                      res.add(value.text & cstring" ")
                    else:
                      res.add(name & cstring"=" & textRepr(value) & cstring" ")
                  else:
                    res.add(name & cstring"=" & cstring"<span class=error-trace>" & value.msg & cstring"</span>")
                    res.add(cstring" ")
                return res
            }
          ]
        }
      )

      self.renderedLength = results.len
      self.table.context.rows().draw()

      # add handler for table redraw event
      self.table.context.on(cstring("draw.dt"), proc(e, show, row: js) =
        discard windowSetTimeout(proc = self.table.updateTableRows(), 100))

      jqFind(cstring(&"{id} tbody")).on(cstring"click", cstring"tr") do (event: js):
        let target = event.target
        let elementEvent = target.parentNode
        let table = self.table
        let elementEventRow = table.context.row(elementEvent)
        let event = cast[ProgramEvent](elementEventRow.data())
        self.api.emit(CtEventJump, event)
        self.api.emit(InternalNewOperation, NewOperation(name: "Trace jump", stableBusy: true))

    else:
      return
  else:
    if self.service.traceSessions.len > 0:
      if self.service.traceSessions[^1].id != self.traceSessionID:
        self.traceSessionID = self.service.traceSessions[^1].id
        # reset traceUpdateID value
        self.traceUpdateID = -1
        # remove rows from the newly calculated tracepoints
        for tracepoint in self.service.traceSessions[^1].tracepoints:
          self.table.removeTracepointResults(tracepoint)
        # redraw datatable
        self.table.context.rows().draw()
        # redraw components
        self.data.redraw()
      else:
        let session = self.service.traceSessions[self.traceSessionID]

        if session.results.hasKey(self.traceUpdateID + 1):
          let results = session.results[self.traceUpdateID + 1]

          if results.len > 0:
            self.table.context.rows.add(results)
            self.table.context.rows().draw()

          self.traceUpdateID += 1
    else:
      return

proc resizeTraceLogHandler(self: TraceLogComponent) =
  self.table.resizeTable()

method render*(self: TraceLogComponent): VNode =
  if kxiMap[cstring("traceLogComponent-" & $self.id)].afterRedraws.len == 0:

    kxiMap[cstring("traceLogComponent-" & $self.id)].afterRedraws.add(proc =
      self.refreshTraces()

      if self.resizeObserver.isNil:
        let componentTab = cast[Node](jq(&"#traceLogComponent-{self.id}"))
        let resizeObserver = createResizeObserver(proc(entries: seq[Element]) =

          for entry in entries:
            let timeout = setTimeout(proc =
              resizeTraceLogHandler(self), 100))

        resizeObserver.observe(componentTab)
        self.resizeObserver = resizeObserver

      # add scroll event listeners to both tables
      jq(&"#traceLogComponent-{self.id} .dataTables_scrollBody").toJs
        .addEventListener(cstring"scroll", proc = self.table.updateTableRows())

      self.table.updateTableRows(redraw = false))

  result = buildHtml(
    tdiv(
      class = componentContainerClass("traceLog")
    )
  ):
    tdiv(class = &"data-table"):
      table(id = fmt"trace-log-table-{self.id}")
    if not self.table.context.isNil:
      tableFooter(self.table)
