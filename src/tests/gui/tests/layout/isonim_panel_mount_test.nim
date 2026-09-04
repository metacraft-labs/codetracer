## isonim_panel_mount_test.nim
##
## Headless tests for `src/frontend/ui/isonim_panel_mount.nim`, the guard the
## FILES, VCS and TESTS panes consult before mounting their IsoNim view.
##
## Reported: *"when I enter debug mode and then hit the Stop button, the FILES,
## VCS and TESTS panels become empty."*
##
## The panes are mounted and hold nothing. Not a fetch failure: the components
## are reused rather than rebuilt, the ViewModels keep their data, and
## `genericUiComponent` re-syncs them and calls each `tryMountIsoNimPanel` on
## the new layout. Each of those calls returned at a write-once table of
## component ids — a latch describing a container that `swapLayout` had already
## destroyed, and that nothing cleared because `layout.nim` suppresses
## `itemDestroyed` for the duration of a layout swap.
##
## THE CONTROL-DATA RUN. The pre-fix answer is carried rather than deleted:
##
##     nim c -r -d:ctIsoNimPanelIdLatch \
##       --path:src src/tests/gui/tests/layout/isonim_panel_mount_test.nim
##
## restores `isoNimPanelNeedsMount` to `not idLatchSaysMounted`, the expression
## all three panes were guarded on. Nothing in the product defines that symbol.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/layout/isonim_panel_mount_test.nim

import std/unittest

import ../../../../frontend/ui/isonim_panel_mount

suite "the latch describes a container, not a name":

  test "AFTER A MODE SWAP: the id was mounted once, this container never was":
    # THE REPORTED DEFECT. `swapLayout` destroyed the element the latch was
    # about and GoldenLayout built a fresh one carrying the same id, so:
    #
    #   * the module's table still says "id 0 is mounted"  -> true
    #   * the element now in the document carries no mark  -> false
    #
    # The pane must mount. Under the id latch it did not, and the user saw an
    # empty FILES panel after pressing Stop.
    check isoNimPanelNeedsMount(idLatchSaysMounted = true,
                                containerCarriesMark = false)

  test "a container that really does carry the view is not mounted twice":
    # The other half, and the reason this is not simply "always mount".
    # `tryMountIsoNimPanel` is called on every registration and re-registration
    # and its first act is to delete the container's children — mounting on top
    # of a live view would tear down a rendered tree and rebuild it on every
    # redraw, and would discard the DOM state the view holds.
    check not isoNimPanelNeedsMount(idLatchSaysMounted = true,
                                    containerCarriesMark = true)

  test "the id latch does not decide, in either direction":
    # Stated as the pair, because "the container decides" is the whole change
    # and a rule that still consulted the id for one of the two answers would
    # keep the defect on that side. The id is now bookkeeping; the mark is the
    # fact.
    for idLatch in [false, true]:
      check isoNimPanelNeedsMount(idLatch, containerCarriesMark = false)
      check not isoNimPanelNeedsMount(idLatch, containerCarriesMark = true)

  test "a first mount still happens":
    # The boot case, which the id latch got right and which must survive.
    check isoNimPanelNeedsMount(idLatchSaysMounted = false,
                                containerCarriesMark = false)

  test "the attribute is one name, and the three panes share it":
    # The mark has to be the same string in every pane or each pane gets a
    # private latch again, which is the shape that produced three copies of one
    # defect. Asserted literally because it is what reaches the DOM and what a
    # browser assertion reads back.
    check IsoNimPanelMountedAttr == cstring"data-ct-isonim-mounted"

suite "the single-instance panes ask the document, not their memory":
  ## `isoNimPanelMountIsLive` is the same change of subject one shape further
  ## along. State, Call Trace and Timeline never had the id-keyed table above;
  ## each kept one module-level `isoNimXMounted: bool`, set on mount and cleared
  ## at exactly one site — the pane's `initXVMWithStore`, when the stub-backed
  ## ViewModel is replaced by the real one.
  ##
  ## THE CONTROL-DATA RUN is the same symbol as above:
  ##
  ##     nim c -r -d:ctIsoNimPanelIdLatch \
  ##       --path:src src/tests/gui/tests/layout/isonim_panel_mount_test.nim
  ##
  ## restores the answer to `mountedVMIsCurrent` alone, which is exactly what
  ## the deleted boolean computed. The first test below is written so that it
  ## FAILS under that define, naming the pane state that produced a blank panel.

  test "AFTER A LAYOUT SWAP: the flag says mounted, the host is gone":
    # THE CASE THE BOOLEAN COULD NOT SEE, and the one this suite exists for.
    #
    # `layout.swapLayout` hands GoldenLayout a whole new tree. The host the
    # pane mounted into is destroyed, and `itemDestroyed` is suppressed for the
    # duration of the swap — deliberately, because that suppression is what
    # stops a mode switch throwing away Monaco buffers. So no reset runs:
    #
    #   * the ViewModel has not been replaced, so the old flag stays true
    #   * `document.contains(host)` is false — that element is not in the page
    #
    # The pane must mount. Under the boolean it did not, and the pane came back
    # blank with no error, no exception and no log.
    #
    # THIS IS THE ASSERTION THAT FAILS UNDER `-d:ctIsoNimPanelIdLatch`.
    check not isoNimPanelMountIsLive(mountedVMIsCurrent = true,
                                     hostIsInDocument = false)

  test "a live host holding the current ViewModel is not remounted":
    # The other half, and the reason this is not simply "always mount". Every
    # mount's first act is to delete the host's children, so remounting over a
    # live view tears down a rendered tree on every registration.
    check isoNimPanelMountIsLive(mountedVMIsCurrent = true,
                                 hostIsInDocument = true)

  test "a live host holding a REPLACED ViewModel is remounted":
    # The case the deleted flag's single reset site existed for: the stub
    # backend's ViewModel is swapped for the real one while the host is
    # perfectly alive. Without this half the pane would keep showing the stub's
    # rows after the real backend arrived, and deleting the flag would have
    # been a regression rather than a fix.
    check not isoNimPanelMountIsLive(mountedVMIsCurrent = false,
                                     hostIsInDocument = true)

  test "a pane that has never mounted is never live":
    # The boot case. `mountedXHost` is nil, so `isoNimPanelHostIsInDocument`
    # answers false, and both halves agree.
    check not isoNimPanelMountIsLive(mountedVMIsCurrent = false,
                                     hostIsInDocument = false)

  test "both halves decide, and neither subsumes the other":
    # Stated as the matrix because a predicate that ignored one input would
    # still pass three of the four cases above by accident. Live is exactly the
    # top-right corner.
    var liveCount = 0
    for vmCurrent in [false, true]:
      for inDocument in [false, true]:
        if isoNimPanelMountIsLive(vmCurrent, inDocument):
          inc liveCount
          check vmCurrent
          check inDocument
    check liveCount == 1
