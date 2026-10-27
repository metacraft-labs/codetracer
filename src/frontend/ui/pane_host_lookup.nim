## ui/pane_host_lookup.nim — which element is a pane's host in a given tab.
##
## The panel host (`ui/panel_host`) mounts panes into the containers
## GoldenLayout's factories create, and needs no lookup for those. The one
## path that finds a host by its id is a container rebuilt OUTSIDE GoldenLayout
## (an auto-hide panel restored from its saved state), and the id is not unique
## in the window: every tab carries the singleton panes' hosts under the same
## id. This module is the rule that picks the right one.

# ---------------------------------------------------------------------------
# Which host is THIS tab's
# ---------------------------------------------------------------------------
#
# The defect this exists for: codetracer-pm issue
# `2026-10-21-isonim-panes-stay-blank-in-every-desktop-tab-but-the-first.md`.
#
# Every tab of a desktop window keeps its DOM in ONE document: tab <n> lives in
# `#ROOT > .session-container#session-container-<n>`, and `ui/session_switch.nim`
# only hides and shows those containers. The singleton panes keep component id
# 0 in every tab — by design, `data.buildComponent(0)` and friends look them up
# by it — so `stateComponent-0`, `vCSComponent-0`, `constraintsComponent-0`, …
# name one host PER TAB. `getElementById` returns the first in document order,
# tab 0's, hidden or not. Every pane then asked tab 0's host
# whether it was mounted (it was), declined, and the later tab's own host was
# never looked at: a second replay tab had a working editor and nothing else
# (`GUI/Multi-Window-Tab-Management.md` §Tab Behavior, rules 1 and 2).
#
# The rule below, and `findPaneHost` that applies it, are the one place
# that answers "which element is this pane's host in this tab". The #835 fix
# made EDITOR ids window-unique instead; that is right for panes a tab opens
# any number of, and wrong for the singleton chrome, whose id 0 per tab is
# load-bearing.

const NotInAnyTab* = -1
  ## The tab of a host that sits in no `session-container-<n>`: the auto-hide
  ## standalone host (`document.body`), a VS Code webview, a page that never
  ## created a tab container.

func paneHostChoice*(hostTabs: openArray[int]; activeTab: int): int =
  ## Of the hosts carrying a pane's id, in document order, each described by
  ## the tab whose container holds it, which is the active tab's? Returns its
  ## position in `hostTabs`, or -1 when there is none YET.
  ##
  ## 1. The active tab's own host.
  ## 2. Otherwise a host outside every tab — those panes are window-wide by
  ##    construction (the footer's Build / Problems / Search / Requests, the
  ##    extension's single page).
  ## 3. Otherwise none. A host held only by ANOTHER tab is not this tab's to
  ##    mount, even when it is the only match: the caller's container has not
  ##    been built yet, and it retries until it is. Borrowing the other tab's
  ##    host is exactly the defect — that host is already mounted, so the mount
  ##    declines and this tab never gets one.
  when defined(ctIsoNimPaneHostDocumentWide):
    # THE PRE-FIX ANSWER — `getElementById`'s: the first match in the
    # document, whatever tab holds it. Reachable only by defining this symbol,
    # which only the control-data run in `pane_host_lookup_test.nim` does.
    if hostTabs.len > 0: 0 else: -1
  else:
    for i, tab in hostTabs:
      if tab == activeTab:
        return i
    for i, tab in hostTabs:
      if tab == NotInAnyTab:
        return i
    -1

when defined(js):
  from isonim/web/dom_api as isonim_dom_api import nil

  proc jsHostsWithId(id: cstring): seq[isonim_dom_api.Element] {.importjs:
    "Array.from(document.querySelectorAll('[id=\"' + " &
    "String(#).replace(/[\"\\\\]/g, function(c){return '\\\\' + c;}) + '\"]'))".}
    ## Every element carrying `id`, in document order. `getElementById` would
    ## stop at the first, and the first is the whole defect. The id is quoted
    ## into an attribute selector with `"` and `\` escaped by hand rather than
    ## through `CSS.escape`, which jsdom (the `renderer-dom` lane) lacks.

  proc jsTabOfHost(host: isonim_dom_api.Element): int {.importjs:
    "(function(e){var c=e.closest('.session-container');" &
    "if(!c)return -1;var m=/^session-container-(\\d+)/.exec(c.id);" &
    "return (m&&m[0].length===c.id.length)?Number(m[1]):-1;})(#)".}
    # (No `$` anchor: `$` is a placeholder character in `importjs`. The
    # length check is the anchor.)
    ## The `<n>` of the `session-container-<n>` holding `host`, or
    ## `NotInAnyTab`.

  proc tabOfPaneHost*(host: isonim_dom_api.Element): int =
    ## The tab (`<n>` of `session-container-<n>`) whose container holds
    ## `host`, or `NotInAnyTab` for a host outside every tab container —
    ## which session's ViewModels a pane in `host` shows
    ## (`ui/panel_host.nim`, `ui/session_viewmodels.nim`).
    if isonim_dom_api.isNodeNil(isonim_dom_api.Node(host)):
      return NotInAnyTab
    jsTabOfHost(host)

  proc findPaneHost*(hostId: cstring;
                     activeTab: int): isonim_dom_api.Element =
    ## THE host of the pane `hostId` (`stateComponent-0`, `vCSComponent-0`, …)
    ## for tab `activeTab`, or `nil` when that tab has none. The choice is `paneHostChoice`; read it for why a
    ## host that only ANOTHER tab holds is never returned.
    ##
    ## `activeTab` is `data.activeSessionIndex` as the mount was requested.
    ## `session_switch` makes a tab active before it builds that tab's
    ## components and layout (`createNewSession`, `switchSession`), so a mount
    ## requested while a tab is being built names that tab.
    ##
    ## Window-wide surfaces outside every tab — the footer's standalone
    ## auto-hide host, the VS Code webview, a page with no session containers
    ## — are found exactly as `getElementById` found them. Lookups that are
    ## not a pane's own host (menus, overlays, the status bar) do not come
    ## through here and stay document-wide.
    let hosts = jsHostsWithId(hostId)
    var tabs = newSeq[int](hosts.len)
    for i in 0 ..< hosts.len:
      tabs[i] = jsTabOfHost(hosts[i])
    let pick = paneHostChoice(tabs, activeTab)
    if pick < 0: nil else: hosts[pick]
