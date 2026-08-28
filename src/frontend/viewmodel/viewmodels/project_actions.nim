## viewmodels/project_actions.nim
##
## VN-M3 — the project's own actions, read rather than invented.
##
## `codetracer-specs/Planned-Features/Noir-Studio.md` §9.3 is unusually
## prescriptive about this, and the prescription is a refusal:
##
##   "**The shape is `tasks.json` and `package.json` scripts**, which is a form
##    developers already understand and which requires the studio to define no
##    schema of its own — the project declares its actions or it does not."
##
##   "**Actions are the project's**, not ours. We surface what a project
##    declares and invent no manifest of our own."
##
## So this module has no opinion about verification, about Noir, or about
## Verno. It reads two file formats developers already write and produces a
## flat list of things the omnibar can run. `verification_vm` then *recognises*
## one of those actions as a Verno invocation, which is an adapter noticing its
## own producer — not a manifest field CodeTracer asked the project to add.
## Delete `verification_vm` and this module still works; delete the project's
## `tasks.json` and CodeTracer offers nothing, which is the correct behaviour
## rather than a gap.
##
## Two consequences worth stating, because both are deliberate:
##
## 1. **No built-in action exists.** There is no `defaultActions()`, no
##    "Verify" entry synthesised for Noir packages. A project with no
##    declaration yields an empty set. Inventing an action would mean
##    inventing the command line to run it with, and a wrong command line
##    surfaced as an IDE feature is worse than no feature.
##
## 2. **A malformed declaration is reported, not skipped.** `problems` carries
##    one line per declaration this module could not use. Silently dropping a
##    task the developer wrote produces the worst bug shape there is: the
##    action they can see in their editor is missing from ours and nothing
##    says why.
##
## Everything here is pure and plain-valued — `string`, `bool`, `seq`, no
## `cstring`, no file access — so it compiles and is asserted on both the C
## (`vm-unit`) and JS (`vm-unit-js`) backends. Reading the files off disk and
## running one of them is a host concern and lives in
## `../host/project_action_runner.nim`.

import std/[json, options, strutils]

import ../store/types

type
  ProjectActionSource* = enum
    ## Which of §9.3's two forms declared this action.
    pasTasksJson = "tasks.json"
    pasPackageJson = "package.json"

  ProjectActionGroup* = enum
    ## VS Code's `group` field, narrowed to the values it defines plus
    ## "unset". Nothing in CodeTracer branches on this; it exists so the
    ## omnibar can sort and label rows the way the project meant them.
    pagNone = ""
    pagBuild = "build"
    pagTest = "test"

  ProjectAction* = object
    ## One runnable action a project declared.
    id*: string
      ## Stable identity, `<source>:<label>`. Used as the omnibar row key and
      ## as the run id, so two runs of the same action are the same row.
    label*: string
      ## What the developer called it. Never rewritten.
    detail*: string
      ## VS Code's `detail`, or the raw script body for a `package.json`
      ## script — in both cases the project's own words.
    command*: string
      ## The executable. For a `package.json` script this is the whole script
      ## line, because npm scripts are shell strings and splitting one
      ## correctly is a shell parser's job, not ours.
    args*: seq[string]
      ## Arguments, verbatim, in order. Empty for `package.json` scripts.
    cwd*: string
      ## `options.cwd` when the task set one, otherwise empty, meaning "the
      ## project root". Not resolved here — resolution needs a filesystem.
    group*: ProjectActionGroup
    isBackground*: bool
      ## The task declared itself long-running. Advisory only: §9.3's process
      ## model treats *every* action as potentially long-running, because a
      ## proof attempt that takes four minutes is not distinguishable up front
      ## from one that takes four seconds.
    source*: ProjectActionSource

  ProjectActionSet* = object
    actions*: seq[ProjectAction]
    problems*: seq[string]
      ## One line per declaration that could not be read. See rule 2 above.

proc `==`*(a, b: ProjectAction): bool {.noSideEffect.} =
  a.id == b.id and a.label == b.label and a.detail == b.detail and
    a.command == b.command and a.args == b.args and a.cwd == b.cwd and
    a.group == b.group and a.isBackground == b.isBackground and
    a.source == b.source

proc commandLine*(action: ProjectAction): string {.noSideEffect.} =
  ## The action as one line, for display and for the `commandLine` field of a
  ## run summary. Quoted only where an argument contains a space, because the
  ## point is to be readable and recognisable, not to be re-parsed.
  result = action.command
  for arg in action.args:
    result.add ' '
    if arg.len == 0 or arg.contains(' '):
      result.add '"' & arg & '"'
    else:
      result.add arg

proc readJson(text, what: string; doc: var JsonNode): string =
  ## Parse, or say why not. Returns "" on success and a problem line
  ## otherwise.
  ##
  ## The two handlers are not belt and braces. On the C backend `parseJson`
  ## raises a Nim `JsonParsingError`, which `CatchableError` catches. On the
  ## JS backend it delegates to `JSON.parse`, whose throw arrives as a
  ## **foreign** exception that no typed Nim handler catches at all — so
  ## without the bare `except` below, a malformed `tasks.json` takes down the
  ## renderer instead of producing a problem line. That is a real defect this
  ## module shipped with until the `vm-unit-js` lane ran the same suite on the
  ## backend the web debugger actually uses.
  try:
    doc = parseJson(text)
    return ""
  except CatchableError as err:
    return what & " is not valid JSON: " & err.msg
  except:
    return what & " is not valid JSON"

proc parseGroup(node: JsonNode): ProjectActionGroup =
  ## VS Code allows `"group": "test"` and
  ## `"group": {"kind": "test", "isDefault": true}`. Both are common in the
  ## wild, so both are read.
  if node.isNil:
    return pagNone
  var raw = ""
  case node.kind
  of JString:
    raw = node.getStr
  of JObject:
    if node.hasKey("kind") and node["kind"].kind == JString:
      raw = node["kind"].getStr
  else:
    return pagNone
  for value in ProjectActionGroup:
    if $value == raw:
      return value
  pagNone

proc parseTasksJson*(text: string): ProjectActionSet =
  ## Read a VS Code `tasks.json`.
  ##
  ## Deliberately tolerant in one direction only: an entry missing the fields
  ## needed to *run* it (a label, a command) is reported as a problem rather
  ## than guessed at, while unknown fields — `problemMatcher`, `presentation`,
  ## `dependsOn` and the rest — are ignored without comment. CodeTracer does
  ## not implement VS Code's task semantics and must not pretend a
  ## `dependsOn` chain was honoured.
  if text.strip().len == 0:
    return ProjectActionSet()
  var doc: JsonNode
  let problem = readJson(text, "tasks.json", doc)
  if problem.len > 0:
    return ProjectActionSet(problems: @[problem])
  if doc.isNil or doc.kind != JObject:
    return ProjectActionSet(problems: @["tasks.json does not contain a JSON object"])
  if not doc.hasKey("tasks"):
    return ProjectActionSet()
  let tasks = doc["tasks"]
  if tasks.kind != JArray:
    return ProjectActionSet(problems: @["tasks.json: `tasks` is not an array"])

  for index, entry in tasks.getElems:
    if entry.kind != JObject:
      result.problems.add "tasks.json: task #" & $index & " is not an object"
      continue
    let label =
      if entry.hasKey("label") and entry["label"].kind == JString: entry["label"].getStr
      else: ""
    if label.len == 0:
      result.problems.add "tasks.json: task #" & $index & " has no `label`"
      continue
    let command =
      if entry.hasKey("command") and entry["command"].kind == JString: entry["command"].getStr
      else: ""
    if command.len == 0:
      result.problems.add "tasks.json: task \"" & label & "\" has no `command`"
      continue

    var args: seq[string] = @[]
    var argsUnreadable = false
    if entry.hasKey("args"):
      let argsNode = entry["args"]
      if argsNode.kind != JArray:
        argsUnreadable = true
      else:
        for arg in argsNode.getElems:
          if arg.kind == JString:
            args.add arg.getStr
          else:
            argsUnreadable = true
            break
    if argsUnreadable:
      # VS Code permits `{"value": ..., "quoting": ...}` argument objects. We
      # do not implement its quoting rules, and running the task with those
      # arguments dropped would run a *different* command than the developer
      # wrote.
      result.problems.add "tasks.json: task \"" & label &
        "\" has arguments CodeTracer cannot read verbatim; not offered"
      continue

    var cwd = ""
    if entry.hasKey("options") and entry["options"].kind == JObject:
      let options = entry["options"]
      if options.hasKey("cwd") and options["cwd"].kind == JString:
        cwd = options["cwd"].getStr

    result.actions.add ProjectAction(
      id: $pasTasksJson & ":" & label,
      label: label,
      detail:
        if entry.hasKey("detail") and entry["detail"].kind == JString: entry["detail"].getStr
        else: "",
      command: command,
      args: args,
      cwd: cwd,
      group: parseGroup(if entry.hasKey("group"): entry["group"] else: nil),
      isBackground:
        entry.hasKey("isBackground") and entry["isBackground"].kind == JBool and
          entry["isBackground"].getBool,
      source: pasTasksJson,
    )

proc parsePackageScripts*(text: string): ProjectActionSet =
  ## Read the `scripts` map of a `package.json`.
  ##
  ## The whole script line becomes `command` with no `args`. npm scripts are
  ## shell strings — `verno fv && echo done` is a legal one — and a naive
  ## whitespace split would turn some of them into commands that are not what
  ## the project wrote. Handing the line to a shell is the host's job.
  if text.strip().len == 0:
    return ProjectActionSet()
  var doc: JsonNode
  let problem = readJson(text, "package.json", doc)
  if problem.len > 0:
    return ProjectActionSet(problems: @[problem])
  if doc.isNil or doc.kind != JObject:
    return ProjectActionSet(problems: @["package.json does not contain a JSON object"])
  if not doc.hasKey("scripts"):
    return ProjectActionSet()
  let scripts = doc["scripts"]
  if scripts.kind != JObject:
    return ProjectActionSet(problems: @["package.json: `scripts` is not an object"])

  for name, body in scripts.pairs:
    if body.kind != JString or body.getStr.strip().len == 0:
      result.problems.add "package.json: script \"" & name & "\" is not a command string"
      continue
    result.actions.add ProjectAction(
      id: $pasPackageJson & ":" & name,
      label: name,
      detail: body.getStr,
      command: body.getStr,
      args: @[],
      cwd: "",
      group: pagNone,
      isBackground: false,
      source: pasPackageJson,
    )

proc collectProjectActions*(tasksJson: string; packageJson: string): ProjectActionSet =
  ## Everything a project declares, in the order §9.3 names the two forms.
  ##
  ## Both are read; neither shadows the other. Two actions can share a label
  ## across the two files and both are offered, distinguished by `id`, because
  ## the alternative is silently hiding one of the developer's own commands.
  let fromTasks = parseTasksJson(tasksJson)
  let fromPackage = parsePackageScripts(packageJson)
  result.actions = fromTasks.actions & fromPackage.actions
  result.problems = fromTasks.problems & fromPackage.problems

proc actionById*(actions: ProjectActionSet; id: string): Option[ProjectAction] {.noSideEffect.} =
  for action in actions.actions:
    if action.id == id:
      return some(action)
  none(ProjectAction)

# ---------------------------------------------------------------------------
# Surfacing — §9.3's "reachable from the omnibar"
# ---------------------------------------------------------------------------

proc matchesQuery*(action: ProjectAction; query: string): bool {.noSideEffect.} =
  ## Substring, case-insensitive, over the label and the command line.
  ##
  ## Not a fuzzy matcher. The palette's existing fuzzy ranking is applied by
  ## the legacy interpreter over its own result set, and re-implementing a
  ## second ranking here would be the bespoke mechanism §9.3 refuses. This is
  ## the filter, and the ordering is the project's own declaration order,
  ## which is the order the developer wrote and can predict.
  if query.len == 0:
    return true
  let needle = query.toLowerAscii
  action.label.toLowerAscii.contains(needle) or
    commandLine(action).toLowerAscii.contains(needle)

proc paletteEntries*(actions: ProjectActionSet;
                     query = ""): seq[CommandPaletteResultEntry] =
  ## The project's actions as omnibar rows.
  ##
  ## `value` is the developer's own label and `snippetSource` is the command
  ## it will run, so the row says what will happen before it happens. Neither
  ## is rewritten: an omnibar that renamed a project's task would make the
  ## action the user picked and the action the project declared two different
  ## things.
  for action in actions.actions:
    if not action.matchesQuery(query):
      continue
    result.add CommandPaletteResultEntry(
      value: action.label,
      valueHighlighted: action.label,
      kind: cprkProjectAction,
      level: cpnlInfo,
      snippetSource: commandLine(action),
    )

proc paletteProblemEntries*(actions: ProjectActionSet):
    seq[CommandPaletteResultEntry] =
  ## The declarations that could not be read, as warning rows.
  ##
  ## They belong in the same list as the actions themselves. A developer
  ## looking for a task they wrote and not finding it needs to be told why in
  ## the place they looked, not in a log.
  for problem in actions.problems:
    result.add CommandPaletteResultEntry(
      value: problem,
      valueHighlighted: problem,
      kind: cprkProjectAction,
      level: cpnlWarning,
    )
