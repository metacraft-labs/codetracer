## PixelHistoryVM — ViewModel for RenderDoc-style pixel history entries.

import std/[math, options, strformat]

import isonim/core/[async_compat, signals]
import isonim/viewmodel

import ../store/replay_data_store
import visual_replay_client

type
  PixelHistoryPixel* = object
    x*: int
    y*: int
    frame*: int

  PixelHistoryVM* = ref object of ViewModel
    client*: VisualReplayClient
    store*: ReplayDataStore
    requestSerial: int

    selectedPixel*: Signal[Option[PixelHistoryPixel]]
    entries*: Signal[seq[VisualReplayPixelHistoryEntry]]
    loading*: Signal[bool]
    error*: Signal[string]
    selectedEntry*: Signal[Option[int]]
    onEntrySelected*: proc(entry: VisualReplayPixelHistoryEntry)
    onEntryActivated*: proc(entry: VisualReplayPixelHistoryEntry)
      ## A row NAVIGATED to (`selectEntry` with `seekSource`, a click): the
      ## Video Player shows that draw call (Visual-Replay.md § Pixel History
      ## Tab, "Click an entry to seek the Video Player to that draw call").
      ## Set by `VisualReplayPanesVM`, which owns the player.
    onHistoryLoaded*: proc(entryCount: int; error: string; loading: bool)

const
  PixelHistoryHeading* = "Pixel History"
  PixelHistoryLoadingText* = "Loading pixel history..."
  PixelHistoryEmptyText* = "Click a frame pixel"
    ## The pane's words, every front-end's (Visual-Replay.md § Pixel History
    ## Tab): the desktop's view and the terminal's and GPUI's panes print
    ## these, so the three cannot come to say different things.

proc pixelText*(vm: PixelHistoryVM): string =
  ## The header's pixel: `Pixel 12, 34 frame 2`, or that none is picked.
  if vm.selectedPixel.val.isSome:
    let pixel = vm.selectedPixel.val.get
    "Pixel " & $pixel.x & ", " & $pixel.y & " frame " & $pixel.frame
  else:
    "No pixel selected"

proc colorByte*(channel: float): int =
  ## A 0..1 channel as the 0..255 byte the swatch is painted with.
  int(round(max(0.0, min(channel, 1.0)) * 255.0))

proc colorText*(color: VisualReplayPixelColor): string =
  &"{color.r:.2f}, {color.g:.2f}, {color.b:.2f}, {color.a:.2f}"

proc passText*(entry: VisualReplayPixelHistoryEntry): string =
  if entry.passed:
    "Passed"
  elif entry.failureReason.len > 0:
    "Failed: " & entry.failureReason
  else:
    "Failed"

proc testsText*(entry: VisualReplayPixelHistoryEntry): string =
  "Depth " & entry.testStatus.depth &
    "  Stencil " & entry.testStatus.stencil &
    "  Blend " & entry.testStatus.blend &
    "  Cull " & entry.testStatus.cull

proc drawText*(entry: VisualReplayPixelHistoryEntry): string =
  "Draw " & $entry.drawCallIndex

proc geidText*(entry: VisualReplayPixelHistoryEntry): string =
  "GEID " & $entry.geid

proc showsEmptyHint*(vm: PixelHistoryVM): bool =
  vm.entries.val.len == 0 and not vm.loading.val and vm.error.val.len == 0

proc beginLoad(vm: PixelHistoryVM): int =
  inc vm.requestSerial
  result = vm.requestSerial
  vm.loading.val = true
  vm.error.val = ""
  vm.entries.val = @[]
  vm.selectedEntry.val = none(int)

proc loadPixelHistory*(vm: PixelHistoryVM; x, y, frame: int) =
  let clampedFrame = max(frame, 0)
  let serial = vm.beginLoad()
  vm.selectedPixel.val = some(PixelHistoryPixel(x: max(x, 0),
                                                y: max(y, 0),
                                                frame: clampedFrame))
  let fut = vm.client.getPixelHistory(max(x, 0), max(y, 0), clampedFrame)
  async_compat.onComplete(fut,
    onSuccess = proc(entries: seq[VisualReplayPixelHistoryEntry]) =
      if serial != vm.requestSerial:
        return
      vm.entries.val = entries
      vm.loading.val = false
      if not vm.onHistoryLoaded.isNil:
        vm.onHistoryLoaded(entries.len, "", false),
    onError = proc(message: string) =
      if serial == vm.requestSerial:
        vm.loading.val = false
        vm.error.val = message
        vm.entries.val = @[]
        if not vm.onHistoryLoaded.isNil:
          vm.onHistoryLoaded(0, message, false))

proc jumpToSourceForEntry*(vm: PixelHistoryVM; index: int): bool =
  ## Dispatch ``ct/seek-to-geid`` for the draw-call entry at ``index``.
  ## Returns ``true`` when the navigation request was actually sent — i.e.
  ## the index is in range, the store is wired, and the entry carries a
  ## non-zero GEID.  This is the M6 "source-jump from draw call" entry
  ## point: the backend's ``seek_to_geid`` handler resolves the GEID to a
  ## ``Location`` and emits ``ct/complete-move``, which
  ## ``EditorViewComponent.onCompleteMove`` consumes to open the relevant
  ## source file at the issuing line.
  ##
  ## A zero GEID is treated as "no source mapping available" and skipped
  ## silently — the spec does not define a tooltip surface, so the
  ## defensive choice is a no-op rather than a misleading editor jump to
  ## the wrong line.  Callers that need user feedback should inspect the
  ## returned bool.
  if vm.store.isNil:
    return false
  if index < 0 or index >= vm.entries.val.len:
    return false
  let geid = vm.entries.val[index].geid
  if geid == 0'u64:
    return false
  vm.store.requestSeekToGeid(geid)
  true

proc selectEntry*(vm: PixelHistoryVM; index: int; seekSource = true) =
  if index < 0 or index >= vm.entries.val.len:
    vm.selectedEntry.val = none(int)
    return
  vm.selectedEntry.val = some(index)
  if seekSource:
    # Route via the public ``jumpToSourceForEntry`` so the M6 source-jump
    # contract has a single implementation.  ``selectEntry`` keeps the
    # historical "select+seek" behaviour (the row click stays a one-step
    # navigation), while a future affordance — e.g. a dedicated jump
    # icon — can call ``jumpToSourceForEntry`` directly without first
    # toggling the selection signal.
    discard vm.jumpToSourceForEntry(index)
    if not vm.onEntryActivated.isNil:
      vm.onEntryActivated(vm.entries.val[index])
  if not vm.onEntrySelected.isNil:
    vm.onEntrySelected(vm.entries.val[index])

proc bindReplayStore*(vm: PixelHistoryVM; store: ReplayDataStore) =
  if store.isNil or vm.store == store:
    return
  vm.store = store

proc createPixelHistoryVM*(client: VisualReplayClient;
                           store: ReplayDataStore = nil): PixelHistoryVM =
  withViewModel proc(dispose: proc()): PixelHistoryVM =
    let vm = PixelHistoryVM(
      client: client,
      selectedPixel: createSignal(none(PixelHistoryPixel)),
      entries: createSignal(newSeq[VisualReplayPixelHistoryEntry]()),
      loading: createSignal(false),
      error: createSignal(""),
      selectedEntry: createSignal(none(int)),
      disposeProc: dispose,
    )
    vm.bindReplayStore(store)
    vm
