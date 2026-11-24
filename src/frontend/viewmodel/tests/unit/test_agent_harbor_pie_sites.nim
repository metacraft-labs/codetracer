## The web's progress pies at their sites (CTF-P1d step 5b): every story of
## a family whose rows, lines or tabs draw a pie, mounted through the
## production web views on the mock DOM, against the viewmodel each story
## builds (`stories/agent_harbor_stories`, the constructors StoryBook and the
## GPUI and terminal hosts share).
##
## For each site that draws a pie:
##   * exactly one pie (`span.ah-pie`);
##   * its role (`data-ah-pie-role`), its share (`data-ah-pie-p`, or the
##     `ah-pie-unknown` shape when no progress is known) and its accessible
##     name (`aria-label`) are the viewmodel's `pie` -- so a view that
##     recomputes a pie, or draws another item's, differs;
##   * it is drawn on the ground the site sits on (`ah-pie-on-<ground>`);
##   * the site's own words print no count or share (`3/19`, `16%`): the pie
##     says it now.
##
## The sites so far: the fleet's rows. The GPUI and terminal
## hosts hold the same rules in their cover tests
## (`test_ctf_p1b_gpui_views_cover_web_states`,
## `test_ctf_p1b_tui_views_cover_web_states`).
##
## No mocks of the subject: the viewmodels read the committed synthetic
## fixture set; the mock renderer is the one both `vm-unit` lanes drive.

import std/[strutils, tables, unittest]

import isonim/core/owner
import isonim/testing/mock_dom

import ../../../stories/codetracer_stories
import ../../../stories/agent_harbor_stories
import ../../views/isonim_agent_harbor_fleet_view
import ../../views/isonim_agent_harbor_pie_view

proc classes(n: MockNode): seq[string] =
  if n.kind != mnkElement or not n.attributes.hasKey("class"): return @[]
  n.attributes["class"].splitWhitespace

proc hasClass(n: MockNode; cls: string): bool = cls in n.classes

proc collectClass(n: MockNode; cls: string; into: var seq[MockNode]) =
  if n.isNil: return
  if n.hasClass(cls): into.add n
  for ch in n.children: collectClass(ch, cls, into)

proc byClass(n: MockNode; cls: string): seq[MockNode] = collectClass(n, cls, result)

proc attr(n: MockNode; name: string): string =
  if n.attributes.hasKey(name): n.attributes[name] else: ""

proc saysShare(words: string): bool =
  ## Whether `words` print a count or a share: a `%`, or a number, `/` and a
  ## number (`3/19`).
  if '%' in words: return true
  for i in 1 ..< words.high:
    if words[i] == '/' and words[i - 1] in Digits and words[i + 1] in Digits: return true

proc pieProblems(site: MockNode; pie: ProgressPie; ground: PieGround; at: string): seq[string] =
  ## One site's pie against the viewmodel's, by the rules in the header,
  ## written out here rather than through the view's own helpers.
  let pies = site.byClass("ah-pie")
  if pies.len != 1:
    return @[at & " draws " & $pies.len & " pies, not one"]
  let d = pies[0]
  if d.attr("data-ah-pie-role") != $pie.role:
    result.add at & ": role " & d.attr("data-ah-pie-role") & ", not " & $pie.role
  let unknown = d.hasClass("ah-pie-unknown")
  if unknown == pie.known:
    result.add at & ": drawn " & (if unknown: "unknown" else: "known") &
               ", the viewmodel's pie is " & (if pie.known: "known" else: "unknown")
  if pie.known:
    let want = pie.fraction * 100.0
    let drawn = parseFloat(d.attr("data-ah-pie-p").strip(chars = {'%'}))
    if abs(drawn - want) > 0.001:
      result.add at & ": share " & d.attr("data-ah-pie-p") & ", not " & $want & "%"
  if d.attr("aria-label") != pie.label:
    result.add at & ": named '" & d.attr("aria-label") & "', not '" & pie.label & "'"
  if not d.hasClass("ah-pie-on-" & $ground):
    result.add at & ": not on the " & $ground & " ground: " & d.attr("class")

const AgentHarborSectionTitle = "CodeTracer/Agent Harbor"
  ## The section's title as its declaration names it (`codetracer_stories`;
  ## the terminal host's `AgentHarborSectionTitle`, which this suite does
  ## not import: it would pull the terminal into the web's unit).

proc agentHarborSection(): CodeTracerStorySection =
  for s in codeTracerStorySections():
    if s.title == AgentHarborSectionTitle: return s
  raise newException(ValueError, "no story section " & AgentHarborSectionTitle)

proc fleetProblems(fixture: string): (seq[string], int) =
  ## The fleet story `fixture` mounted, each row against its `FleetRow`:
  ## the problems, and the rows compared.
  let r = MockRenderer()
  var problems: seq[string]
  var rows = 0
  createRoot proc(done: proc()) =
    let vm = createFleetStoryVM(fixture)
    let view = renderAgentHarborFleetPanel[MockRenderer, MockNode](r, vm)
    let drawn = view.byClass("ah-fleet-row")
    let want = vm.rows
    if drawn.len != want.len:
      problems.add fixture & ": " & $drawn.len & " rows drawn, " & $want.len & " in the viewmodel"
    for i in 0 ..< min(drawn.len, want.len):
      let at = fixture & " row " & want[i].shortId
      problems.add pieProblems(drawn[i], want[i].pie, pgPanel, at)
      if drawn[i].byClass("ah-fleet-dot").len > 0:
        problems.add at & ": still draws the status dot"
      for s in drawn[i].byClass("ah-fleet-status-label"):
        if saysShare(s.textContent): problems.add at & ": the status says a share: " & s.textContent
      inc rows
    vm.dispose()
    done()
  (problems, rows)

suite "CTF-P1d: the web draws each site's pie from its viewmodel":
  test "the fleet: every row of every fleet story":
    var problems: seq[string]
    var stories, rows = 0
    for story in agentHarborSection().stories:
      if story.surface != "agent-harbor-fleet" or isPlaybackStory(story.surface, story.fixture):
        continue
      let (found, compared) = fleetProblems(story.fixture)
      problems.add found
      rows += compared
      inc stories
    for p in problems: echo "  ", p
    check problems.len == 0
    # The section's fleet stories (`fleetFixtures`), every one mounted, and
    # rows drawn: a family that lost its stories cannot pass by drawing none.
    check stories == fleetFixtures.len
    check rows > 0

  test "a recomputed pie is a mismatch":
    var fleet: seq[string]
    let r = MockRenderer()
    createRoot proc(done: proc()) =
      let vm = createFleetStoryVM("snapshot")
      let row = vm.rows[0]
      # A site that recomputes its pie from the category with a made-up
      # plan, rather than reading the row's: role kept, share invented.
      let wrong = pieOf(row.category, 1, 2)
      let host = r.createElement("div")
      r.appendChild(host, pieIndicator[MockRenderer, MockNode](r, wrong, pgPanel, PieLinePx))
      fleet = pieProblems(host, row.pie, pgPanel, "planted")
      # And one on the wrong ground.
      let other = r.createElement("div")
      r.appendChild(other, pieIndicator[MockRenderer, MockNode](r, row.pie, pgMenu, PieLinePx))
      fleet.add pieProblems(other, row.pie, pgPanel, "planted ground")
      vm.dispose()
      done()
    check fleet.len >= 2
    check saysShare("3/19") and saysShare("needs input, 16%")
    check not saysShare("main/feature-2") and not saysShare("needs input")
