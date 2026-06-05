## ui/origin_chain_runtime.nim
##
## Shared lazy-fill bridge for Value Origin Tracking placeholder pills
## (spec §3.2.3 V1 default ``originDisplay.batchFillVisible: on``).
##
## Every value-rendering surface that renders an icon-only / placeholder
## badge — State Pane (via the IsoNim view), history popover
## (``ui/value.nim``), omniscience-flow overlay (``ui/flow.nim``) —
## funnels its placeholder tokens through this module so the
## ``ct/originSummary`` batch fill collapses into one debounced request
## per ``originDisplay.batchFillThrottleMs`` window.
##
## The module owns:
##
## - a single ``OriginChainVM`` handle, installed by ``ui/state.nim`` at
##   bootstrap (``setOriginChainVM``); the VM is the canonical owner of
##   the placeholder queue + the user preferences signal,
## - a single ``setTimeout`` handle so re-entering ``enqueueOriginPlaceholderToken``
##   inside the throttle window pushes the new token and defers dispatch,
## - an ``IntersectionObserver`` handle that observes placeholder badge
##   elements anywhere on the document so scroll-into-view auto-enqueues
##   them without each surface having to wire its own observer.
##
## The intentional decoupling from ``ui/state.nim`` lets
## ``ui/value.nim`` + ``ui/flow.nim`` participate in the lazy-fill
## pipeline without taking on a circular import (``state.nim`` already
## imports ``value.nim``).

import std/options

import isonim/core/signals
import ../viewmodel/viewmodels/origin_chain_types
import ../viewmodel/viewmodels/origin_chain_vm
import origin_badge

# Re-export so callers reach the badge helpers (and the wire-shape
# extractors) without importing both modules.  ``signals`` is exported
# so callers can read ``OriginChainVM.preferences.val`` without an
# explicit ``isonim/core/signals`` import.
export origin_badge, origin_chain_vm, signals

when defined(js):
  import std/jsffi
  import std/dom

  # ---------------------------------------------------------------------------
  # Module-level state.  All slots are nil/empty until the host wires
  # them via ``setOriginChainVM`` (called by ``ui/state.nim`` once the
  # OriginChainVM is created).  Until then every public proc behaves as
  # a no-op so the surfaces can render the badge without crashing in
  # the rare bootstrap window (e.g. the very first ``CtUpdatedHistory``
  # event before the State VM finishes its async init).
  # ---------------------------------------------------------------------------

  var sharedOriginChainVM: OriginChainVM
  var pendingFlushHandle: TimeOut
  var sharedLazyFillObserver: JsObject

  proc setOriginChainVM*(vm: OriginChainVM) =
    ## Install the shared ``OriginChainVM``.  Idempotent — multiple
    ## bootstraps (the State Pane stub-backend → shared-store path
    ## re-runs init) re-bind without leaking observer state.  Replacing
    ## the VM also resets the lazy-fill observer so the old VM's
    ## preferences signal no longer holds it open.
    sharedOriginChainVM = vm
    if not sharedLazyFillObserver.isNil:
      discard sharedLazyFillObserver.disconnect()
      sharedLazyFillObserver = nil

  proc originChainVM*(): OriginChainVM =
    ## Public accessor.  Returns ``nil`` when the VM has not yet been
    ## bootstrapped; the caller is expected to tolerate the nil.
    sharedOriginChainVM

  proc flushPlaceholdersNow*() =
    ## Cancel any pending throttle timer and dispatch the
    ## ``ct/originSummary`` batch immediately.  Used by the
    ## ``visibilitychange`` / "panel about to close" code paths that
    ## want to honour the queued tokens before the badges leave the
    ## viewport.
    if sharedOriginChainVM.isNil:
      return
    if not pendingFlushHandle.isNil:
      clearTimeout(pendingFlushHandle)
      pendingFlushHandle = nil
    sharedOriginChainVM.flushPlaceholderFill()

  proc enqueueOriginPlaceholderToken*(token: string) =
    ## Enqueue ``token`` into the shared placeholder-fill queue and
    ## (re-)arm the throttled flush.  No-op when ``token`` is empty or
    ## when the OriginChainVM has not been bootstrapped yet.
    if token.len == 0:
      return
    if sharedOriginChainVM.isNil:
      return
    sharedOriginChainVM.enqueuePlaceholderFill(token)
    # Reset the debounce timer so a rapid scroll-fill burst still
    # collapses into one ``ct/originSummary`` request per
    # batchFillThrottleMs interval.
    if not pendingFlushHandle.isNil:
      clearTimeout(pendingFlushHandle)
    let throttleMs = sharedOriginChainVM.preferences.val.batchFillThrottleMs
    pendingFlushHandle = setTimeout(proc() =
      pendingFlushHandle = nil
      if not sharedOriginChainVM.isNil:
        sharedOriginChainVM.flushPlaceholderFill()
    , throttleMs)

  proc ensureLazyFillObserver*(): JsObject =
    ## Create (or return the already-created) ``IntersectionObserver``
    ## that auto-enqueues placeholder badges as they scroll into the
    ## viewport.  Honours the
    ## ``originDisplay.batchFillVisible`` preference — when the user
    ## switches the preference off the observer is torn down so the
    ## badges stay un-resolved until the user clicks them manually.
    if sharedOriginChainVM.isNil:
      return nil
    if not sharedOriginChainVM.preferences.val.batchFillVisible:
      if not sharedLazyFillObserver.isNil:
        discard sharedLazyFillObserver.disconnect()
        sharedLazyFillObserver = nil
      return nil
    if sharedLazyFillObserver.isNil:
      sharedLazyFillObserver = createBadgeIntersectionObserver(
        proc(token: cstring) =
          enqueueOriginPlaceholderToken($token))
    sharedLazyFillObserver

  proc observePlaceholderBadge*(badge: Node) =
    ## Register a placeholder badge with the lazy-fill observer.  Safe
    ## to call on non-placeholder badges (the IntersectionObserver
    ## simply receives them as zero-token entries and the queue de-dups).
    ## Safe to call before the OriginChainVM is bootstrapped — the call
    ## is silently dropped so the surface can render unconditionally.
    let observer = ensureLazyFillObserver()
    if observer.isNil:
      return
    observeBadgeForLazyFill(observer, badge)

  proc observePlaceholderBadgeJs*(badge: JsObject) =
    ## ``JsObject`` overload.  The IsoNim view layer hands us
    ## ``isonim_dom.Node`` (effectively the same browser DOM node) and
    ## ``ui/value.nim`` / ``ui/flow.nim`` use ``kdom.Node``; both are
    ## interchangeable at the JS level, so accept a ``JsObject`` and
    ## let the IntersectionObserver figure it out.
    let observer = ensureLazyFillObserver()
    if observer.isNil:
      return
    if badge.isNil:
      return
    discard observer.observe(badge)
