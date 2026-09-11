## project_definitions/load.nim — PLAT-11. Composing a repository's
## `.codetracer/` directories into one answer, and keeping the user's own
## definitions out of it.
##
## ## COMPOSITION, WITH THE OVERRIDE RULES STATED (§6)
##
## Project-Definitions.md §6: "**Composable**: a monorepo has definitions per
## package; a nested project inherits and may override, with the override
## rules stated rather than emergent."
##
## The rules, stated:
##
##   1. **Scope depth is the ordering.** A definition file's `scope` is the
##      package directory it sits in, relative to the repository root. A
##      DEEPER scope is NEARER, and nearer wins. Depth is the number of path
##      segments — a total order on a single number, so there is no
##      "which of these two is more specific" question to answer twice.
##   2. **A collection is overridden by NAME.** A nearer `.codetracer/`
##      declaring a collection called "the request path" REPLACES an
##      ancestor's collection of that name entirely; it does not merge the
##      point lists. Merging would produce a collection nobody wrote, whose
##      contents depend on load order, and which neither author could predict
##      by reading their own file.
##   3. **An override is REPORTED** (`pdnCollectionShadowed`), naming both
##      files. §6 asks for the rules to be stated rather than emergent, and a
##      rule whose application is invisible is emergent in practice whatever
##      the document says.
##   4. **Visualiser rules and diff selections are not overridden, they are
##      ORDERED.** A nearer rule ranks ahead of a farther one within the
##      `ptProjectDefinition` tier; §5.4 then breaks remaining ties by
##      specificity and, last, by declaration order — and reports the tie.
##      Rules are not named, so there is no name for an override to key on;
##      ordering is the only coherent composition for them.
##
## ## THE USER'S DEFINITIONS ARE A DIFFERENT FIELD, NOT A LATER ENTRY
##
## §6: "A user's own definitions are separate and not checked in, and never
## silently merged into the project's — otherwise a user's local experiment
## becomes a diff."
##
## So `load` takes the two sets as two arguments and puts them in two fields,
## and it REFUSES a call whose project set contains a `doUser` file or whose
## user set contains a `doProject` one (`pdcOriginMixed`). The separation is
## therefore a checked property of the call rather than a convention the
## caller is trusted to honour — which matters because the one function that
## could merge them is this one, and the check lives inside it.
##
## Every record also carries its own `origin`, so a consumer that deliberately
## looks at both — a pane listing every collection the user can enable —
## still knows which came from where, and can say so.

import std/[algorithm, strutils, tables]

import ./diagnostics
import ./containment
import ./layout
import ./model
import ./parse

func scopeDepth*(scope: string): int =
  ## How nested a definition file is. 0 for the repository root.
  ##
  ## Counted on segments rather than on `'/'` occurrences so an empty scope
  ## and a one-segment scope differ by one rather than by zero, and so the
  ## number matches what `containment` already validated.
  if scope.len == 0: return 0
  result = 1
  for ch in scope:
    if ch == '/': inc result

proc composeInto(files: openArray[DefinitionFile]; origin: DefinitionOrigin;
                 into: var ProjectDefinitions;
                 problems: var seq[ProjectDefinitionProblem]) =
  ## Parse every declarative file of one origin, then apply §6's rules.
  if files.len > MaxDefinitionScopes * declarativeKinds().len:
    problems.add problem(UnknownDefinitionFile, 0, pdcTooManyEntries,
      $files.len & " definition files were offered in one load; the bound is " &
      $(MaxDefinitionScopes * declarativeKinds().len) & " — " &
      $MaxDefinitionScopes & " scopes times " & $declarativeKinds().len &
      " declarative files each. A monorepo larger than that is not refused; " &
      "one LOAD is bounded, so the composition below is bounded by a " &
      "constant rather than by a directory walk")
    return

  # ORDER THE FILES BEFORE PARSING, so the composition rules below see them
  # nearest-last and the shadowing report names the right side as the winner
  # however the caller happened to enumerate the directories. A caller's walk
  # order is not a contract, and depending on it is how "the nearer one wins"
  # becomes "the last one read wins".
  var ordered: seq[DefinitionFile] = @[]
  for f in files: ordered.add f
  ordered.sort(proc (a, b: DefinitionFile): int =
    result = cmp(scopeDepth(a.scope), scopeDepth(b.scope))
    if result == 0: result = cmp(a.scope, b.scope)
    if result == 0: result = cmp(ord(a.kind), ord(b.kind)))

  var collectionOwner = initTable[string, PointCollection]()
  var collectionOrder: seq[string] = @[]

  for f in ordered:
    if f.origin != origin:
      problems.add problem(f.path, 0, pdcOriginMixed,
        "this file is tagged " & (if f.origin == doUser: "'user'" else: "'project'") &
        " and was offered as part of the " &
        (if origin == doUser: "user's" else: "project's") & " set. §6 keeps " &
        "the two apart so a user's local experiment never becomes a diff, " &
        "and the separation is checked here rather than trusted to the caller")
      continue

    if tierOf(f.kind) == dtExecutable:
      # NOT PARSED, NOT READ, NOT RUN. Reported, so a project that ships one
      # is visible rather than silently inert. PLAT-13 owns what happens next.
      problems.add executableTierNotice(f)
      continue

    let sp = if f.scope.len == 0: ppOk else: pathProblem(f.scope)
    if sp != ppOk:
      problems.add problem(f.path, 0, pdcScopeEscapesProject,
        "the package directory this definition was found in is not inside " &
        "the project: " & describe(sp, f.scope) & ". Composition may not " &
        "reach outside the checkout any more than a single path may")
      continue

    var parsed = ProjectDefinitions()
    problems.add parseDefinitionFile(f, parsed)

    for c in parsed.collections:
      if collectionOwner.hasKey(c.name):
        let prev = collectionOwner[c.name]
        if scopeDepth(c.scope) >= scopeDepth(prev.scope):
          # Rule 2 and rule 3: the nearer one replaces the farther one, and
          # the replacement is reported with BOTH files named, because either
          # author may be surprised and neither can see the other's file.
          problems.add problem(c.file, 0, pdnCollectionShadowed,
            "collection '" & c.name & "' here replaces the one declared in '" &
            prev.file & "'. A nearer .codetracer/ overrides an ancestor's " &
            "collection of the same name ENTIRELY rather than merging the " &
            "two point lists — a merged collection is one neither author " &
            "wrote and neither could predict by reading their own file")
          collectionOwner[c.name] = c
        else:
          problems.add problem(c.file, 0, pdnCollectionShadowed,
            "collection '" & c.name & "' here is replaced by the one declared " &
            "in '" & prev.file & "', which is nearer the code")
      else:
        collectionOwner[c.name] = c
        collectionOrder.add c.name

    for v in parsed.visualisers: into.visualisers.add v
    for d in parsed.diffs: into.diffs.add d

  for name in collectionOrder:
    into.collections.add collectionOwner[name]

func rankVisualisers*(rules: seq[VisualiserRule]): seq[VisualiserRule] =
  ## §5.4's ordering WITHIN the project-definition tier: nearer scope first,
  ## then more specific, then declaration order.
  ##
  ## A stable sort on a total comparison, so the result does not depend on the
  ## sort's internals; `algorithm.sort` is stable for `SortOrder.Ascending`
  ## with a full comparator, and the comparator here never returns 0 for two
  ## distinct rules because `order` and `file` break every tie.
  result = rules
  result.sort(proc (a, b: VisualiserRule): int =
    result = cmp(scopeDepth(b.scope), scopeDepth(a.scope))
    if result == 0: result = cmp(specificity(b), specificity(a))
    if result == 0: result = cmp(a.file, b.file)
    if result == 0: result = cmp(a.order, b.order))

func rankDiffs*(selections: seq[DiffSelection]): seq[DiffSelection] =
  result = selections
  result.sort(proc (a, b: DiffSelection): int =
    result = cmp(scopeDepth(b.scope), scopeDepth(a.scope))
    if result == 0: result = cmp(b.match.len, a.match.len)
    if result == 0: result = cmp(a.file, b.file)
    if result == 0: result = cmp(a.order, b.order))

proc reportTies(rules: seq[VisualiserRule];
                problems: var seq[ProjectDefinitionProblem]) =
  ## §5.4: "ties broken by declaration order **and reported**".
  ##
  ## A tie is two rules at the same scope depth with the same specificity that
  ## MATCH THE SAME THING — same match text, same match kind, same language.
  ## Reported as a notice: the tie is resolved, deterministically, by
  ## declaration order, and the point of the report is that a user asking
  ## "why did this one win" gets an answer other than "it was first".
  for i in 0 ..< rules.len:
    for j in i + 1 ..< rules.len:
      let a = rules[i]
      let b = rules[j]
      if a.match == b.match and a.matchKind == b.matchKind and
         a.language == b.language and scopeDepth(a.scope) == scopeDepth(b.scope):
        problems.add problem(b.file, 0, pdnRuleTieReported,
          "this rule matches exactly what the rule declared " &
          (if a.file == b.file: "earlier in this file"
           else: "in '" & a.file & "'") &
          " matches ('" & a.match & "', " & $a.matchKind &
          (if a.language.len > 0: ", language '" & a.language & "'" else: "") &
          "). Declaration order decided, and the earlier one wins. §5.4 " &
          "requires that a user be able to ask which visualiser rendered a " &
          "value and get an answer, which a silently broken tie does not give")

proc loadProjectDefinitions*(projectFiles: openArray[DefinitionFile];
                             userFiles: openArray[DefinitionFile] = []):
    LoadedProjectDefinitions =
  ## THE ENTRY POINT, and it opens nothing.
  ##
  ## Both arguments are files somebody else read. `src/ct/launch/`'s
  ## `project_definitions_dir.nim` is the half that has a filesystem; this is
  ## the half that has the grammar, and the split is what makes PLAT-11's
  ## third deliverable ("a loader with **no** I/O, network, process or
  ## filesystem access beyond the checkout") checkable rather than asserted:
  ## `project_definitions_test` reads this package's entire import closure and
  ## fails on anything that could reach a machine.
  composeInto(projectFiles, doProject, result.project, result.problems)
  composeInto(userFiles, doUser, result.user, result.problems)
  result.project.visualisers = rankVisualisers(result.project.visualisers)
  result.project.diffs = rankDiffs(result.project.diffs)
  result.user.visualisers = rankVisualisers(result.user.visualisers)
  result.user.diffs = rankDiffs(result.user.diffs)
  reportTies(result.project.visualisers, result.problems)
  reportTies(result.user.visualisers, result.problems)

func allCollections*(l: LoadedProjectDefinitions): seq[PointCollection] =
  ## Both sets, in ONE list, with every entry carrying its `origin`.
  ##
  ## This is deliberately the only function that returns them together, and it
  ## returns the RECORDS rather than their contents, so the origin travels
  ## with each. §6 forbids silently merging the user's into the project's; it
  ## does not forbid a pane listing both, and a pane that listed only one
  ## would be hiding the user's own work from them.
  ##
  ## The project's come first because the project's are the shared ones; a
  ## user's collection of the same name does NOT replace a project's —
  ## composition (above) is within one origin only, so both appear and the
  ## user can see that they have shadowed nothing.
  for c in l.project.collections: result.add c
  for c in l.user.collections: result.add c

func describeLoad*(l: LoadedProjectDefinitions): string =
  ## One block of text a `--verbose` run, a log or a diagnostics pane can
  ## print: what loaded, and everything that did not.
  var lines: seq[string] = @[]
  lines.add "project definitions: " &
    $l.project.collections.len & " collection(s), " &
    $l.project.visualisers.len & " visualiser rule(s), " &
    $l.project.diffs.len & " diff selection(s)"
  if l.user.collections.len + l.user.visualisers.len + l.user.diffs.len > 0:
    lines.add "your own definitions (not part of the project): " &
      $l.user.collections.len & " collection(s), " &
      $l.user.visualisers.len & " visualiser rule(s), " &
      $l.user.diffs.len & " diff selection(s)"
  let refused = refusals(l.problems)
  let noted = notices(l.problems)
  if refused.len > 0:
    lines.add $refused.len & " refused:"
    for p in refused: lines.add "  " & render(p)
  if noted.len > 0:
    lines.add $noted.len & " reported:"
    for p in noted: lines.add "  " & render(p)
  lines.join("\n")
