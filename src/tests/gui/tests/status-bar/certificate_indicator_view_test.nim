## SB-1 — what the user actually sees, headlessly.
##
## `certificate_indicator_vm_test.nim` proves the four states are *decided*
## correctly. This file proves they are *shown*: it renders the real status
## shell (`views/isonim_status_view.renderStatusShell`) through IsoNim's
## `MockRenderer` and asserts the DOM, on both Nim backends.
##
## Three things only a render test can establish, and all three are milestone
## requirements rather than polish:
##
## 1. **An unwired indicator emits no element at all.** SB-1 must not disturb
##    the status bar in a build or a mode that has nothing to say, and the
##    footer contract, the render-stability spec and the two visibility guards
##    all assert the bar's existing DOM. `statusCertificateModel(nil)` is what
##    makes that true, and this is where it is checked.
## 2. **The disclosure opens without a panel and without disturbing the
##    layout.** It renders INSIDE the indicator's own span, which is what
##    "reveal detail … not open a panel or replace the user's layout" means
##    concretely (Status-Bar.md, "Interaction").
## 3. **A state change does not rebuild the shell.** The status bar has a
##    history of re-render churn and `status-bar-render-stability.spec.ts` is
##    the guard; the structure signature is the mechanism, and a certificate
##    state that changed the signature would reintroduce exactly that churn.
##
## No mocks beyond IsoNim's own `MockRenderer`, which is the framework's
## headless renderer rather than a stand-in for the subject.

import std/[strutils, tables, unittest]

import isonim/testing/mock_dom

import views/status_certificate_projection

# ---------------------------------------------------------------------------
# Minimal MockNode helpers
#
# Deliberately local rather than imported from `views/isonim_views_test.nim`:
# that file is 11,000 lines and 465 cases in one binary, and importing it to
# borrow four search helpers would put this suite in its blast radius. They
# RAISE on a miss rather than returning nil, for the reason that file records —
# a nil `MockNode` dereference is a SIGSEGV, and a SIGSEGV cancels every case
# declared after it, while `unittest.check` does not abort a case.
# ---------------------------------------------------------------------------

type NodeNotFound = object of CatchableError

proc hasClass(node: MockNode; cls: string): bool =
  if node.kind != mnkElement:
    return false
  for part in node.attributes.getOrDefault("class", "").split(' '):
    if part == cls:
      return true
  false

proc findByClassOrNil(node: MockNode; cls: string): MockNode =
  if node.hasClass(cls):
    return node
  for child in node.children:
    let found = findByClassOrNil(child, cls)
    if found != nil:
      return found
  nil

proc findByClass(node: MockNode; cls: string): MockNode =
  result = findByClassOrNil(node, cls)
  if result == nil:
    raise newException(NodeNotFound, "no element with class '" & cls & "'")

proc findAllByClass(node: MockNode; cls: string): seq[MockNode] =
  result = @[]
  if node.hasClass(cls):
    result.add node
  for child in node.children:
    result.add findAllByClass(child, cls)

proc textOf(node: MockNode): string =
  if node.kind == mnkText:
    return node.text
  result = ""
  for child in node.children:
    result.add textOf(child)

# ---------------------------------------------------------------------------

proc baseShell(certificate = StatusCertificateModel()): StatusShellModel =
  ## A status shell like the one the product builds, differing only in the
  ## certificate model — so every assertion below is about the indicator.
  StatusShellModel(
    base: StatusBaseModel(
      language: "Nim",
      encoding: "UTF-8",
      processClass: "ready-status",
      processText: "stable: ready",
      showFinished: false,
      locationText: "/w/main.nim:12#44",
      locationTitle: "/w/main.nim:12#44",
      certificate: certificate))

proc modelFor(state: CertificateIndicatorState; disclosed = false):
    StatusCertificateModel =
  ## The projection of a ViewModel sitting in `state`. Built through the real
  ## `statusCertificateModel`, not by hand, so the view suite and the wiring
  ## cannot disagree about what a state looks like.
  let vm = newCertificateIndicatorVm(nil)
  vm.model = CertificateIndicatorModel(
    state: state,
    label: (case state
            of cisNoCertificates: NoCertificatesLabel
            of cisCertified: CertifiedLabel
            of cisNotCertified: NotCertifiedLabel
            of cisWasCertified: WasCertifiedLabel
            of cisUnverifiable: UnverifiableLabel),
    summary: "summary for " & $state,
    remedy: (if state == cisCertified: "" else: RunTheTestsRemedy),
    authenticityNote: NoKeysRegisteredNote,
    detail: @[
      CertificateDetailRow(label: "Framework", value: "ct-test"),
      CertificateDetailRow(label: "Platform", value: "linux/amd64"),
      CertificateDetailRow(label: "Targets", value: "tests/a_test.nim")],
    certificateName: ".ct/certificates/run.toml")
  vm.disclosed = disclosed
  statusCertificateModel(vm)

suite "SB-1: the indicator in the status bar's DOM":

  test "an unwired indicator emits no element at all":
    ## The property that keeps SB-1 invisible to every build and mode that has
    ## nothing to say — and therefore keeps the footer contract, the
    ## render-stability spec and the two visibility guards seeing the DOM they
    ## were written against.
    let r = MockRenderer()
    let shell = renderStatusShell(r, baseShell())
    check findByClassOrNil(shell, "test-certificate-status") == nil
    check findByClassOrNil(shell, "test-certificate-disclosure") == nil
    # And the projection of a nil ViewModel is what produces that.
    check statusCertificateModel(nil).label == ""

  test "each state renders its own label and its own state class":
    ## Four distinguishable states. Distinguishable is the requirement, so the
    ## assertion is that no two of them look alike — not merely that each
    ## renders something.
    var labels: seq[string] = @[]
    var classes: seq[string] = @[]
    for state in [cisNoCertificates, cisCertified, cisNotCertified,
                  cisWasCertified, cisUnverifiable]:
      let r = MockRenderer()
      let shell = renderStatusShell(r, baseShell(modelFor(state)))
      let node = findByClass(shell, "test-certificate-status")
      let label = findByClass(node, "test-certificate-label")
      checkpoint $state & " -> '" & textOf(label) & "'"
      check textOf(label).len > 0
      # The state is on the element as data, so a theme, a test or an
      # assistive technology can read it without parsing the label's prose.
      check node.attributes.getOrDefault("data-certificate-state") ==
        stateClass(state)
      check node.attributes.getOrDefault("role") == "status"
      labels.add textOf(label)
      classes.add node.attributes.getOrDefault("data-certificate-state")

    for i in 0 ..< labels.len:
      for j in (i + 1) ..< labels.len:
        checkpoint labels[i] & " vs " & labels[j]
        check labels[i] != labels[j]
        check classes[i] != classes[j]

  test "unverifiable never reads like not-certified in the DOM":
    ## The distinction the milestone turns on, at the surface a user meets.
    ## Two states that rendered the same text would collapse in the only place
    ## it matters, however carefully the ViewModel kept them apart.
    let notCertified = modelFor(cisNotCertified)
    let unverifiable = modelFor(cisUnverifiable)
    check notCertified.label != unverifiable.label
    check notCertified.stateClass != unverifiable.stateClass

    let r = MockRenderer()
    let shell = renderStatusShell(r, baseShell(unverifiable))
    let node = findByClass(shell, "test-certificate-status")
    check node.hasClass("test-certificate-unverifiable")
    check not node.hasClass("test-certificate-not-certified")

  test "the tooltip carries the honesty sentence, not only the verdict":
    ## Status-Bar.md's Notes: the display MUST NOT imply a stronger guarantee
    ## than the certificate carries. The hover is the shortest path from
    ## "Certified" to a wrong conclusion, so it is where the sentence has to be.
    let certified = modelFor(cisCertified)
    let r = MockRenderer()
    let shell = renderStatusShell(r, baseShell(certified))
    let title = findByClass(shell, "test-certificate-status")
      .attributes.getOrDefault("title")
    checkpoint title
    check "not evidence that the run was not fabricated" in title
    check certified.label == CertifiedLabel

  test "the disclosure is closed until it is opened, and opens in place":
    ## "Selecting the indicator SHOULD reveal detail … it must not open a panel
    ## or replace the user's layout." Rendered as a CHILD of the indicator's own
    ## span, so there is no layout slot involved to disturb.
    let closed = MockRenderer()
    let closedShell = renderStatusShell(closed, baseShell(modelFor(cisCertified)))
    check findByClassOrNil(closedShell, "test-certificate-disclosure") == nil

    let opened = MockRenderer()
    let openedShell = renderStatusShell(
      opened, baseShell(modelFor(cisCertified, disclosed = true)))
    let indicator = findByClass(openedShell, "test-certificate-status")
    # Found from the INDICATOR, not from the shell: this is the assertion that
    # it opened in place rather than somewhere else in the bar.
    let disclosure = findByClass(indicator, "test-certificate-disclosure")
    check disclosure != nil
    # Nothing else in the shell gained or lost a region.
    check findByClassOrNil(openedShell, "status-right") != nil
    check findByClassOrNil(openedShell, "location-path") != nil

  test "the disclosure names framework, targets, platform and the record":
    let r = MockRenderer()
    let shell = renderStatusShell(
      r, baseShell(modelFor(cisCertified, disclosed = true)))
    let rows = findAllByClass(shell, "test-certificate-row")
    check rows.len == 3
    var seen: seq[string] = @[]
    for row in rows:
      seen.add textOf(findByClass(row, "test-certificate-row-label"))
    checkpoint seen.join(", ")
    check "Framework" in seen
    check "Platform" in seen
    check "Targets" in seen
    # The honesty sentence is in the disclosure too, in every state, never
    # abbreviated away.
    check textOf(findByClass(shell, "test-certificate-authenticity")).len > 0

  test "the remedy is shown when there is one and absent when there is not":
    ## "Run the tests" and "fix the configuration" are the practical payload of
    ## keeping unverifiable apart from not-certified, so the remedy must reach
    ## the surface — and a certified state must not invent one.
    let stale = MockRenderer()
    let staleShell = renderStatusShell(
      stale, baseShell(modelFor(cisWasCertified, disclosed = true)))
    check textOf(findByClass(staleShell, "test-certificate-remedy")) ==
      RunTheTestsRemedy

    let good = MockRenderer()
    let goodShell = renderStatusShell(
      good, baseShell(modelFor(cisCertified, disclosed = true)))
    check findByClassOrNil(goodShell, "test-certificate-remedy") == nil

  test "selecting the indicator invokes the callback":
    var selected = 0
    let r = MockRenderer()
    let shell = renderStatusShell(
      r, baseShell(modelFor(cisCertified)),
      StatusShellCallbacks(onSelectCertificate: proc() = inc selected))
    findByClass(shell, "test-certificate-status").fireEvent("click")
    check selected == 1

  test "a state change patches in place; opening the disclosure does not":
    ## The render-stability contract, asserted at its mechanism rather than
    ## through the browser. `statusStructureSignature` is the "can I patch
    ## instead of rebuild?" test, and a certificate STATE that changed it would
    ## rebuild the whole shell — destroying `.location-path`, `#copy-path-image`
    ## and both auto-hide hosts — on every commit the user makes.
    let certified = baseShell(modelFor(cisCertified))
    let stale = baseShell(modelFor(cisWasCertified))
    check statusStructureSignature(certified) == statusStructureSignature(stale)

    # Presence, on the other hand, IS a shape change: the element exists or it
    # does not, and only a rebuild can add it.
    let absent = baseShell()
    check statusStructureSignature(absent) != statusStructureSignature(certified)

    # And so is the disclosure, which adds a subtree.
    let opened = baseShell(modelFor(cisCertified, disclosed = true))
    check statusStructureSignature(opened) != statusStructureSignature(certified)

  test "every field of the certificate model is either in the signature or patched":
    ## `statusStructureSignature`'s own rule, applied to the fields SB-1 added:
    ## "EVERY field of `StatusShellModel` must appear either here or in
    ## `patchStatusValues`. A field in neither renders once and then never
    ## updates again, which is a silent staleness bug rather than a loud one."
    ##
    ## Asserted behaviourally: for each field, two models differing ONLY in that
    ## field must differ in the signature (it is structural) or render
    ## differently through the patch path (it is a value). The second half is
    ## checked here by rendering both and comparing the DOM, because the patch
    ## path itself is `when defined(js)` and needs a real DOM.
    proc rendered(model: StatusCertificateModel): string =
      let r = MockRenderer()
      let shell = renderStatusShell(r, baseShell(model))
      let node = findByClassOrNil(shell, "test-certificate-status")
      if node == nil: return "<absent>"
      result = node.attributes.getOrDefault("class") & "\x1f" &
               node.attributes.getOrDefault("data-certificate-state") & "\x1f" &
               node.attributes.getOrDefault("title") & "\x1f" & textOf(node)

    let base = modelFor(cisCertified, disclosed = true)

    # Built as explicit variants rather than as a table of mutator closures.
    # A capture-free closure literal inside a `unittest` test body is an
    # `env is missing` codegen assertion under `nim js` (jsgen.nim:1239), so
    # the elegant spelling does not compile in half the lanes this suite runs
    # in.
    var variants: seq[StatusCertificateModel] = @[]
    var names: seq[string] = @[]

    block:
      var m = base
      m.label = "Other"
      variants.add m
      names.add "label"
    block:
      var m = base
      m.stateClass = "other"
      variants.add m
      names.add "stateClass"
    block:
      var m = base
      m.title = "other title"
      variants.add m
      names.add "title"
    block:
      var m = base
      m.summary = "other summary"
      variants.add m
      names.add "summary"
    block:
      var m = base
      m.remedy = "other remedy"
      variants.add m
      names.add "remedy"
    block:
      var m = base
      m.authenticityNote = "other note"
      variants.add m
      names.add "authenticityNote"
    block:
      var m = base
      m.disclosed = false
      variants.add m
      names.add "disclosed"
    block:
      var m = base
      m.detail.add StatusCertificateDetailRow(label: "Extra", value: "x")
      variants.add m
      names.add "detail (a row added)"
    block:
      var m = base
      m.detail[0].value = "changed"
      variants.add m
      names.add "detail (a value changed)"

    for i in 0 ..< variants.len:
      let structural =
        statusStructureSignature(baseShell(base)) !=
        statusStructureSignature(baseShell(variants[i]))
      let visible = rendered(base) != rendered(variants[i])
      checkpoint names[i] & ": structural = " & $structural &
                 ", visible = " & $visible
      check structural or visible
