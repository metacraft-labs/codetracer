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
                             hostIsInDocument: bool): bool =
  ## Is the mount a SINGLE-INSTANCE pane remembers still the one on screen?
  ##
  ## The three replay panes — State, Call Trace, Timeline — never had the
  ## id-keyed table above. Each kept one module-level `isoNimXMounted: bool`,
  ## set on mount and cleared at exactly one place: the pane's
  ## `initXVMWithStore`, when the stub-backed ViewModel is replaced by the
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
  ##   * `hostIsInDocument` — `document.contains(host)`, asked of the element
  ##     the module actually mounted into. Covers the layout swap, the session
  ##     switch and the panel close with one question and no reset list.
  ##   * `mountedVMIsCurrent` — the host can be perfectly alive and holding
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
    mountedVMIsCurrent and hostIsInDocument

when defined(js):
  from isonim/web/dom_api as isonim_dom_api import nil

  proc isoNimPanelContainerIsMounted*(container: isonim_dom_api.Element): bool =
    ## Does this element already carry a mounted IsoNim view?
    isonim_dom_api.getAttribute(container, IsoNimPanelMountedAttr) ==
      cstring"1"

  proc markIsoNimPanelContainerMounted*(container: isonim_dom_api.Element) =
    ## Record the mount ON THE ELEMENT, so it cannot outlive it.
    isonim_dom_api.setAttribute(container, IsoNimPanelMountedAttr, cstring"1")

  proc jsDocumentContains(host: isonim_dom_api.Element): bool
      {.importjs: "document.contains(#)".}

  proc isoNimPanelHostIsInDocument*(host: isonim_dom_api.Element): bool =
    ## `document.contains(host)` — the whole of the liveness question.
    ##
    ## A `nil` host means the pane has never mounted, which is not live
    ## either, so the null check is part of the answer rather than a guard
    ## around it.
    if isonim_dom_api.isNodeNil(isonim_dom_api.Node(host)):
      return false
    jsDocumentContains(host)
