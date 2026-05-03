## Shared IsoNim shell structure for the standalone ``#isonim-app`` mount.
##
## The shell is intentionally only the standalone experimental app frame:
## header plus section hosts for panels that can render without
## GoldenLayout tab context.  Editor is not listed here because its view
## needs per-tab parameters (index, path, expansion state) supplied by the
## layout manager.

import isonim/dsl/ui
import isonim/core/computation
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

type
  IsoNimAppSectionSpec* = object
    panelId*: string
    title*: string

  IsoNimAppSectionHost*[N] = object
    panelId*: string
    title*: string
    content*: N

  IsoNimAppShell*[N] = object
    root*: N
    sections*: seq[IsoNimAppSectionHost[N]]

const
  IsoNimAppHeaderClass* = "isonim-app-header"
  IsoNimPanelSectionClass* = "isonim-panel-section"
  IsoNimSectionHeaderClass* = "isonim-section-header"
  IsoNimSectionContentClass* = "isonim-section-content"
  IsoNimAppHeaderText* = "IsoNim Rendering (experimental)"

  IsoNimAppSectionSpecs*: array[9, IsoNimAppSectionSpec] = [
    IsoNimAppSectionSpec(panelId: "state", title: "State"),
    IsoNimAppSectionSpec(panelId: "calltrace", title: "Calltrace"),
    IsoNimAppSectionSpec(panelId: "event-log", title: "Event Log"),
    IsoNimAppSectionSpec(panelId: "flow", title: "Flow"),
    IsoNimAppSectionSpec(panelId: "timeline", title: "Timeline"),
    IsoNimAppSectionSpec(panelId: "search", title: "Search"),
    IsoNimAppSectionSpec(panelId: "point-list", title: "Point List"),
    IsoNimAppSectionSpec(panelId: "scratchpad", title: "Scratchpad"),
    IsoNimAppSectionSpec(panelId: "shell", title: "Shell"),
  ]

proc sectionId*(panelId: string): string =
  "isonim-section-" & panelId

template renderIsoNimAppShellImpl(
    r, rootClass, stateContent, calltraceContent, eventLogContent,
    flowContent, timelineContent, searchContent, pointListContent,
    scratchpadContent, shellContent: untyped): untyped =
  ui(r):
    tdiv(class = rootClass):
      tdiv(class = IsoNimAppHeaderClass):
        text IsoNimAppHeaderText
      tdiv(class = IsoNimPanelSectionClass, id = sectionId("state")):
        h3(class = IsoNimSectionHeaderClass):
          text "State"
        tdiv(ref = stateContent, class = IsoNimSectionContentClass):
          discard
      tdiv(class = IsoNimPanelSectionClass, id = sectionId("calltrace")):
        h3(class = IsoNimSectionHeaderClass):
          text "Calltrace"
        tdiv(ref = calltraceContent, class = IsoNimSectionContentClass):
          discard
      tdiv(class = IsoNimPanelSectionClass, id = sectionId("event-log")):
        h3(class = IsoNimSectionHeaderClass):
          text "Event Log"
        tdiv(ref = eventLogContent, class = IsoNimSectionContentClass):
          discard
      tdiv(class = IsoNimPanelSectionClass, id = sectionId("flow")):
        h3(class = IsoNimSectionHeaderClass):
          text "Flow"
        tdiv(ref = flowContent, class = IsoNimSectionContentClass):
          discard
      tdiv(class = IsoNimPanelSectionClass, id = sectionId("timeline")):
        h3(class = IsoNimSectionHeaderClass):
          text "Timeline"
        tdiv(ref = timelineContent, class = IsoNimSectionContentClass):
          discard
      tdiv(class = IsoNimPanelSectionClass, id = sectionId("search")):
        h3(class = IsoNimSectionHeaderClass):
          text "Search"
        tdiv(ref = searchContent, class = IsoNimSectionContentClass):
          discard
      tdiv(class = IsoNimPanelSectionClass, id = sectionId("point-list")):
        h3(class = IsoNimSectionHeaderClass):
          text "Point List"
        tdiv(ref = pointListContent, class = IsoNimSectionContentClass):
          discard
      tdiv(class = IsoNimPanelSectionClass, id = sectionId("scratchpad")):
        h3(class = IsoNimSectionHeaderClass):
          text "Scratchpad"
        tdiv(ref = scratchpadContent, class = IsoNimSectionContentClass):
          discard
      tdiv(class = IsoNimPanelSectionClass, id = sectionId("shell")):
        h3(class = IsoNimSectionHeaderClass):
          text "Shell"
        tdiv(ref = shellContent, class = IsoNimSectionContentClass):
          discard

proc sectionHosts[N](
    stateContent, calltraceContent, eventLogContent, flowContent,
    timelineContent, searchContent, pointListContent, scratchpadContent,
    shellContent: N): seq[IsoNimAppSectionHost[N]] =
  @[
    IsoNimAppSectionHost[N](
      panelId: "state", title: "State", content: stateContent),
    IsoNimAppSectionHost[N](
      panelId: "calltrace", title: "Calltrace", content: calltraceContent),
    IsoNimAppSectionHost[N](
      panelId: "event-log", title: "Event Log", content: eventLogContent),
    IsoNimAppSectionHost[N](
      panelId: "flow", title: "Flow", content: flowContent),
    IsoNimAppSectionHost[N](
      panelId: "timeline", title: "Timeline", content: timelineContent),
    IsoNimAppSectionHost[N](
      panelId: "search", title: "Search", content: searchContent),
    IsoNimAppSectionHost[N](
      panelId: "point-list", title: "Point List", content: pointListContent),
    IsoNimAppSectionHost[N](
      panelId: "scratchpad", title: "Scratchpad", content: scratchpadContent),
    IsoNimAppSectionHost[N](
      panelId: "shell", title: "Shell", content: shellContent),
  ]

proc renderIsoNimAppShell*(r: MockRenderer): IsoNimAppShell[MockNode] =
  var stateContent, calltraceContent, eventLogContent, flowContent: MockNode
  var timelineContent, searchContent, pointListContent: MockNode
  var scratchpadContent, shellContent: MockNode

  let shell = renderIsoNimAppShellImpl(
    r, "isonim-app-shell", stateContent, calltraceContent, eventLogContent,
    flowContent, timelineContent, searchContent, pointListContent,
    scratchpadContent, shellContent)

  IsoNimAppShell[MockNode](
    root: shell,
    sections: sectionHosts(
      stateContent, calltraceContent, eventLogContent, flowContent,
      timelineContent, searchContent, pointListContent, scratchpadContent,
      shellContent),
  )

when defined(js):
  proc renderIsoNimAppShell*(r: WebRenderer):
      IsoNimAppShell[isonim_dom.Element] =
    var stateContent, calltraceContent, eventLogContent: isonim_dom.Element
    var flowContent, timelineContent, searchContent: isonim_dom.Element
    var pointListContent, scratchpadContent, shellContent: isonim_dom.Element

    let shell = renderIsoNimAppShellImpl(
      r, "isonim-app-shell", stateContent, calltraceContent, eventLogContent,
      flowContent, timelineContent, searchContent, pointListContent,
      scratchpadContent, shellContent)

    IsoNimAppShell[isonim_dom.Element](
      root: shell,
      sections: sectionHosts(
        stateContent, calltraceContent, eventLogContent, flowContent,
        timelineContent, searchContent, pointListContent, scratchpadContent,
        shellContent),
    )
