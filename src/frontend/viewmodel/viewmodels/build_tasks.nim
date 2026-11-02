## viewmodels/build_tasks.nim — **Build tasks, the task picker and the
## `:build` commands, decided once for every front-end**
## (Build-Output-Pane.md §3.6, §3.11, §3.12, §5.2).
##
## ## Where a task list lives
##
## In the project: `.codetracer/build.yaml` under the folder Edit mode opened
## (§5.2), read again every time a task is asked for, so an edit to the file
## is seen without a restart. A task runs in that folder, or in its `cwd:`
## (relative to the folder). With no such file, a session that knows the
## command its program was built with (the desktop's `trace.compileCommand`,
## from the configuration's `defaultBuild`) offers it as the one task,
## `default` (§5.2's "infers the build command"); with neither there is no task,
## and the picker says how to add one.
##
## ## How `:build <command>` and `:build: <task>` share one omnibox
##
## The COLON after the verb is the whole distinction, and it is the desktop
## palette's own `command: subcommand` grammar:
##
## * `:build` alone runs the default task (§3.12);
## * `:build <command>` runs a free command (the terminal's and GPUI's
##   PLAT-16 verb, unchanged);
## * `:build:` (nothing after it) is the task picker — what `Ctrl+Shift+B`
##   opens (§3.11) — and `:build: tasks` lists the tasks the same way;
## * `:build: stop`, `:build: clear`, `:build: history` act on the pane;
## * `:build: <name>` runs the task called `<name>`. The four words above are
##   the pane's: a task named `stop` is reached from the picker, never by
##   typing its name, and the configuration reader says so (`shadowed`).
##
## ## The picker is the omnibox
##
## `Ctrl+Shift+B` (`build.run`; `Ctrl+B` is the side panels', CUA-Keymap.md)
## opens the omnibox on `BuildTaskQuery` — the default task first, so `Enter`
## runs it — with the tasks and the pane's four commands as its entries
## (`buildTaskEntries`, the omnibox's `omBuildTask` mode). Choosing one is
## `runBuildChoice`; typing a line is `runBuildVerb`. Both act through a
## front-end's `BuildTaskHost`, so what a choice DOES is this module's on every
## front-end and only HOW (a process, a message to the desktop's main process)
## is the front-end's.
##
## ## The problem matcher
##
## The built-in matchers (§3.4) are all applied to every line, in the shared
## scanner (`build_location_parser`): a line is read by whichever matcher
## places a location on it. A task's `problemMatcher` is checked against those
## names (a misspelt one is a configuration error) and shown in the picker;
## `none` turns the task's diagnostics off.
##
## Pure Nim: no filesystem, no process. C and JavaScript backends.

import std/strutils

import ./omnibar_vm

type
  BuildTaskGroup* = enum
    btgBuild = "build"
    btgTest = "test"
    btgNone = "none"

  BuildTask* = object
    name*: string
    command*: string
    problemMatcher*: string
      ## One of `ProblemMatcherNames`, or "" for the automatic choice.
    group*: BuildTaskGroup
    isDefault*: bool
      ## `default: true`.
    cwd*: string
      ## Relative to the project folder ("" the folder itself).
    line*: int
      ## Where it was declared in the file (1-based), 0 for an inferred task.

  BuildTaskConfig* = object
    source*: string
      ## The file the tasks were read from, "" when none.
    tasks*: seq[BuildTask]
    problems*: seq[string]
      ## What the file got wrong, each `<source>:<line>: <what>`. A task with
      ## a problem is not in `tasks`.
    inferred*: bool
      ## The one task is the session's own build command (§5.2), not a file's.

  BuildVerbKind* = enum
    bvkNone = "none"            ## Not a `:build` line.
    bvkRunDefault = "default"   ## `:build`
    bvkRunCommand = "command"   ## `:build <command>`
    bvkRunTask = "task"         ## `:build: <name>`
    bvkPick = "pick"            ## `:build:`, `:build: tasks`
    bvkStop = "stop"            ## `:build: stop`
    bvkClear = "clear"          ## `:build: clear`
    bvkHistory = "history"      ## `:build: history`

  BuildVerb* = object
    kind*: BuildVerbKind
    argument*: string
      ## The command (`bvkRunCommand`) or the task's name (`bvkRunTask`).

  BuildTaskHost* = object
    ## What a front-end does for this module: the HOW of every choice.
    start*: proc(command, workingDirectory, taskName,
                 problemMatcher: string): string
      ## Start `command` in `workingDirectory` as a new build (`taskName` ""
      ## for a free command; `problemMatcher` "none" reads no diagnostics,
      ## `BuildVM.beginBuild`); "" when it started, else why not.
    stop*: proc(): string
      ## Stop the running build; what to say.
    clear*: proc(): string
      ## Clear the current build's output; what to say.
    showHistory*: proc(): string
      ## Bring up the Build Output pane's history picker; what to say.
    openPicker*: proc(): string
      ## Open the omnibox on `BuildTaskQuery`; what to say.
    projectDir*: string
      ## The folder Edit mode opened, which the tasks run in.
    running*: bool
      ## Whether a build is running now (one at a time).

const
  BuildTasksFile* = ".codetracer/build.yaml"
    ## The project's task list (§5.2), relative to the project folder.
  BuildTaskQuery* = ":build: "
    ## What `Ctrl+Shift+B` and `:build: tasks` open the omnibox on.
  BuildVerbWords* = ["stop", "clear", "history", "tasks"]
    ## The words after `:build:` that are the pane's, not a task's.
  ProblemMatcherNames* = ["nim", "gcc", "clang", "rust", "go", "python",
                          "typescript", "noir", "generic", "none"]
    ## §3.4's built-in matchers, and `none`.
  BuildSubcommandDetails*: array[4, string] = [
    "Stop the running build", "Clear the build output",
    "Show an earlier build", "List the build tasks"]
    ## The picker's second column for the four words, in `BuildVerbWords`'
    ## order.
  NoBuildTasksText* = "No build tasks: add " & BuildTasksFile &
                      " to the project (Build-Output-Pane.md §5.2)"
  BuildAlreadyRunningText* = "a build is already running; :build: stop it first"
  DefaultTaskName* = "default"

# ---------------------------------------------------------------------------
# The file
# ---------------------------------------------------------------------------

proc indentOf(s: string): int =
  while result < s.len and s[result] == ' ':
    inc result

proc withoutComment(s: string): string =
  ## The line without a `#` comment (outside quotes; a `#` must follow a space
  ## or start the line, as YAML says).
  var quote = '\0'
  var escaped = false
  for i, ch in s:
    if quote != '\0':
      if escaped: escaped = false
      elif ch == '\\' and quote == '"': escaped = true
      elif ch == quote: quote = '\0'
    elif ch in {'"', '\''} and (i == 0 or s[i - 1] in {' ', ':'}):
      quote = ch
    elif ch == '#' and (i == 0 or s[i - 1] == ' '):
      return s[0 ..< i].strip(leading = false)
  s.strip(leading = false)

proc scalarOf(raw: string; ok: var bool): string =
  ## A YAML scalar: `"…"` (with `\"`, `\\`, `\n`, `\t`), `'…'` (with `''`),
  ## or plain text.
  let v = raw.strip
  ok = true
  if v.len >= 1 and v[0] == '"':
    if v.len < 2 or v[^1] != '"':
      ok = false
      return ""
    var i = 1
    while i < v.len - 1:
      if v[i] == '\\' and i + 1 < v.len - 1:
        case v[i + 1]
        of 'n': result.add '\n'
        of 't': result.add '\t'
        else: result.add v[i + 1]
        i += 2
      else:
        result.add v[i]
        inc i
  elif v.len >= 1 and v[0] == '\'':
    if v.len < 2 or v[^1] != '\'':
      ok = false
      return ""
    result = v[1 ..< v.len - 1].replace("''", "'")
  else:
    result = v

proc splitKey(line: string): tuple[ok: bool; key, value: string] =
  let colon = line.find(':')
  if colon <= 0:
    return (false, "", "")
  (true, line[0 ..< colon].strip, line[colon + 1 .. ^1])

proc boolOf(v: string): tuple[ok, value: bool] =
  case v.toLowerAscii
  of "true", "yes", "on": (true, true)
  of "false", "no", "off": (true, false)
  else: (false, false)

proc parseBuildTasks*(text: string; source = BuildTasksFile): BuildTaskConfig =
  ## `.codetracer/build.yaml` (§3.6):
  ##
  ##     tasks:
  ##       default:
  ##         command: "nim c -o:./build/app src/main.nim"
  ##         problemMatcher: nim
  ##         group: build
  ##         default: true
  ##         cwd: packages/app
  ##
  ## The block YAML of §3.6 and §5.2, read strictly: an unknown key, a task
  ## without a `command`, a value that is not a scalar is a problem with its
  ## line, and the task it is in is left out — a file that half-parsed must not
  ## run the half it understood under the name of the whole.
  result.source = source
  let lines = text.splitLines
  var inTasks = false
  var cur: BuildTask
  var curBad = false
  var have = false
  var taskIndent = -1

  proc problem(r: var BuildTaskConfig; line: int; what: string) =
    r.problems.add source & ":" & $line & ": " & what

  proc flush(r: var BuildTaskConfig) =
    if have:
      if cur.command.strip.len == 0 and not curBad:
        r.problem(cur.line, "task '" & cur.name & "' has no command")
        curBad = true
      if not curBad:
        r.tasks.add cur
    have = false
    curBad = false

  for i, rawLine in lines:
    let n = i + 1
    var lead = 0
    while lead < rawLine.len and rawLine[lead] in {' ', '\t'}:
      inc lead
    if '\t' in rawLine[0 ..< lead] and rawLine.strip.len > 0 and
       not rawLine.strip.startsWith("#"):
      result.problem(n, "indent with spaces, not tabs")
      continue
    let line = withoutComment(rawLine)
    if line.strip.len == 0:
      continue
    let ind = indentOf(line)
    let body = line.strip
    if ind == 0:
      result.flush()
      let (ok, key, value) = splitKey(body)
      if not ok:
        result.problem(n, "expected `tasks:`")
        inTasks = false
      elif key == "tasks":
        if value.strip.len > 0:
          result.problem(n, "`tasks:` holds the tasks on the lines below it")
        inTasks = true
        taskIndent = -1
      else:
        result.problem(n, "unknown key '" & key & "' (the file holds `tasks:`)")
        inTasks = false
      continue
    if not inTasks:
      continue
    if taskIndent < 0:
      taskIndent = ind
    if ind == taskIndent:
      result.flush()
      let (ok, key, value) = splitKey(body)
      var sok: bool
      let name = scalarOf(key, sok)
      if not ok or value.strip.len > 0 or name.len == 0 or not sok:
        result.problem(n, "expected a task's name followed by `:`")
        continue
      cur = BuildTask(name: name, group: btgBuild, line: n)
      have = true
      for prior in result.tasks:
        if prior.name == name:
          result.problem(n, "task '" & name & "' is declared twice")
          curBad = true
      continue
    if ind < taskIndent:
      result.problem(n, "this line is less indented than the tasks")
      continue
    if not have:
      continue
    let (ok, key, rawValue) = splitKey(body)
    if not ok:
      result.problem(n, "expected `key: value` in task '" & cur.name & "'")
      curBad = true
      continue
    var sok: bool
    let value = scalarOf(rawValue, sok)
    if not sok:
      result.problem(n, "unterminated quote in '" & key & "'")
      curBad = true
      continue
    case key
    of "command":
      cur.command = value
    of "problemMatcher":
      if value notin ProblemMatcherNames:
        result.problem(n, "unknown problemMatcher '" & value & "' (one of " &
                       ProblemMatcherNames.join(", ") & ")")
        curBad = true
      cur.problemMatcher = value
    of "group":
      case value
      of "build": cur.group = btgBuild
      of "test": cur.group = btgTest
      of "none": cur.group = btgNone
      else:
        result.problem(n, "unknown group '" & value & "' (build, test or none)")
        curBad = true
    of "default", "isDefault":
      let b = boolOf(value)
      if not b.ok:
        result.problem(n, "`" & key & "` is true or false")
        curBad = true
      cur.isDefault = b.value
    of "cwd":
      cur.cwd = value
    else:
      result.problem(n, "unknown key '" & key & "' in task '" & cur.name &
                     "' (command, problemMatcher, group, default, cwd)")
      curBad = true
  result.flush()
  var defaults = 0
  for t in result.tasks:
    if t.isDefault: inc defaults
  if defaults > 1:
    result.problems.add source & ": " & $defaults &
      " tasks say `default: true`; the first is the default"

proc inferredBuildTasks*(command: string): BuildTaskConfig =
  ## §5.2: no project file, and the session knows the command its program was
  ## built with — the one task, `default`.
  if command.strip.len == 0:
    return BuildTaskConfig()
  BuildTaskConfig(inferred: true, tasks: @[BuildTask(
    name: DefaultTaskName, command: command.strip, group: btgBuild,
    isDefault: true)])

proc loadBuildTasks*(fileText: string; fileFound: bool;
                     inferredCommand = ""): BuildTaskConfig =
  ## The project's task list: the file's when there is one (even an empty or a
  ## broken one — its problems are reported, never replaced by a guess), else
  ## the inferred one.
  if fileFound: parseBuildTasks(fileText)
  else: inferredBuildTasks(inferredCommand)

proc shadowed*(t: BuildTask): bool =
  ## A task whose name is one of the pane's words: `:build: <name>` does the
  ## pane's thing, and the task is reached from the picker.
  t.name in BuildVerbWords

proc defaultTask*(c: BuildTaskConfig): tuple[found: bool; task: BuildTask] =
  ## The task `:build` runs and the picker puts first: the first marked
  ## `default: true`; else the one named `default`; else the only task in the
  ## `build` group.
  for t in c.tasks:
    if t.isDefault:
      return (true, t)
  for t in c.tasks:
    if t.name == DefaultTaskName:
      return (true, t)
  var only = -1
  for i, t in c.tasks:
    if t.group == btgBuild:
      if only >= 0:
        return (false, BuildTask())
      only = i
  if only >= 0: (true, c.tasks[only]) else: (false, BuildTask())

proc findTask*(c: BuildTaskConfig; name: string): tuple[found: bool;
                                                         task: BuildTask] =
  for t in c.tasks:
    if t.name == name:
      return (true, t)
  (false, BuildTask())

proc workingDirectoryOf*(t: BuildTask; projectDir: string): string =
  ## Where the task runs: the project folder, or its `cwd` under it (an
  ## absolute `cwd` as written).
  if t.cwd.len == 0:
    return projectDir
  if t.cwd.startsWith("/") or projectDir.len == 0:
    return t.cwd
  var rel = t.cwd
  while rel.startsWith("./"):
    rel = rel[2 .. ^1]
  if projectDir.endsWith("/"): projectDir & rel else: projectDir & "/" & rel

# ---------------------------------------------------------------------------
# The verbs
# ---------------------------------------------------------------------------

proc parseBuildVerb*(line: string): BuildVerb =
  ## What a command line asks of the build (the module header's grammar).
  var text = line.strip
  if text.startsWith(":"):
    text = text[1 .. ^1].strip(trailing = false)
  if not text.startsWith("build"):
    return BuildVerb(kind: bvkNone)
  let rest = text[5 .. ^1]
  if rest.len == 0 or rest.strip.len == 0 and not rest.startsWith(":"):
    return BuildVerb(kind: bvkRunDefault)
  if rest[0] == ':':
    let word = rest[1 .. ^1].strip
    case word
    of "", "tasks": BuildVerb(kind: bvkPick)
    of "stop": BuildVerb(kind: bvkStop)
    of "clear": BuildVerb(kind: bvkClear)
    of "history": BuildVerb(kind: bvkHistory)
    else: BuildVerb(kind: bvkRunTask, argument: word)
  elif rest[0] in Whitespace:
    BuildVerb(kind: bvkRunCommand, argument: rest.strip)
  else:
    BuildVerb(kind: bvkNone)   # `:builder`, some other word

proc isBuildLine*(line: string): bool =
  parseBuildVerb(line).kind != bvkNone

# ---------------------------------------------------------------------------
# The picker
# ---------------------------------------------------------------------------

proc taskDetail*(t: BuildTask; isTheDefault: bool): string =
  result = t.command
  var notes: seq[string]
  if isTheDefault: notes.add "default"
  if t.group != btgBuild: notes.add $t.group
  if t.problemMatcher.len > 0: notes.add "matcher: " & t.problemMatcher
  if t.cwd.len > 0: notes.add "in " & t.cwd
  if notes.len > 0:
    result.add "  (" & notes.join(", ") & ")"

proc buildTaskEntries*(c: BuildTaskConfig): seq[OmnibarEntry] =
  ## The picker's entries, in the order it lists them with nothing typed: the
  ## default task, the other tasks as the file declares them, then the pane's
  ## four commands. A task's target is `task:<name>`, a command's its word.
  let d = c.defaultTask
  if d.found:
    result.add OmnibarEntry(kind: omBuildTask, label: d.task.name,
                            detail: taskDetail(d.task, true),
                            target: "task:" & d.task.name)
  for t in c.tasks:
    if d.found and t.name == d.task.name:
      continue
    result.add OmnibarEntry(kind: omBuildTask, label: t.name,
                            detail: taskDetail(t, false),
                            target: "task:" & t.name)
  for i, w in BuildVerbWords:
    if w == "tasks":
      continue   # the picker IS the list
    result.add OmnibarEntry(kind: omBuildTask, label: w,
                            detail: BuildSubcommandDetails[i], target: w)

# ---------------------------------------------------------------------------
# Acting
# ---------------------------------------------------------------------------

proc startTask*(host: BuildTaskHost; t: BuildTask): string =
  if host.running:
    return BuildAlreadyRunningText
  if host.start.isNil:
    return "this window cannot run builds"
  let why = host.start(t.command, t.workingDirectoryOf(host.projectDir),
                       t.name, t.problemMatcher)
  if why.len > 0: why else: "running task " & t.name & ": " & t.command

proc runBuildVerb*(host: BuildTaskHost; c: BuildTaskConfig;
                   verb: BuildVerb): string =
  ## A `:build` line, carried out through the host. What to say.
  case verb.kind
  of bvkNone:
    ""
  of bvkRunDefault:
    let d = c.defaultTask
    if d.found:
      host.startTask(d.task)
    elif c.tasks.len == 0:
      NoBuildTasksText
    else:
      # Several tasks and none is the default: the picker chooses.
      if host.openPicker.isNil: "no default build task; :build: <task>"
      else: host.openPicker()
  of bvkRunCommand:
    if host.running:
      BuildAlreadyRunningText
    elif host.start.isNil:
      "this window cannot run builds"
    else:
      let why = host.start(verb.argument, host.projectDir, "", "")
      if why.len > 0: why else: "running " & verb.argument
  of bvkRunTask:
    let f = c.findTask(verb.argument)
    if f.found:
      host.startTask(f.task)
    elif c.tasks.len == 0:
      NoBuildTasksText
    else:
      var names: seq[string]
      for t in c.tasks: names.add t.name
      "no build task '" & verb.argument & "' (" & names.join(", ") & ")"
  of bvkPick:
    if host.openPicker.isNil: "this window has no task picker"
    else: host.openPicker()
  of bvkStop:
    if host.stop.isNil: "this window cannot stop a build"
    elif not host.running: "nothing is running"
    else: host.stop()
  of bvkClear:
    if host.clear.isNil: "" else: host.clear()
  of bvkHistory:
    if host.showHistory.isNil: "this window has no build history"
    else: host.showHistory()

proc runBuildChoice*(host: BuildTaskHost; c: BuildTaskConfig;
                     entry: OmnibarEntry): string =
  ## A picker entry chosen.
  if entry.target.startsWith("task:"):
    runBuildVerb(host, c, BuildVerb(kind: bvkRunTask,
                                    argument: entry.target[5 .. ^1]))
  else:
    runBuildVerb(host, c, parseBuildVerb(":build: " & entry.target))

proc pickerNote*(c: BuildTaskConfig): string =
  ## What a front-end says when the picker opens: the file's problems, or that
  ## there is no task, or nothing.
  if c.problems.len > 0:
    c.problems[0] & (if c.problems.len > 1: " (and " & $(c.problems.len - 1) &
                     " more)" else: "")
  elif c.tasks.len == 0: NoBuildTasksText
  else: ""
