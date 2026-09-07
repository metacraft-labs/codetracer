## view_vocabulary/portability.nim — PLAT-3. The vocabulary's own check.
##
## PLAT-3's second integration test: "a view using a medium-specific escape is
## rejected by the vocabulary's own check". This is that check.
##
## ## WHAT AN ESCAPE IS, GIVEN THAT THE TYPE IS CLOSED
##
## `ViewNode` has no free-form attribute bag, no class, no style and no
## geometry, so most of the ways a view could name a medium are unrepresentable
## rather than checked. That is deliberate — a constraint the type enforces
## costs nothing to keep — but it leaves a question: if nothing medium-specific
## can be written down, what is there to reject?
##
## Six things, and each of them is a REAL shape rather than one invented so the
## check would have something to say:
##
##   pvNativeEscape       PLAT-9's native view. It is a legitimate thing to
##                        write and an illegitimate thing to claim is portable,
##                        which is exactly why the vocabulary needs a check
##                        rather than a prohibition. A pane that supplies a
##                        native view for GPUI and an abstract one everywhere
##                        else passes this check on the abstract tree and never
##                        runs it on the native one.
##
##   pvPointerOnly        an interactive node whose `activation` lacks
##                        `acKeyboard`. PLAT-3's verification gate is
##                        "designed against the terminal first", and PLAT-6
##                        deliverable 3 spells out why: "a terminal user may
##                        have no pointer". A view reachable only by clicking
##                        is a view written from the web side.
##
##   pvActuationOnReading `activation` on `Text`, `Image`, `Markdown` or
##                        `ProgressIndicator`. A clickable label is the same
##                        defect wearing a different hat: the vocabulary has a
##                        `Button`, and a reading that can be actuated is one
##                        no keyboard contract describes.
##
##   pvNoTextEquivalent   an `Image` with no `alt`. On a terminal with no
##                        graphics protocol — which PLAT-14 exists because it
##                        is the common case — `alt` IS the rendering. An image
##                        without one renders as nothing on the medium this
##                        vocabulary is designed against first.
##
##   pvMediumMarkup       ANSI control bytes or HTML tags inside a node's text.
##                        Terminal escape sequences in a string that a DOM will
##                        set as `textContent` are visible garbage; HTML in a
##                        string a terminal will print is visible garbage the
##                        other way. PLAT-2's survey found five spellings of
##                        one error value, "one of them HTML embedded in the
##                        value itself" — this is that defect arriving in a
##                        view instead of a value.
##
##   pvStructural         two nodes sharing an `id`, or a table row whose
##                        length disagrees with its columns. Neither is
##                        medium-specific; both make a binding on SOME medium
##                        impossible (a focus manager needs to name the focused
##                        node; no medium's table draws a ragged row), which is
##                        the same question asked structurally.
##
## ## THE BOUND ON THE MARKUP RULE, STATED RATHER THAN PRETENDED AWAY
##
## `<` and `>` are ordinary characters. `Vec<T>`, `HashMap<String, i32>` and
## `a < b` are all things a view's text may legitimately contain, and a rule
## that rejected them would be a rule nobody could keep. So the HTML arm
## matches a CLOSED LIST of tag names — `<div`, `</span>`, `<br/>` — and not
## `<` followed by anything. It therefore MISSES markup written with a tag name
## outside the list, and that is recorded here rather than claimed against.
##
## `pkMarkdown` is exempt from the HTML arm entirely: CommonMark permits inline
## HTML by specification, so a Markdown source containing `<br>` is a correct
## Markdown source and not an escape. The ANSI arm still applies to it.
##
## ## NO POSITIVE-CONTROL PROBLEM
##
## `checkPortable` walks a tree it is handed and can therefore be handed an
## empty one, which would satisfy every "must not contain" assertion over its
## result (Verification-Harness-Traps §4). `checkPortable` reports the node
## count it visited alongside the violations for exactly that reason, and the
## suite asserts the count rather than only the emptiness of the violation
## list.

import std/[strutils, tables]

import ./vocabulary
import ./behaviour

type
  ViolationKind* = enum
    pvNativeEscape
    pvPointerOnly
    pvActuationOnReading
    pvNoTextEquivalent
    pvMediumMarkup
    pvStructural

  Violation* = object
    kind*: ViolationKind
    nodeId*: string      ## the offending node's `id`; "" when it has none
    viewKind*: ViewKind
    detail*: string      ## what was found, named

  PortabilityReport* = object
    violations*: seq[Violation]
    nodesVisited*: int
      ## The scan's own positive control. A report with zero violations and
      ## zero nodes visited is a scan that read nothing, and the two are
      ## indistinguishable unless the count is on the report.

const
  HtmlTagNames = [
    "div", "span", "p", "a", "b", "i", "u", "em", "strong", "br", "hr",
    "img", "table", "thead", "tbody", "tr", "td", "th", "ul", "ol", "li",
    "pre", "code", "script", "style", "font", "button", "input", "select",
    "option", "form", "label", "h1", "h2", "h3", "h4", "h5", "h6"]
    ## The closed list the HTML arm matches. See the bound in the header.

func containsAnsi(s: string): bool =
  ## An ESC byte, or any C0 control other than tab and newline. These are
  ## terminal instructions; nothing else in any medium wants them in a string.
  for ch in s:
    let b = ord(ch)
    if b == 0x1b: return true
    if b < 0x20 and ch != '\t' and ch != '\n' and ch != '\r': return true
  false

func containsHtmlTag(s: string): bool =
  let lowered = s.toLowerAscii
  for name in HtmlTagNames:
    for opener in ["<" & name & ">", "<" & name & " ", "<" & name & "/",
                   "</" & name & ">", "</" & name & " "]:
      if lowered.contains(opener): return true
  false

func textsOf(n: ViewNode): seq[string] =
  ## Every string in the node a medium will eventually PRINT. Attributes that
  ## are identities (`id`, `nativeView`, option ids) are excluded: they are
  ## never shown and a `<` in one of them is not markup on any screen.
  result.add n.label
  result.add n.text
  result.add n.alt
  for o in n.options:
    result.add o.label
  for c in n.columns:
    result.add c
  for row in n.rows:
    for cell in row:
      result.add cell

func violation(k: ViolationKind; n: ViewNode; detail: string): Violation =
  Violation(kind: k, nodeId: n.id, viewKind: n.kind, detail: detail)

proc checkPortable*(root: ViewNode): PortabilityReport =
  ## Every reason `root` cannot be rendered on every front-end, with the node
  ## and the reason named. An empty `violations` on a non-zero `nodesVisited`
  ## is the vocabulary saying yes.
  if root.isNil:
    return PortabilityReport()
  var seenIds = initTable[string, int]()
  for n in walk(root):
    inc result.nodesVisited

    if n.nativeMedium.len > 0:
      result.violations.add violation(pvNativeEscape, n,
        "native view '" & n.nativeView & "' for medium '" & n.nativeMedium &
        "'; PLAT-9 native views are per-front-end and cannot be claimed " &
        "portable")
      # A native node's INSIDES are that medium's business; reporting six more
      # violations from under it would bury the one that matters.
      continue

    if n.kind in InteractiveKinds:
      if acKeyboard notin n.activation:
        result.violations.add violation(pvPointerOnly, n,
          "interactive " & vocabularyName(n.kind) &
          " without acKeyboard; a terminal reader may have no pointer")
      if keyContract(n.kind).len == 0:
        result.violations.add violation(pvStructural, n,
          vocabularyName(n.kind) &
          " is interactive but declares no keyboard contract")
    elif n.activation.len > 0:
      result.violations.add violation(pvActuationOnReading, n,
        vocabularyName(n.kind) &
        " is a reading and cannot be actuated; use a Button")

    if n.kind == pkImage and n.alt.len == 0:
      result.violations.add violation(pvNoTextEquivalent, n,
        "Image '" & n.mediaType &
        "' carries no alt; a terminal without a graphics protocol has " &
        "nothing to render")

    if n.id.len == 0:
      result.violations.add violation(pvStructural, n,
        vocabularyName(n.kind) &
        " has no id; a front-end with real focus cannot name it")
    else:
      seenIds.mgetOrPut(n.id, 0).inc
      if seenIds[n.id] == 2:
        result.violations.add violation(pvStructural, n,
          "id '" & n.id & "' is used by more than one node")

    if n.kind == pkTable:
      for i, row in n.rows:
        if row.len != n.columns.len:
          result.violations.add violation(pvStructural, n,
            "table row " & $i & " has " & $row.len & " cells against " &
            $n.columns.len & " columns")
          break

    for s in textsOf(n):
      if s.len == 0: continue
      if containsAnsi(s):
        result.violations.add violation(pvMediumMarkup, n,
          "terminal control bytes in text: " & escape(s))
        break
      if n.kind != pkMarkdown and containsHtmlTag(s):
        result.violations.add violation(pvMediumMarkup, n,
          "HTML markup in text: " & escape(s))
        break

func isPortable*(root: ViewNode): bool =
  ## The one-line answer. A view that visited no nodes is NOT portable — an
  ## empty answer is not a yes.
  let r = checkPortable(root)
  r.nodesVisited > 0 and r.violations.len == 0

func describeViolation*(v: Violation): string =
  ## One line, naming the rule, the node and what was found. Written as one
  ## line for the same reason `describeAttribution` is: the surfaces that would
  ## report it include a terminal status line.
  let id = if v.nodeId.len > 0: v.nodeId else: "<unnamed>"
  $v.kind & " " & vocabularyName(v.viewKind) & " " & id & ": " & v.detail

func describeReport*(r: PortabilityReport): string =
  if r.nodesVisited == 0:
    return "portability check read NO nodes — the scan, not the view, is the " &
           "thing that failed"
  if r.violations.len == 0:
    return "portable: " & $r.nodesVisited & " nodes, no violations"
  var lines = @["not portable: " & $r.violations.len & " violation(s) over " &
                $r.nodesVisited & " nodes"]
  for v in r.violations:
    lines.add "  " & describeViolation(v)
  lines.join("\n")

# ---------------------------------------------------------------------------
# The vocabulary's own invariants, as distinct from a view's
# ---------------------------------------------------------------------------

func vocabularyInvariants*(): seq[string] =
  ## Reasons the VOCABULARY — not a view written in it — is malformed.
  ## Returns an empty sequence when it is well formed.
  ##
  ## This is the arm that catches an entry added to `InteractiveKinds` with no
  ## behaviour, or a reading that grew a keyboard contract. It reads the same
  ## two tables `applyKey` reads, from the outside.
  for k in ViewKind:
    let contract = keyContract(k)
    if k in InteractiveKinds and contract.len == 0:
      result.add vocabularyName(k) &
        " is in InteractiveKinds but has an empty keyContract"
    if k notin InteractiveKinds and contract.len > 0:
      result.add vocabularyName(k) &
        " is not interactive but declares " & $contract.len & " key bindings"
    for binding in contract:
      if binding.key in {kTab, kBackTab}:
        result.add vocabularyName(k) &
          " claims Tab, which belongs to the host's focus order"
      if binding.key == kNone:
        result.add vocabularyName(k) & " has a binding for kNone"
      if binding.description.len == 0:
        result.add vocabularyName(k) & " has a binding with no description"
