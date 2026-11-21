## CTF-P2c step 2 follow-ups (manager note 132), the rules every host
## shares, and the web view's marks for them:
##
## * **The matched-line rule** (`cut_text_rules.cutAroundMatch`, study D62):
##   a matched line of the program's text on one line, the match always
##   whole; the start kept first, then the end, then both sides cut around
##   the match; the trim rule on each side of a "…"; a cut never splits a
##   rune; a match wider than the room keeps its start.
## * **Empty providers** (D60): the providers that answered with nothing
##   are named on one quiet line, in the providers' order, and are not
##   drawn as groups.
## * **A failed provider** (D61): the summary stays in the caption role;
##   only the failed group's state is in the error role.
## * **The web view's marks**: a matched line is `data-ah-cut="match"` with
##   its match's offsets and its whole text as the tooltip; the empty line
##   follows the groups.
##
## No mocks beyond IsoNim's mock renderer (the view's DOM): the viewmodels
## are the results stories' own (`createResultsStoryVM`), over the scripted
## providers those stories use. Widths are counted in characters (one unit
## a byte of ASCII, as a terminal counts cells).

import std/[strutils, tables, unittest]
from std/unicode import runes, validateUtf8
import isonim/core/owner
import isonim/testing/mock_dom
import ../../views/[cut_text_rules, isonim_agent_harbor_results_view, ah_cut_text]
import ../../../stories/agent_harbor_results_stories

proc cells(t: string): int =
  ## Characters, as a terminal counts cells (every glyph here is narrow).
  for _ in t.runes: inc result

proc cut(text, match: string; room: int): string =
  let at = text.find(match)
  doAssert at >= 0
  cutAroundMatch(text, at, at + match.len, room, cells, 1)

proc collect(n: MockNode; name: string; into: var seq[MockNode]) =
  if n.attributes.hasKey(name): into.add n
  for ch in n.children: collect(ch, name, into)

proc all(n: MockNode; name: string): seq[MockNode] = collect(n, name, result)
proc attr(n: MockNode; name: string): string = n.attributes.getOrDefault(name, "")

proc withResults(fixture: string; body: proc(vm: ResultCommandsVM)) =
  createRoot proc(disposeRoot: proc()) =
    let vm = createResultsStoryVM(fixture)
    body(vm)
    vm.dispose()
    disposeRoot()

const Line = "let damage = calculate_damage(initial_shield, remaining_shield, mass);"

suite "the matched-line rule (D62)":
  test "a line that fits is whole":
    check cut("remaining_shield -= damage;", "remaining", 40) == "remaining_shield -= damage;"

  test "the start is kept first, the end cut":
    let shown = cut(Line, "damage", 30)
    check shown.startsWith("let damage")
    check shown.endsWith(CutEllipsis)
    check cells(shown) <= 30

  test "then the end is kept, the start cut":
    let shown = cut(Line, "mass", 30)
    check shown.startsWith(CutEllipsis)
    check shown.endsWith("mass);")
    check cells(shown) <= 30

  test "then both sides are cut around the match, which stays whole":
    let shown = cut(Line, "initial_shield", 26)
    check shown.startsWith(CutEllipsis) and shown.endsWith(CutEllipsis)
    check "initial_shield" in shown
    check cells(shown) <= 26

  test "the match is always whole and the trim rule holds, at every room":
    for room in 8 .. Line.len:
      for match in ["damage", "calculate_damage", "remaining_shield", "mass", "let"]:
        let shown = cut(Line, match, room)
        check cells(shown) <= room
        check not danglesAroundEllipsis(shown)
        if cells(match) + 2 <= room: check match in shown

  test "a match wider than the room keeps its start":
    let shown = cut(Line, "calculate_damage(initial_shield", 12)
    check shown.startsWith(CutEllipsis & "calculate")
    check cells(shown) <= 12

  test "a cut never splits a rune":
    let text = "let señal = remaining_shield — ñandú, ñandú, ñandú"
    for room in 6 .. 40:
      let at = text.find("remaining_shield")
      let shown = cutAroundMatch(text, at, at + 16, room, cells, 1)
      check shown.validateUtf8 == -1

suite "empty providers and a failed provider (D60, D61)":
  test "the empty providers are named on one line, and are no group":
    withResults("search-failed", proc(vm: ResultCommandsVM) =
      check emptyProvidersLine(vm) == "No matches in Files"
      for g in vm.groups: check g.group.id != "files"
      check vm.headerRole == "caption"
      check vm.headerText.contains("Agent Harbor sessions failed"))
    withResults("search-no-symbols", proc(vm: ResultCommandsVM) =
      check emptyProvidersLine(vm) == "No matches in Symbols")
    withResults("search-final", proc(vm: ResultCommandsVM) =
      check emptyProvidersLine(vm) == "")

suite "the web view's marks":
  test "a matched line is cut around its match, its whole text the tooltip":
    withResults("search-final", proc(vm: ResultCommandsVM) =
      let root = renderAgentHarborResults[MockRenderer, MockNode](MockRenderer(), vm)
      var codes: seq[MockNode]
      for n in root.all(CutTextAttribute):
        if n.attr(CutTextAttribute) == CutMatchValue: codes.add n
      check codes.len > 0
      for c in codes:
        let title = c.attr("data-ah-title")
        check c.attr("title") == title
        let s = parseInt(c.attr("data-ah-match-start"))
        let e = parseInt(c.attr("data-ah-match-end"))
        check e > s
        check title[s ..< e].toLowerAscii == "shield")

  test "the empty line follows the groups":
    withResults("search-failed", proc(vm: ResultCommandsVM) =
      let root = renderAgentHarborResults[MockRenderer, MockNode](MockRenderer(), vm)
      let lines = root.all("data-ah-empty-providers")
      check lines.len == 1
      check lines[0].attr("data-ah-empty-providers") == "No matches in Files")
