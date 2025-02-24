import ui_imports
import editor
import ../jsstrings

let COMMAND_FUZZY_OPTIONS = FuzzyOptions(
  limit: 20,
  allowTypo: true,
  threshold: -10000,
  all: false)

let SUBCOMMANDS_FUZZY_OPTIONS = FuzzyOptions(
  limit: 20,
  allowTypo: true,
  threshold: -10000,
  all: true)

proc clearEmptyTokens(tokens: var seq[string]): seq[string] =
  var whiteSpaceIndex = tokens.find(cstring(" "))

  while whiteSpaceIndex != -1:
    tokens.delete(whiteSpaceIndex)
    whiteSpaceIndex = tokens.find(cstring(" "))

  var emptyIndex = tokens.find(cstring(""))

  while emptyIndex != -1:
    tokens.delete(emptyIndex)
    emptyIndex = tokens.find(cstring(""))

  return tokens

proc parseCommandQuery(self: CommandInterpreter, query: cstring): SearchQuery =
  var tokens = ($query).split(":", 1).mapIt(it.strip())
  let commandName = tokens[0]
  let expectArgs =
    if tokens.len > 1 and self.commands.hasKey(commandName):
      true
    else:
      false

  tokens = tokens.clearEmptyTokens()

  # get args/subcommands if there are any
  let args: seq[cstring] =
    if tokens.len > 1:
      tokens[1].split(",").mapIt(cstring(it.strip()))
    else:
      @[]

  SearchQuery(
    kind: CommandQuery,
    value: commandName,
    args: args,
    expectArgs: expectArgs)

proc parseFileQuery(self: CommandInterpreter, query: cstring): SearchQuery =
  SearchQuery(
    kind: FileQuery,
    value: query)

func queryMatchesCommand(query: cstring, command: cstring): bool =
  return query.toLowerCase().startsWith(commandPrefix & command)

proc parseQuery*(self: CommandInterpreter, query: cstring): SearchQuery =
  let isProgramSearch = queryMatchesCommand(query, "grep")
  let isSymbolSearch = queryMatchesCommand(query, "sym")
  let isCommand = (not isProgramSearch and not isSymbolSearch) and ($query).startsWith(commandPrefix)

  if isCommand and query.len > 1:
    self.parseCommandQuery(cstring(($query).substr(1)))
  elif isProgramSearch and query.len > 1:
    SearchQuery(kind: ProgramQuery, value: cstring(($query).substr(1)))
  elif isSymbolSearch and query.len > 1:
    SearchQuery(kind: SymbolQuery, value: cstring(($query).substr(1)))
  else:
    self.parseFileQuery(cstring($query))

proc searchProgram*(self: CommandInterpreter, query: cstring) =
  self.data.services.search.searchProgram(query)

proc getSortedFuzzyResults[T](self: CommandInterpreter, query: cstring, collection: seq[T], options: FuzzyOptions = COMMAND_FUZZY_OPTIONS): seq[FuzzyResult] =
  fuzzysort.go(query, collection, options).sorted(
    (x,y) => y.score - x.score)

proc highlightResult(fuzzyResult: FuzzyResult, open: cstring = cstring("<b>"), close: cstring = cstring("</b>")): cstring =
  fuzzysort.highlight(fuzzyResult, open, close)

proc prepareCommandPanelResults(self: CommandInterpreter, kind: QueryKind, results: seq[FuzzyResult]): seq[CommandPanelResult] =
  var queryResults: seq[CommandPanelResult] = @[]

  case kind:
  of CommandQuery:
    for result in results:
      let command = self.commands[result.target]
      let queryResult = CommandPanelResult(
        kind: kind,
        value: command.name,
        valueHighlighted: highlightResult(result))

      if command.kind == ActionCommand:
        queryResult.action = command.action
        queryResult.shortcut = command.shortcut

      queryResults.add(queryResult)

  of FileQuery:
    for result in results:
      queryResults.add(
        CommandPanelResult(
          kind: kind,
          value: result.target,
          valueHighlighted: highlightResult(result),
          fullPath: self.files[result.target]))

  of SymbolQuery:
    for result in results:
      for symbol in self.symbols[$result.target]:
        queryResults.add(
          CommandPanelResult(
            kind: kind,
            value: result.target,
            valueHighlighted: highlightResult(result),
            file: symbol.path,
            line: symbol.line,
            symbolKind: symbol.kind))

  of ProgramQuery:
    discard # should be unreachable: we should directly send results from backend?

  of TextSearchQuery:
    discard # should be unreachable: we should directly send results from backend?

  return queryResults

proc autocompleteQuery*(self: CommandInterpreter, query: SearchQuery): seq[CommandPanelResult] =
  var fuzzyResults: seq[FuzzyResult] = @[]

  case query.kind:
  of CommandQuery:
    if query.expectArgs:
      # prepare search query
      let subcommandSearchQuery =
        if query.args.len > 0:
          query.args[0]
        else:
          cstring(" ")

      # get command object from the interpreter register
      let inputCommand = self.commands[query.value]

      # prepare subcommand to be searched
      # and to be given as an argument to prepareCommandPanelResults() procedure
      let preparedSubcommands =
        inputCommand.subcommands.mapIt(fuzzysort.prepare(it))

      # sort subcommands according to the input argument
      fuzzyResults =
        self.getSortedFuzzyResults(
          subcommandSearchQuery,
          preparedSubcommands,
          SUBCOMMANDS_FUZZY_OPTIONS)
    else:
      fuzzyResults =
        self.getSortedFuzzyResults(query.value, self.commandsPrepared)

  of FileQuery:
    fuzzyResults =
      self.getSortedFuzzyResults(query.value, self.filesPrepared)

  of SymbolQuery:
    if query.value.len > 4:
      fuzzyResults =
        self.getSortedFuzzyResults(($query.value)[4 .. ^1], self.symbolsPrepared)

  of ProgramQuery:
    # shouldn't be called! we should call directly searchProgram for now
    # and wait for its results/autocomplete event
    discard

  of TextSearchQuery:
    # shouldn't be called! we should call directly searchProgram for now
    # and wait for its results/autocomplete event
    discard

  self.prepareCommandPanelResults(query.kind, fuzzyResults)

proc runQueryCommand*(self: CommandInterpreter, res: CommandPanelResult) =
  self.data.actions[self.commands[res.value].action]()

proc openFileQuery*(self: CommandInterpreter, res: CommandPanelResult) =
  self.data.openTab(self.files[res.value], ViewSource)

proc actOnProgramSearchResult*(self: CommandInterpreter, res: CommandPanelResult) =
  echo "# TODO most cases"
  discard

proc runCommandPanelResult*(self: CommandInterpreter, commandResult: CommandPanelResult) =
  case commandResult.kind:
  of CommandQuery:
    self.runQueryCommand(commandResult)

  of FileQuery:
    self.openFileQuery(commandResult)

  of ProgramQuery:
    self.actOnProgramSearchResult(commandResult)

  of TextSearchQuery:
    self.data.openTab(self.files[commandResult.file], ViewSource, line=commandResult.line)

  of SymbolQuery:
    self.data.openTab(self.files[commandResult.file], ViewSource, line=commandResult.line)
