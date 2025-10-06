import ui_imports, kdom, ../renderer, command_interpreter

proc clear(self: CommandPaletteComponent) =
  self.selected = 0
  self.inputValue = ""
  self.inputPlaceholder = ""
  self.query = nil
  self.results = @[]

proc close(self: CommandPaletteComponent) =
  self.active = false
  redrawAll()
  self.clear()

proc resetCommandPalette(self: CommandPaletteComponent) =
  self.inputField.toJs.value = "".cstring
  self.close()
  data.redraw()

proc commandIsParent(self: CommandPaletteComponent, commandName: cstring): bool =
  if self.interpreter.commands.hasKey(commandName):
    self.interpreter.commands[commandName].kind == ParentCommand
  else:
    return false

proc commandResultView(self: CommandPaletteComponent, queryResult: CommandPanelResult, selected: bool, isEven: bool, i: int, activeCommandName: cstring): VNode =
  let selectedClass = if selected: "command-selected" else: ""
  let evenClass = if isEven: "command-even" else: "command-odd"

  let displayResult = if queryResult.level == NotificationInfo:
      case queryResult.kind:
      of ProgramQuery:
        buildHtml(
          tdiv(class = "command-program-search-result")
        ):
          span(class = "command-program-search-result-line"):
            text $queryResult.codeSnippet.line
          span(class = "command-program-search-result-source"):
            text queryResult.codeSnippet.source
          span(class = "command-program-search-result-value"):
            text queryResult.value

      of TextSearchQuery, SymbolQuery:
        let nameLimit = 40

        var txt =
          if queryResult.value.trim.len <= nameLimit:
            queryResult.valueHighlighted.trim
          else:
            let trimmed = queryResult.valueHighlighted.trim
            var res = ""
            var curr = 0
            var cnt = 0
            var open = false
            while cnt < nameLimit - 3:
              let currStr = ($trimmed)[curr .. ^1]
              if currStr.startsWith("<b>"):
                open = true
                res &= "<b>"
                curr += 3
              elif currStr.startsWith("</b>"):
                open = false
                res &= "</b>"
                curr += 4
              else:
                res &= trimmed[curr]
                cnt += 1
                curr += 1

            if open:
              res &= "</b>"

            res & "..."

        if queryResult.kind == SymbolQuery:
          txt &= ": " & queryResult.symbolKind

        let file =
          if queryResult.file.len <= nameLimit:
            queryResult.file
          else:
            "..." & ($queryResult.file)[^(nameLimit - 3) .. ^1]

        buildHtml(
          tdiv(class = "command-program-search-result")
        ):
          span(class = "command-program-search-result-value"):
            verbatim(txt)
          span(class = "command-program-search-result-location"):
            text file & ":"
            span(class = "command-program-search-result-line"):
              text $queryResult.line

      else:
        buildHtml(verbatim(queryResult.valueHighlighted))

    else:
      let level = toLowerAscii(($queryResult.level)["Notification".len .. ^1])
      buildHtml(tdiv(class = "command-program-{level}")):
        text queryResult.value

  buildHtml(
    tdiv(
      class = "command-result " & selectedClass & " " & evenClass & $(self.inputValue.len),
      onclick = proc =
        self.close()
        self.interpreter.runCommandPanelResult(queryResult)
        self.resetCommandPalette()
    )
  ):
    displayResult

proc changePlaceholder*(self: CommandPaletteComponent) =
  if self.results.len == 0:
    self.inputPlaceholder = cstring("")
  else:
    case self.query.kind:
    of CommandQuery:
      if self.query.expectArgs:
        self.inputPlaceholder = cstring(&"{commandPrefix}{self.query.value}: ")
        if self.query.args.len > 0:
          for result in self.results:
            if ($(result.value.toLowerCase())).startsWith($(self.query.args[0].toLowerCase())):
              self.inputPlaceholder = cstring(&"{commandPrefix}{self.query.value}: {result.value}")
              break
      else:
        for result in self.results:
          if ($(result.value.toLowerCase())).startsWith($(self.query.value.toLowerCase())):
            # Since we are matching in case insensitive way, the found completion
            # may have different casing than the query. Since we are rendering the
            # completion behind the entered query, such difference would produce
            # an ugly rendering mismatches. We fix this by prefixing the found
            # completion with the precisely entered query:
            let completion = self.query.value & result.value.slice(self.query.value.len)
            if self.commandIsParent(result.value):
              self.inputPlaceholder = cstring(&"{commandPrefix}{completion}: ")
            else:
              self.inputPlaceholder = cstring(&"{commandPrefix}{completion}")
            break

    of FileQuery:
      for result in self.results:
        if ($(result.value.toLowerCase())).startsWith($(self.query.value.toLowerCase())):
          self.inputPlaceholder = result.value
          break

    of ProgramQuery:
      discard

    of TextSearchQuery:
      discard

    of SymbolQuery:
      discard # TODO

proc eventuallyClearPlaceholder(self: CommandPaletteComponent, value: cstring) =
  if self.inputPlaceholder != cstring("") and not ($(self.inputPlaceholder)).startsWith($value):
    self.inputPlaceholder = cstring("")
    redrawAll()

proc showResults(self: CommandPaletteComponent) =
  let value = self.inputField.toJs.value.to(cstring)
  self.inputValue = value
  self.query = self.interpreter.parseQuery(value)
  if self.query.kind != ProgramQuery:
    self.results = self.interpreter.autocompleteQuery(self.query)
    self.changePlaceholder()
    self.active = true
    redrawAll()
  else:
    discard

proc onInput(self: CommandPaletteComponent, value: cstring) =
  self.eventuallyClearPlaceholder(value)
  self.showResults()

proc runQuery(self: CommandPaletteComponent) =
  clog "runQuery "

  let value = self.inputField.toJs.value.to(cstring)
  self.inputValue = value
  self.query = self.interpreter.parseQuery(value)

  case self.query.kind:
  of CommandQuery:
    if self.results.len == 0:
      return

    let selectedResult = self.results[self.selected]
    let command = self.interpreter.commands[selectedResult.value]

    case command.kind:
    of ParentCommand:
      let inputValue = cstring(&"{commandPrefix}{selectedResult.value}: ")
      self.inputField.toJs.value = inputValue
      self.onInput(inputValue)
    of ActionCommand:
      self.interpreter.runCommandPanelResult(selectedResult)
      self.close()
    self.resetCommandPalette()

  of FileQuery:
    if self.results.len == 0:
      return

    self.interpreter.openFileQuery(self.results[self.selected])
    self.close()
    self.resetCommandPalette()

  of ProgramQuery:
    clog "search program"

    if self.results.len != 0 and self.prevCommandValue == self.inputValue:
      let selectedResult = self.results[self.selected]
      self.interpreter.runCommandPanelResult(selectedResult)
      self.close()
      self.resetCommandPalette()
    else:
      self.interpreter.searchProgram(self.query.value)

  of TextSearchQuery:
    # should be unreachable. This type is accessible through ProgramQuery
    discard

  of SymbolQuery:
    let selectedResult = self.results[self.selected]
    self.interpreter.runCommandPanelResult(selectedResult)
    self.close()
    self.resetCommandPalette()

  self.prevCommandValue = self.inputValue

proc onTab(self: CommandPaletteComponent) =
  if self.inputPlaceholder != "" and self.inputPlaceholder != self.inputValue:
    self.inputField.toJs.value = self.inputPlaceholder
    self.onInput(self.inputPlaceholder)

method onProgramSearchResults*(self: CommandPaletteComponent, results: seq[CommandPanelResult]) {.async.} =
  clog "onProgramSearchResults commands"
  self.results = results
  self.data.redraw()

method render*(self: CommandPaletteComponent): VNode =
  result = buildHtml(
    tdiv(id = "command-data")
  ):
    tdiv(id = "command-view"):
      tdiv(id = "command-query"):
        input(class = "disabled",
        placeholder = self.inputPlaceholder)
        input(
          `type` = "text",
          id = "command-query-text",
          name = "command-query",
          placeholder = "Navigate to file or run a :command",
          class = "mousetrap",
          autocomplete="off", # https://stackoverflow.com/questions/254712/disable-spell-checking-on-html-textfields
          autocorrect="off",
          autocapitalize="off",
          spellcheck="false",
          onblur = proc =
            data.ui.commandPalette.active = false
            self.resetCommandPalette(),
          onmousedown = proc =
            data.search(SearchFileRealTime, "".cstring),
          oninput = proc(ev: Event, tg: VNode) =
            let value = self.inputField.toJs.value.to(cstring)
            self.onInput(value),
          onkeydown = proc(e: KeyboardEvent, v: VNode) =
            echo "command ", e.keyCode
            if e.keyCode == DOWN_KEY_CODE: # down
              commandSelectNext()
            elif e.keyCode == UP_KEY_CODE: # up
              commandSelectPrevious()
            elif e.keyCode == ENTER_KEY_CODE: # enter
              self.runQuery()
            elif e.keyCode == ESC_KEY_CODE: # escape
              self.resetCommandPalette()
            elif e.keyCode == TAB_KEY_CODE: # tab
              e.preventDefault()
              self.onTab()
        )
        tdiv(class = "custom-tooltip"):
          # TODO: we should build this dynamically from a list of registered short-cuts
          #
          # There are two things to consider:
          #
          #  * The user can change the default bindings, so the shortcuts
          #    here should change as well
          #
          #  * Developers and users can add new bindings independently from
          #    each other. This needs to be done through a facility that
          #    creates a short-cut to a prepopulated command pallete. We
          #    should be able to ask the table of configured short-cuts to
          #    give us all active bindings that active the command pallete
          #    in one way or another.
          text "Navigate to file (ctrl+p) / Run command (alt+p)"

      var resultsClass =
        if self.results.len == 0 and self.inputValue == cstring"":
          "no-results"
        else:
          ""

      tdiv(
        id = "command-results",
        class = resultsClass,
        onmousedown = proc(e: Event, et: VNode) = e.preventDefault()
      ):
        if self.results.len > 0:
          for i, result in self.results:
            commandResultView(self, result, i == self.selected, i mod 2 == 0, i, data.services.search.activeCommandName)
        else:
          tdiv(class = "command-result empty"):
            text "No matching result found."
