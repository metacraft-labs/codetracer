import
  ui_imports,
  editor

let
  COMMAND_FUZZY_OPTIONS = FuzzyOptions(
    limit: 20,
    allowTypo: true,
    threshold: -10000,
    all: false
  )
  SUBCOMMANDS_FUZZY_OPTIONS = FuzzyOptions(
    limit: 20,
    allowTypo: true,
    threshold: -10000,
    all: true
  )

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

proc getSortedFuzzyResults(
    self: CommandInterpreter,
    query: cstring,
    collection: seq[cstring],
    options: FuzzyOptions = COMMAND_FUZZY_OPTIONS): seq[FuzzyResult] =
  ## Run ``fuzzysort`` on ``collection`` and return the results sorted by score.
  ##
  ## ``collection`` is provided as raw strings and converted to freshly prepared
  ## ``fuzzysort`` objects on every call. This avoids reusing prepared results
  ## whose internal indexes caused stale highlights between searches.

  let prepared = collection.mapIt(fuzzysort.prepare(it))
  fuzzysort.go(query, prepared, options).sorted((x,y) => y.score - x.score)

proc highlightResult(fuzzyResult: FuzzyResult, open: cstring = cstring("<b>"), close: cstring = cstring("</b>")): cstring =
  ## Return ``fuzzyResult.target`` with the characters at ``fuzzyResult._indexes``
  ## wrapped in the provided ``open`` and ``close`` tags.
  ##
  ## This avoids using ``fuzzysort.highlight`` directly which mutates the
  ## ``FuzzyResult`` instance, leading to stale highlight ranges when the same
  ## prepared result is reused across searches.

  if fuzzyResult.target.len == 0 or fuzzyResult.`"_indexes"`.len == 0:
    return fuzzyResult.target

  var result = newStringOfCap(fuzzyResult.target.len +
                              fuzzyResult.`"_indexes"`.len * (open.len + close.len))
  var last = 0
  for idx in fuzzyResult.`"_indexes"`:
    if idx < 0 or idx >= fuzzyResult.target.len:
      continue
    result.add(($fuzzyResult.target)[last ..< idx])
    result.add($open)
    result.add(($fuzzyResult.target)[idx])
    result.add($close)
    last = idx + 1
  result.add(($fuzzyResult.target)[last ..< fuzzyResult.target.len])
  return result.cstring

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
      # sort subcommands according to the input argument using the raw strings
      fuzzyResults =
        self.getSortedFuzzyResults(
          subcommandSearchQuery,
          inputCommand.subcommands,
          SUBCOMMANDS_FUZZY_OPTIONS)
    else:
      fuzzyResults =
        self.getSortedFuzzyResults(
          query.value,
          self.commands.keys.toSeq())

  of FileQuery:
    fuzzyResults =
      self.getSortedFuzzyResults(
        query.value,
        self.files.keys.toSeq())

  of SymbolQuery:
    if query.value.len > 4:
      fuzzyResults =
        self.getSortedFuzzyResults(
          ($query.value)[4 .. ^1],
          self.symbols.keys.toSeq())

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
