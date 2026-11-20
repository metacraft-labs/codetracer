## The omnibox result commands stories' viewmodel constructors.
##
## A story of the `agent-harbor-results` surface (declared in
## `codetracer_stories.nim`) is a `ResultCommandsVM` built by
## `createResultsStoryVM` over the story's fixture, and the production view
## `isonim_agent_harbor_results_view` rendered over it in the caption bar of
## the window the composer stories show: `src/shield.nr` stopped at line 7.
##
## Every story is a moment of the CTF-P2L project (`layout_story_data.nim`,
## the invented `noir-space-ship` repository; P2c study D49):
##
## - FILES are the repository's files;
## - SYMBOLS and PROGRAM TEXT are read from the story program's source at the
##   revision the window replays (`test-programs/noir_space_ship`,
##   `review_story_data.storyShieldSourceBefore`), so a row's line is the
##   line the editor shows;
## - AGENT HARBOR SESSIONS are the project's sessions at the moment the
##   window shows (`projectWorkingSet`), matched by their task and what they
##   last said, as Agent Harbor's search matches "prompt, messages or files";
## - Agent Harbor's discovery, its rows and the rich rows' boxes are
##   invented in Agent Harbor's shapes (agent-harbor `specs/Input-Commands.md`),
##   as is the extension `Spec index` and the CodeTracer extension `Design
##   notes`.
##
## No provider and no Agent Harbor search is wired yet, and the prototypes
## never reach a server, so each provider is a `ScriptedSearchProvider` and
## Agent Harbor a `ScriptedCommandSource` (the seams' own implementations);
## every state is reached by driving the viewmodel as an operator would
## (typing, moving, opening), never by setting its fields.

import std/strutils
import nim_agents_isonim_viewmodels/agent_harbor/[result_commands_vm, records]
import ./layout_story_data
import ./review_story_data

export result_commands_vm

const
  resultsFixtures* = ["search-partial", "search-final", "search-failed",
    "search-no-symbols", "search-none", "search-long", "search-group",
    "search-superseded", "ah-commands", "ah-search", "ah-unknown",
    "ah-unreachable", "ah-extension", "rich-rows", "text-fallback",
    "opened-outside", "at-completion", "slash-completion"]
    ## Every fixture an `agent-harbor-results` story may name.

  ProjectFiles* = ["src/main.nr", "src/shield.nr", "src/tests.nr", "Nargo.toml",
                   "Prover.toml", "fixtures/positive_field.toml",
                   "fixtures/negative_field.toml"]
    ## The invented repository's files.
  StoryAgents* = ["Claude", "Codex", "Grok", "Opencode", "Antigravity"]
    ## The agents a launch or an `@` offers: the five agent kinds the real
    ## fleet snapshot runs, by their products' own names (P2c study D38).
  StoryWorkflows* = ["nargo-test", "record-failing-test", "review-change"]
  StoryCapabilities* = ["research", "think", "stream"]
  WindowMoment = "debug-failing-test"
    ## The moment the window shows: the clamp session running.
  Dot = " \xC2\xB7 "

  MainSource = staticRead("../../../test-programs/noir_space_ship/src/main.nr")

  Discovery = """{"commands": [
    {"id": "search", "aliases": ["s"], "title": "Search sessions",
     "description": "Sessions whose prompt, messages or files match the text",
     "kind": "results", "argument": {"placeholder": "words or key:value filters"},
     "surfaces": ["launcher", "webui", "tui", "external"], "source": "builtin"},
    {"id": "search-chats", "aliases": ["sc"], "title": "Search chats",
     "description": "Web chats whose history matches the text, with key:value filters",
     "kind": "results", "surfaces": ["launcher", "webui", "external"], "source": "builtin"},
    {"id": "specs", "aliases": ["sp"], "title": "Search specs",
     "description": "Sections of the project's specifications that mention the text",
     "kind": "results", "surfaces": ["launcher", "webui", "external"],
     "source": "extension:spec-index"}
  ]}"""
    ## Agent Harbor's discovery, in its documented shape: its two built-in
    ## commands and one an extension contributes.

proc sources(): seq[(string, string)] =
  ## The program's files the recording holds, at the replayed revision.
  @[("src/main.nr", MainSource), ("src/shield.nr", storyShieldSourceBefore())]

# ---------------------------------------------------------------------------
# CodeTracer's providers
# ---------------------------------------------------------------------------

proc fileRows(text: string): seq[ResultRow] =
  for f in ProjectFiles:
    if f.matches(text):
      result.add ResultRow(id: f, kind: rkFile, title: f, source: "builtin")

proc identAt(line: string; at: int): string =
  var i = at
  while i < line.len and line[i] in IdentChars:
    result.add line[i]
    inc i

proc symbols(): seq[ResultRow] =
  ## The recorded program's functions, parameters and variables, each where
  ## it is first declared in its file.
  for (path, source) in sources():
    var seen: seq[string]
    let lines = splitLines(source)
    for n, line in lines:
      let at = n + 1
      let s = line.strip
      var k = s.find("fn ")
      if k >= 0 and (k == 0 or s[k - 1] == ' '):
        let name = identAt(s, k + 3)
        if name.len > 0 and ("fn:" & name) notin seen:
          seen.add "fn:" & name
          result.add ResultRow(id: path & "#" & name, kind: rkSymbol, title: name,
                               subtitle: "function", location: path & ":" & $at,
                               source: "builtin")
          # Its parameters: `name: Type` inside the parentheses.
          let open = s.find('(')
          let close = s.find(')', max(0, open))
          if open >= 0 and close > open:
            for part in s[open + 1 ..< close].split(','):
              let p = part.strip
              let colon = p.find(':')
              if colon > 0:
                let param = p[0 ..< colon].strip
                if param.len > 0 and ("v:" & param) notin seen:
                  seen.add "v:" & param
                  result.add ResultRow(id: path & "#" & param, kind: rkSymbol,
                                       title: param, subtitle: "parameter",
                                       location: path & ":" & $at, source: "builtin")
      k = s.find("let ")
      if k == 0:
        var rest = s[4 .. ^1]
        if rest.startsWith("mut "): rest = rest[4 .. ^1]
        let name = identAt(rest, 0)
        if name.len > 0 and ("v:" & name) notin seen:
          seen.add "v:" & name
          result.add ResultRow(id: path & "#" & name, kind: rkSymbol, title: name,
                               subtitle: "variable", location: path & ":" & $at,
                               source: "builtin")

proc symbolRows(text: string): seq[ResultRow] =
  for s in symbols():
    if s.title.matches(text): result.add s

proc programTextRows(text: string): seq[ResultRow] =
  ## Every line of the program that holds the text (`:grep`'s search).
  for (path, source) in sources():
    let lines = splitLines(source)
    for n, line in lines:
      if line.strip.len > 0 and line.matches(text):
        result.add ResultRow(id: path & ":" & $(n + 1), kind: rkLine, title: line.strip,
                             location: path & ":" & $(n + 1), source: "builtin")

# ---------------------------------------------------------------------------
# Agent Harbor
# ---------------------------------------------------------------------------

proc statusWord(s: FleetSession): string =
  if s.awaitingInput: "needs input"
  else:
    case s.status
    of fsQueued: "queued"
    of fsFailed: "failed"
    of fsCompleted: "completed"
    else: "running"

proc lastSaid(s: FleetSession): string =
  for a in s.recent:
    if a.kind == fakLog: result = a.text.replace("assistant: ", "")

proc summaryBox(s: FleetSession; tests: string): string =
  ## A session's summary as Agent Harbor's search would send it (invented),
  ## in the roles the front-end passes into the box (`--ct-*`).
  "<style>.k{color:var(--ct-caption);font-size:var(--ct-caption-size)}.s{margin-top:4px}" &
    ".t{margin-top:6px;color:var(--ct-success)}.f{color:var(--ct-error)}</style>" &
    "<div class=k>" & s.agentSoftware & Dot & s.branch & Dot & statusWord(s) & "</div>" &
    "<div class=s>" & lastSaid(s) & "</div>" & tests

proc sessionRows(text: string; rich: bool): seq[ResultRow] =
  ## The project's sessions whose task or last words hold the text.
  let now = int64(1_763_000_000_000)
  for s in projectWorkingSet(WindowMoment, now).snapshot.sessions:
    if not (s.prompt.matches(text) or lastSaid(s).matches(text)): continue
    # Matched by what it last said: that line is the row's excerpt, so the
    # reader sees why it is listed.
    let byMessage = not s.prompt.matches(text)
    var row = ResultRow(id: s.id, kind: rkSession, title: s.prompt,
                        excerpt: (if byMessage: lastSaid(s) else: ""),
                        subtitle: (if s.initiative.len > 0: s.initiative else: ProjectRepository) &
                                  Dot & s.agentSoftware & Dot & statusWord(s),
                        url: "agent-harbor://task/" & s.id, source: "builtin",
                        trusted: true)
    if rich:
      # A rich row's text form: its last words, quoted where its box is not
      # drawn (the terminal, GPUI, a host that turned HTML off).
      if row.excerpt.len == 0 and s.id in [ClampSession, DrainedTestSession]:
        row.excerpt = lastSaid(s)
      if s.id == ClampSession:
        row.html = summaryBox(s, "<div class=t>nargo test: 5 passed, " &
                                 "<span class=f>1 failing (shield_never_negative)</span></div>")
        row.htmlHeight = 132
      elif s.id == DrainedTestSession:
        var steps = ""
        for (i, step) in [(1, "Read src/shield.nr"), (2, "Wrote drained_field_fails"),
                          (3, "Ran nargo test: drained_field_fails failed"),
                          (4, "Recorded the failing test"), (5, "Read the recording at pass 5"),
                          (6, "Asked to open the recording in a new tab"),
                          (7, "Waiting for an answer")]:
          steps.add "<li>" & $i & ". " & step & "</li>"
        row.html = summaryBox(s, "<ol style=\"margin:6px 0 0;padding:0;list-style:none;" &
          "line-height:20px\">" & steps & "</ol>")
        row.htmlHeight = 120
    result.add row

proc specRows(text: string; rich: bool): seq[ResultRow] =
  ## The extension `Spec index`'s rows (invented sections, and a URL only
  ## the system can open).
  for (id, title, sub) in [
      ("shield-clamp", "Shield model \xC2\xA7 A hit never takes the shield below zero",
       "spec/Shield-Model.md"),
      ("shield-regen", "Shield model \xC2\xA7 Regeneration stops at the initial shield",
       "spec/Shield-Model.md"),
      ("fixtures", "Fixtures \xC2\xA7 An asteroid field per file", "spec/Fixtures.md")]:
    if not (title.matches(text) or (id == "shield-clamp" and "clamp".matches(text))):
      continue
    result.add ResultRow(id: id, kind: rkSpec, title: title, location: sub,
                         url: "https://specs.noir-space-ship.example/" & id,
                         source: "extension:spec-index")

proc designNoteRows(text: string): seq[ResultRow] =
  ## The CodeTracer extension `Design notes`: a provider of `/search`,
  ## not trusted to run scripts; its box holds one, which is not run.
  if not "clamp".matches(text): return
  @[ResultRow(id: "note-clamp", kind: rkSpec, title: "Why the clamp is in calculate_damage",
              subtitle: "design note", url: "https://notes.noir-space-ship.example/clamp",
              source: "extension:design-notes",
              # Its text form, quoted where the box is not drawn.
              excerpt: "The damage is clamped where it is computed, so every caller " &
                       "sees a damage the shield can absorb.",
              html: "<div style=\"color:var(--ct-caption)\">Decided 2026-11-04</div>" &
                    "<div style=\"margin-top:4px\">The damage is clamped where it is " &
                    "computed, so every caller sees a damage the shield can absorb.</div>" &
                    "<div id=live></div><script>document.getElementById('live')" &
                    ".textContent='Live preview';</script>",
              htmlHeight: 64)]

proc commandRows(command, text: string): seq[ResultRow] =
  case command
  of "search": sessionRows(text, rich = false)
  of "specs": specRows(text, rich = false)
  else: @[]

proc storyCommands(): seq[InputCommand] =
  let d = parseDiscovery(Discovery, [("spec-index", "Spec index")])
  doAssert d.ok, d.error
  d.commands

type StoryProviders = object
  files, symbols, programText: ScriptedSearchProvider
  harbor: ScriptedCommandSource

proc providersFor(rich = false; notes = false): (StoryProviders, seq[SearchProvider]) =
  var s: StoryProviders
  s.harbor = newScriptedCommandSource(storyCommands(),
    proc(command, text: string): seq[ResultRow] =
      if command == "search": sessionRows(text, rich) else: commandRows(command, text),
    "scripted Agent Harbor commands (invented answers)")
  s.files = newScriptedSearchProvider("files", "Files", fileRows)
  s.symbols = newScriptedSearchProvider("symbols", "Symbols", symbolRows)
  s.programText = newScriptedSearchProvider("program-text", "Program text", programTextRows)
  var list: seq[SearchProvider] = @[SearchProvider(s.files), s.symbols, s.programText,
                                    newAgentHarborSearchProvider(s.harbor)]
  if notes:
    list.add newScriptedSearchProvider("design-notes", "Design notes", designNoteRows,
                                       source = "extension:design-notes")
  (s, list)

proc newStoryResults(p: StoryProviders; list: seq[SearchProvider]): ResultCommandsVM =
  result = newResultCommandsVM(list, p.harbor)
  result.agents = @StoryAgents
  result.repositories = @[ProjectRepository]
  result.files = @ProjectFiles
  result.workflows = @StoryWorkflows
  result.capabilities = @StoryCapabilities

proc typeIn(vm: ResultCommandsVM; text: string) =
  ## What the operator typed, keystroke by keystroke as the field delivers
  ## it: each prefix supersedes the one before (the last one is what
  ## stands).
  vm.setInput(text)

proc createResultsStoryVM*(fixture: string): ResultCommandsVM =
  ## The result commands at the moment the fixture names.
  case fixture
  of "search-partial":
    let (p, list) = providersFor()
    p.programText.hold = true
    result = newStoryResults(p, list)
    result.typeIn("/s shield")
  of "search-final":
    let (p, list) = providersFor()
    result = newStoryResults(p, list)
    result.typeIn("/s shield")
  of "search-failed":
    # A query whose rows fit the sheet, so the failed group is in view.
    let (p, list) = providersFor()
    p.harbor.failures = @[("search", "Agent Harbor is not reachable")]
    result = newStoryResults(p, list)
    result.typeIn("/s calculate_damage")
  of "search-no-symbols":
    let (p, list) = providersFor()
    result = newStoryResults(p, list)
    result.typeIn("/s field")
  of "search-none":
    let (p, list) = providersFor()
    result = newStoryResults(p, list)
    result.typeIn("/s warp drive")
  of "search-long", "search-group":
    let (p, list) = providersFor()
    result = newStoryResults(p, list)
    result.typeIn("/s remaining")
    if fixture == "search-group":
      result.showGroup("program-text")
      result.moveSelection(2)
  of "search-superseded":
    let (p, list) = providersFor()
    result = newStoryResults(p, list)
    result.typeIn("/s shield")
    p.programText.hold = true          # slow on the next query
    result.typeIn("/s shield_pct")
  of "ah-commands":
    let (p, list) = providersFor()
    result = newStoryResults(p, list)
    result.typeIn("/ah")
  of "ah-search":
    let (p, list) = providersFor()
    result = newStoryResults(p, list)
    result.typeIn("/ahs shield")
  of "ah-unknown":
    let (p, list) = providersFor()
    result = newStoryResults(p, list)
    result.typeIn("/ah-sessions shield")
  of "ah-unreachable":
    let (p, list) = providersFor()
    p.harbor.unreachable = "GET /api/v1/input-commands failed: connection refused"
    result = newStoryResults(p, list)
    result.typeIn("/ah")
  of "ah-extension":
    let (p, list) = providersFor()
    result = newStoryResults(p, list)
    result.typeIn("/ahsp shield")
  of "rich-rows", "text-fallback":
    let (p, list) = providersFor(rich = true, notes = true)
    result = newStoryResults(p, list)
    if fixture == "text-fallback": result.setHtmlEnabled(false)
    result.typeIn("/s clamp")
  of "opened-outside":
    let (p, list) = providersFor()
    result = newStoryResults(p, list)
    result.typeIn("/ahsp clamp")
    result.openSelected()
  of "at-completion":
    let (p, list) = providersFor()
    result = newStoryResults(p, list)
    result.typeIn("/ai Run drained_field_fails again with @")
  of "slash-completion":
    let (p, list) = providersFor()
    result = newStoryResults(p, list)
    result.typeIn("/ai Check the clamp against the spec and /")
  else:
    raise newException(ValueError, "no results story fixture " & fixture &
                       "; known: " & resultsFixtures.join(", "))
