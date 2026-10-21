## Whether an IsoNim side panel still has the mount its module remembers.
##
## The defect this exists for
## --------------------------
## Reported: *"when I enter debug mode and then hit the Stop button, the FILES,
## VCS and TESTS panels become empty."*
##
## The panes mount and hold nothing, and nothing about their DATA is wrong.
## `applyModeLayout` reuses the components already in `componentMapping`, the
## ViewModels keep their contents, and `genericUiComponent` re-runs
## `syncLegacyFilesystemIntoVM` / `syncLegacyVCSIntoVM` and calls each
## `tryMountIsoNimPanel` on the new layout. Every one of those calls then
## returned at its first line, because each module kept a WRITE-ONCE table of
## component ids it had already mounted:
##
##     if isoNimVCSMountedIds.hasKey(componentId): return
##
## `swapLayout` destroys the whole GoldenLayout tree and rebuilds it, so the
## container those latches referred to is gone and a fresh, empty one with the
## SAME id has taken its place. The clearing path — `closeLayoutTab` calling
## `component.unregister()` — does not run, because `layout.nim` deliberately
## suppresses `itemDestroyed` for the duration of a layout swap. That
## suppression is correct: it is what stops a mode switch throwing away Monaco
## buffers. It also guarantees that an id-keyed latch outlives the mount it
## describes.
##
## `ui/test_results.nim`'s own `unregister` already named this failure — "after
## a session switch or a panel close the pane comes back blank and silent,
## because its mount returns early at a guard that nothing ever clears" — for
## two routes. A mode transition is the third, and the worst, because on that
## route the clearing path is skipped by design rather than by omission.
##
## Why the mark lives on the container, not in a table
## ---------------------------------------------------
## A table keyed on a component id is a claim about a NAME. What the caller
## needs to know is whether a particular NODE still carries the view — and the
## node is the thing that was destroyed. Marking the container itself makes the
## latch die exactly when the thing it describes dies, with no reset call to
## remember to add: a rebuilt container is a new element and carries no mark, so
## the next `tryMount` mounts. That covers the mode swap, the session switch and
## the panel close with one mechanism instead of three, and covers the route
## nobody has thought of yet.
##
## This is the same defect as the read-only guard in
## `ui/read_only_transition.nim`, one level up: a remembered boolean was treated
## as the state itself, so the work that establishes the state was skipped
## whenever the memory and the world disagreed.

const IsoNimPanelMountedAttr* = cstring"data-ct-isonim-mounted"
  ## Set on a panel's container element once its IsoNim view is mounted into it.
  ## Read back from whatever element is in the document NOW, which is the whole
  ## point — an element the layout rebuilt is a different element.

func isoNimPanelNeedsMount*(idLatchSaysMounted: bool;
                            containerCarriesMark: bool): bool =
  ## Must `tryMountIsoNimPanel` go on and mount?
  ##
  ## THE FIX IS THE CHANGE OF SUBJECT. The answer used to be
  ## `not idLatchSaysMounted` — a question about the module's memory. It is now
  ## `not containerCarriesMark`, a question about the container in front of it.
  ##
  ## `idLatchSaysMounted` is still a parameter, and is still exactly what the
  ## pre-fix build answered from, so `isonim_panel_mount_test.nim` can state
  ## both answers and name the case that separates them: the latch says mounted
  ## and the container is a fresh one, which is every pane after a mode switch.
  when defined(ctIsoNimPanelIdLatch):
    # THE PRE-FIX ANSWER, reachable only by defining this symbol, and defined
    # ONLY by the control-data run in `isonim_panel_mount_test.nim`'s header.
    # Nothing in the product defines it.
    not idLatchSaysMounted
  else:
    not containerCarriesMark

func isoNimPanelMountIsLive*(mountedVMIsCurrent: bool;
                             hostCarriesMark: bool): bool =
  ## Is the mount a SINGLE-INSTANCE pane remembers still the one on screen?
  ##
  ## The three replay panes — State, Call Trace, Timeline — never had the
  ## id-keyed table above. Each kept one module-level `isoNimXMounted: bool`,
  ## set on mount and cleared at exactly one place: the pane's
  ## `initXVMFromSession` (or `initXVMWithStore`), when the stub-backed ViewModel is replaced by the
  ## real one. So the boolean answered a question about the module's own
  ## history and nothing else.
  ##
  ## **A boolean that records "I mounted once" cannot answer "is it mounted
  ## now".** `layout.swapLayout` hands GoldenLayout a whole new tree; the DOM
  ## the pane mounted into is destroyed and `itemDestroyed` is deliberately
  ## suppressed for the duration, so no reset runs. The flag stays `true`, the
  ## next `tryMount` returns at its first line, and the pane is blank with no
  ## error, no exception and no log — the same silence documented at the top
  ## of this file for the id-keyed panes.
  ##
  ## Both halves are load-bearing and neither subsumes the other:
  ##
  ##   * `hostCarriesMark` — the host IN FRONT OF THE MOUNT (this tab's,
  ##     found by `findIsoNimPaneHost`) carries the mount mark. It used to be
  ##     `hostIsInDocument`, `document.contains(host)` of the one host the
  ##     module remembered;
  ##     that answered "live" in every tab once tab 0 had mounted
  ##     (issue `2026-10-21-isonim-panes-stay-blank-in-every-desktop-tab-but-the-first.md`).
  ##     A rebuilt host carries no mark, so the layout swap is still covered.
  ##   * `mountedVMIsCurrent` — the ViewModel recorded ON that host
  ##     (`recordIsoNimPanelHostSource`) is the current one. The host can be
  ##     perfectly alive and holding
  ##     the DOM of a ViewModel that has since been replaced. This is the
  ##     case the old flag's single reset site existed for, and dropping it
  ##     would leave the stub backend's rows on screen after the real one
  ##     arrived.
  when defined(ctIsoNimPanelIdLatch):
    # THE PRE-FIX ANSWER, reachable only by defining this symbol — the same
    # control-data lever `isoNimPanelNeedsMount` above uses, and defined by
    # nothing in the product. `isoNimXMounted` was set true on mount and
    # cleared only on a ViewModel swap, so it is exactly `mountedVMIsCurrent`
    # with the DOM question left unasked.
    mountedVMIsCurrent
  else:
    mountedVMIsCurrent and hostCarriesMark


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
# tab 0's, hidden or not. Every `tryMountIsoNim*Panel` then asked tab 0's host
# whether it was mounted (it was), declined, and the later tab's own host was
# never looked at: a second replay tab had a working editor and nothing else
# (`GUI/Multi-Window-Tab-Management.md` §Tab Behavior, rules 1 and 2).
#
# The rule below, and `findIsoNimPaneHost` that applies it, are the one place
# that answers "which element is this pane's host in this tab". The #835 fix
# made EDITOR ids window-unique instead; that is right for panes a tab opens
# any number of, and wrong for the singleton chrome, whose id 0 per tab is
# load-bearing.

const NotInAnyTab* = -1
  ## The tab of a host that sits in no `session-container-<n>`: the auto-hide
  ## standalone host (`document.body`), a VS Code webview, a page that never
  ## created a tab container.

func isoNimPaneHostChoice*(hostTabs: openArray[int]; activeTab: int): int =
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
    # which only the control-data run in `isonim_panel_mount_test.nim` does.
    if hostTabs.len > 0: 0 else: -1
  else:
    for i, tab in hostTabs:
      if tab == activeTab:
        return i
    for i, tab in hostTabs:
      if tab == NotInAnyTab:
        return i
    -1

func isoNimPanelNeedsMountInHost*(latchSaysMounted: bool;
                                  hostCarriesMark: bool): bool =
  ## For the panes that keep a MODULE-level latch — a `bool` (Event Log,
  ## Terminal, Build, …) or a table keyed by the bare component id
  ## (Constraints, Scratchpad, Agent Activity, …): must this host be mounted?
  ##
  ## The latch alone answered for every tab at once. Tab 0's mount set it, and
  ## tab 1's host — same id, different element — was then "mounted" without
  ## ever having been. So the host is asked too: the view is in place only
  ## when the latch says so AND this element carries the mark
  ## (`markIsoNimPanelContainerMounted`). The latch keeps its other job: the
  ## modules CLEAR it to have a live host rebuilt (a ViewModel swap in
  ## `initXVMFromSession`, `unregister`, the auto-hide overlay refresh), and a
  ## cleared latch still mounts.
  ##
  ## The panes whose latch never decided — Files, VCS, Test Results — keep
  ## `isoNimPanelNeedsMount`, which asks the mark alone.
  when defined(ctIsoNimPanelIdLatch):
    # THE PRE-FIX ANSWER: the latch alone. Control-data only, as above.
    not latchSaysMounted
  else:
    not (latchSaysMounted and hostCarriesMark)

when defined(js):
  import std/jsffi
  from isonim/web/dom_api as isonim_dom_api import nil

  proc isoNimPanelContainerIsMounted*(container: isonim_dom_api.Element): bool =
    ## Does this element already carry a mounted IsoNim view?
    isonim_dom_api.getAttribute(container, IsoNimPanelMountedAttr) ==
      cstring"1"

  proc markIsoNimPanelContainerMounted*(container: isonim_dom_api.Element) =
    ## Record the mount ON THE ELEMENT, so it cannot outlive it.
    isonim_dom_api.setAttribute(container, IsoNimPanelMountedAttr, cstring"1")

  # -------------------------------------------------------------------------
  # The host lookup every `tryMountIsoNim*Panel` goes through
  # -------------------------------------------------------------------------

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

  proc findIsoNimPaneHost*(hostId: cstring;
                           activeTab: int): isonim_dom_api.Element =
    ## THE host of the pane `hostId` (`stateComponent-0`, `vCSComponent-0`, …)
    ## for tab `activeTab`, or `nil` when that tab has none yet — in which case
    ## the caller keeps retrying, as it already does while GoldenLayout builds
    ## the container. The choice is `isoNimPaneHostChoice`; read it for why a
    ## host that only ANOTHER tab holds is never returned.
    ##
    ## `activeTab` is `data.activeSessionIndex` AS THE MOUNT WAS REQUESTED,
    ## captured before the retry loop starts: a retry that lands after the user
    ## switched tabs still mounts the tab it was asked for. `session_switch`
    ## makes a tab active before it builds that tab's components and layout
    ## (`createNewSession`, `switchSession`), so a mount requested while a tab
    ## is being built names that tab.
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
    let pick = isoNimPaneHostChoice(tabs, activeTab)
    if pick < 0: nil else: hosts[pick]

  # -------------------------------------------------------------------------
  # Which ViewModel a host's view was built on
  # -------------------------------------------------------------------------

  proc jsRecordHostSource(host: isonim_dom_api.Element; source: JsRoot)
      {.importjs: "#.__ctIsoNimMountSource = #".}
  proc jsHostHoldsSource(host: isonim_dom_api.Element; source: JsRoot): bool
      {.importjs: "((#.__ctIsoNimMountSource || null) === #)".}

  proc recordIsoNimPanelHostSource*[T: ref](host: isonim_dom_api.Element;
                                            source: T) =
    ## Record ON THE ELEMENT which ViewModel the view mounted into it reads.
    ## For the single-instance replay panes (State, Call Trace), whose one
    ## module-level "mounted host / mounted VM" pair could describe only one
    ## tab's host. Like the mark, it dies with the element.
    jsRecordHostSource(host, cast[JsRoot](source))

  proc isoNimPanelHostHolds*[T: ref](host: isonim_dom_api.Element;
                                     source: T): bool =
    ## Was the view in `host` mounted on `source`? `false` for a host that was
    ## never mounted, or was mounted on a ViewModel since replaced.
    if source.isNil:
      return false
    jsHostHoldsSource(host, cast[JsRoot](source))
