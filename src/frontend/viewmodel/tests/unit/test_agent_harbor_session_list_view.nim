## The Agent Harbor session list follows its layout after it is built.
##
## `renderAgentHarborSessionList` draws the sidebar (`tsmSidebar`) and the
## docked (`tsmDocked`) layouts of one `SessionTabStripVM`, and only the
## sidebar carries the collapse-to-marks button. `vm.mode` is a signal a host
## changes with `setMode` after the list is mounted, so the button has to
## appear and disappear with it; a branch over the signal that ran once, when
## the head was built, would keep the first layout's answer forever. These
## checks change the layout under a mounted list, in both directions, and
## count the buttons each time.
##
## The head is built inside the list's render effect, and that effect reads
## `vm.mode` and re-runs, so the button already followed the mode while the
## view branched over `vm.mode.val` inside its `ui` block. `test_view_census`
## caught the branch itself; the fix moved the read into the effect, and
## these checks hold that the move kept the button following the mode.
##
## The last suite holds the whole head to the mode, with the list collapsed:
## sidebar, docked, sidebar again. Each switch must build a NEW head (the
## effect re-ran), drop or restore the title and the summary, and set the
## list's own classes, because collapsing only applies to the sidebar. A
## layout read once, outside the effect, keeps the first answer: the docked
## list then stays collapsed, untitled and with the sidebar's button.
##
## The data source is the embedded fixture (`newFixtureDataSource`), not a
## mock: the head is drawn in every load state, so nothing here waits on it,
## and the fixture keeps the VM on the same construction path the StoryBook
## stories use. The mock renderer is the one both `vm-unit` lanes drive.

import std/[unittest, tables, strutils]

import isonim/core/owner
import isonim/testing/mock_dom
import nim_agents_isonim_viewmodels/agent_harbor/fixture_source

import ../../views/isonim_agent_harbor_session_tabs_view

const ExpectedAssertions = 31
var countedAssertions = 0
template ck(cond: untyped) =
  inc countedAssertions
  check cond

proc classOf(node: MockNode): string =
  if node.attributes.hasKey("class"): node.attributes["class"] else: ""

proc countClass(node: MockNode; class: string): int =
  if node.classOf == class: inc result
  for child in node.children:
    result += countClass(child, class)

const CollapseClass = "ah-session-list-collapse"
const HeadClass = "ah-session-list-head"
const TitleClass = "ah-session-list-title"
const CollapsedClass = "ah-session-list-collapsed"

proc findClass(node: MockNode; class: string): MockNode =
  if node.classOf == class: return node
  for child in node.children:
    let found = findClass(child, class)
    if not found.isNil: return found

proc hasClassToken(node: MockNode; token: string): bool =
  for part in node.classOf.split(' '):
    if part == token: return true

suite "the session list's collapse button follows vm.mode":

  test "a docked list mounted first gains the button in the sidebar and loses it again":
    var panel: MockNode
    var vm: SessionTabStripVM
    createRoot proc(dispose: proc()) =
      vm = newSessionTabStripVM(newFixtureDataSource(), tsmDocked)
      panel = renderAgentHarborSessionList[MockRenderer, MockNode](MockRenderer(), vm)
    ck panel.countClass(CollapseClass) == 0
    vm.setMode(tsmSidebar)
    ck panel.countClass(CollapseClass) == 1
    vm.setMode(tsmDocked)
    ck panel.countClass(CollapseClass) == 0

  test "a sidebar list mounted first loses the button when docked":
    var panel: MockNode
    var vm: SessionTabStripVM
    createRoot proc(dispose: proc()) =
      vm = newSessionTabStripVM(newFixtureDataSource(), tsmSidebar)
      panel = renderAgentHarborSessionList[MockRenderer, MockNode](MockRenderer(), vm)
    ck panel.countClass(CollapseClass) == 1
    vm.setMode(tsmDocked)
    ck panel.countClass(CollapseClass) == 0
    vm.setMode(tsmSidebar)
    ck panel.countClass(CollapseClass) == 1

  test "a collapsed sidebar keeps the button, and docking drops it":
    ## Collapsing hides the title and summary; the button is how the operator
    ## gets them back, so it must survive the collapse.
    var panel: MockNode
    var vm: SessionTabStripVM
    createRoot proc(dispose: proc()) =
      vm = newSessionTabStripVM(newFixtureDataSource(), tsmSidebar)
      panel = renderAgentHarborSessionList[MockRenderer, MockNode](MockRenderer(), vm)
    vm.collapsed.val = true
    ck panel.countClass(CollapseClass) == 1
    vm.setMode(tsmDocked)
    ck panel.countClass(CollapseClass) == 0

suite "the session list's head follows vm.mode while collapsed":

  test "sidebar -> docked -> sidebar rebuilds the head each time, with the collapsed flag":
    var panel: MockNode
    var vm: SessionTabStripVM
    createRoot proc(dispose: proc()) =
      vm = newSessionTabStripVM(newFixtureDataSource(), tsmSidebar)
      panel = renderAgentHarborSessionList[MockRenderer, MockNode](MockRenderer(), vm)
    vm.collapsed.val = true
    # Collapsed sidebar: marks only, the expand button, no title.
    let sidebarHead = panel.findClass(HeadClass)
    ck not sidebarHead.isNil
    ck panel.countClass(HeadClass) == 1
    ck panel.hasClassToken("ah-session-list-sidebar")
    ck panel.hasClassToken(CollapsedClass)
    ck panel.countClass(TitleClass) == 0
    ck panel.countClass(CollapseClass) == 1
    ck panel.findClass(CollapseClass).attributes.getOrDefault("title") == "Expand the session list"

    # Docked: the flag stays set on the VM, but a docked list is never
    # collapsed, so the head is rebuilt with its title and without the button.
    vm.setMode(tsmDocked)
    ck vm.collapsed.val
    let dockedHead = panel.findClass(HeadClass)
    ck not dockedHead.isNil
    ck dockedHead != sidebarHead
    ck panel.countClass(HeadClass) == 1
    ck panel.hasClassToken("ah-session-list-docked")
    ck not panel.hasClassToken(CollapsedClass)
    ck panel.countClass(TitleClass) == 1
    ck panel.countClass(CollapseClass) == 0

    # Sidebar again: collapsed again, as it was left.
    vm.setMode(tsmSidebar)
    let againHead = panel.findClass(HeadClass)
    ck not againHead.isNil
    ck againHead != dockedHead
    ck panel.countClass(HeadClass) == 1
    ck panel.hasClassToken("ah-session-list-sidebar")
    ck panel.hasClassToken(CollapsedClass)
    ck panel.countClass(TitleClass) == 0
    ck panel.countClass(CollapseClass) == 1

  test "the file's assertions all ran":
    ck countedAssertions == ExpectedAssertions
