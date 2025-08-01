import
  ../types,
  ui_imports, colors, typetraits, strutils, base64

import ../communication, ../../common/ct_event

var newAnsiUp* {.importcpp: "new AnsiUp".}: proc: js
let ansiUp {.exportc.} = newAnsiUp()

proc splitNewLines(text: cstring): seq[cstring] =
  text.split("\n")

proc ensureLine(self: TerminalOutputComponent) =
  if not self.cachedLines.hasKey(self.currentLine):
    self.cachedLines[self.currentLine] = @[]

proc appendToTerminalLine(self: TerminalOutputComponent, text: cstring, eventIndex: int) =
  self.ensureLine()
  var lineTerminalEvents = self.cachedLines[self.currentLine]

  lineTerminalEvents.add(TerminalEvent(
    text: text,
    eventIndex: eventIndex))

  self.cachedLines[self.currentLine] = lineTerminalEvents

proc addTerminalLine(self: TerminalOutputComponent, text: cstring, eventIndex: int) =
  self.appendToTerminalLine(text, eventIndex)
  self.currentLine += 1

when defined(ctInExtension):
  var terminalOutputComponentForExtension* {.exportc.}: TerminalOutputComponent = makeTerminalOutputComponent(data, 0, inExtension = true)

  proc makeTerminalOutputComponentForExtension*(id: cstring): TerminalOutputComponent {.exportc.} =
    if terminalOutputComponentForExtension.kxi.isNil:
      terminalOutputComponentForExtension.kxi = setRenderer(proc: VNode = terminalOutputComponentForExtension.render(), id, proc = discard)
    result = terminalOutputComponentForExtension

proc getLines(self: TerminalOutputComponent) =
  self.api.emit(CtLoadTerminal, EmptyArg())

proc cacheAnsiToHtmlLines(self: TerminalOutputComponent, eventList: seq[ProgramEvent]) =
  var raw = ""
  let regExPattern = regex("(<span[^>]*>)(.*?)(<\\/span>)")
  var nextLineStart: cstring = ""
  self.cachedEvents = eventList

  for eventIndex, event in eventList:
    var content =
      if event.base64Encoded:
        cstring(decode($event.content))
      else:
        event.content
    var lines: seq[cstring] = @[]

    if content.len > 0:
      let html = cast[cstring](ansiUp.ansi_to_html(content))
      let matches = html.matchAll(regExPattern)
      var startIndex = 0

      if matches.len > 0:
        for match in matches:
          let preMatchText = html.slice(startIndex, match.index)

          # check if there is a text before the html tag
          if preMatchText.len > 0:
            # split it by new line "\n" and check if there is more than one results
            let tokens = preMatchText.split("\\n")

            if tokens.len > 1:
              for j in 0..tokens.len - 2:
                self.addTerminalLine(tokens[j], eventIndex)
              nextLineStart = tokens[^1]
            else:
              self.appendToTerminalLine(nextLineStart & tokens[^1], eventIndex)

          let startTag = match[1]
          let endTag = match[3]
          let text = match[2]
          let tokens = text.split("\\n")

          if tokens.len > 1:
            self.addTerminalLine(
              nextLineStart & startTag & tokens[0] & endTag,
              eventIndex)

            for j in 1..tokens.len - 2:
              self.addTerminalLine(startTag & tokens[j] & endTag, eventIndex)
            nextLineStart = startTag & tokens[^1] & endTag
          else:
            self.appendToTerminalLine(
              nextLineStart & startTag & tokens[^1] & endTag,
              eventIndex)

          startIndex = match.index + match[0].len

        let postMatchText = html.slice(startIndex)

        # check if there is a text after the last html tag
        if postMatchText.len > 0:
          # split it by new line "\n" and check if there is more than one results
          let tokens = postMatchText.split("\\n")

          if tokens.len > 1:
            self.addTerminalLine(nextLineStart & tokens[0], eventIndex)

            for j in 1..tokens.len - 2:
              self.addTerminalLine(tokens[j], eventIndex)

            nextLineStart = tokens[^1]
          else:
            self.appendToTerminalLine(nextLineStart & tokens[^1], eventIndex)
      else:
        if html.len > 0:
          # split it by new line "\n" and check if there is more than one results
          let tokens = html.split("\\n")

          if tokens.len > 1:
            self.addTerminalLine(nextLineStart & tokens[0], eventIndex)

            for j in 1..tokens.len - 2:
              self.addTerminalLine(tokens[j], eventIndex)

            nextLineStart = tokens[^1]
          else:
            if self.isDbBasedTrace: # and tokens[^1] == "\n":
              self.addTerminalLine(nextLineStart & tokens[^1], eventIndex)
            else:
              self.appendToTerminalLine(nextLineStart & tokens[^1], eventIndex)

method onLoadedTerminal*(self: TerminalOutputComponent, eventList: seq[ProgramEvent]) {.async.} =
  self.cacheAnsiToHtmlLines(eventList)

proc onTerminalEventClick(self: TerminalOutputComponent, eventElement: ProgramEvent) =
  self.api.emit(CtEventJump, eventElement)

method onOutputJumpFromShellUi*(self: TerminalOutputComponent, response: int) {.async.} =
  if self.cachedLines[response].len > 0:
    let eventElement = self.cachedEvents[self.cachedLines[response][0].eventIndex]

    self.onTerminalEventClick(eventElement)

proc terminalEventView(self: TerminalOutputComponent, lineEvent: TerminalEvent): VNode =
  let eventElement = self.cachedEvents[lineEvent.eventIndex]
  let rrTicks = eventElement.directLocationRRTicks
  # let focusRRTicks = self.data.services.debugger.location.rrTicks
  # let lineClass =
  #   if rrTicks < focusRRTicks:
  #     "past"
  #   elif rrTicks == focusRRTicks:
  #     "active"
  #   else:
  #     "future"

  buildHtml(
    tdiv(
      # class = &"{lineClass}",
      onclick = proc = self.onTerminalEventClick(eventElement)
    )
  ):
    verbatim lineEvent.text

proc terminalLineView(self: TerminalOutputComponent, i: int, lineEvents: seq[TerminalEvent]): VNode =
  buildHtml(
    tdiv(
      class="terminal-line",
      id = &"terminal-line-{i}"
    )
  ):
    for lineEvent in lineEvents:
      terminalEventView(self, lineEvent)

method render*(self: TerminalOutputComponent): VNode  =
  buildHtml(
    tdiv(class=componentContainerClass("terminal"))
  ):
    pre:
      if self.cachedLines.len() > 0:
        for i, lineEvents in self.cachedLines:
          terminalLineView(self, i, lineEvents)
      else:
        tdiv(class="empty-overlay"):
          text "The current record does not print anything to the terminal."

method register*(self: TerminalOutputComponent, api: MediatorWithSubscribers) =
  self.api = api
  api.subscribe(CtLoadedTerminal, proc(kind: CtEventKind, response: seq[ProgramEvent], sub: Subscriber) =
    discard self.onLoadedTerminal(response)
  )
  api.subscribe(CtUpdatedEvents, proc(kind: CtEventKind, response: seq[ProgramEvent], sub: Subscriber) =
    if self.initialUpdate:
      self.getLines()
      self.initialUpdate = false
  )
  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    self.redraw()
  )
  api.emit(InternalLastCompleteMove, EmptyArg())

# think if it's possible to directly exportc in this way the method
proc registerTerminalOutputComponent*(component: TerminalOutputComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
