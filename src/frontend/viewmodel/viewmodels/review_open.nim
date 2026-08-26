## viewmodels/review_open.nim
##
## The one way a ViewModel asks CodeTracer to read a review dataset off disk.
##
## AA-3's constraint, from `Agent-Activity-Panel.milestones.org`: selecting an
## evidence call "enters a review over that dataset **through the ordinary
## review-entry routine**.  Not a second way to open a review; the same one,
## reached from the feed."  This type is the ViewModel-side half of that: it
## carries the *request*, and the host answers it by driving exactly the path
## `ct review <PATH>` already drives —
##
##   read the JSON with `index/review_dataset.readReviewDatasetFile` (the same
##   read `index/args.nim`'s `--deepreview` branch performs)
##     → `vcs.openReviewDataset`
##       → `vcs.startDeepReviewNavigation`
##         → `review_entry.enterReview`
##
## — with nothing new between the file and the panels.  Modelled on
## `trace_open.nim`, which plays the same role for recordings, and kept apart
## from any one panel for the same reason: a second surface that wants to open
## a review should reach for this rather than grow another path.
##
## ## Why a request/answer pair rather than a synchronous read
##
## The renderer cannot read files: the dataset is read by the Electron main
## process, which also *keeps* it (`index/config.reviewSourceLookup` serves
## the review's file text out of `startOptions.deepReview`).  So a click has
## to cross the process boundary in both directions, and the answer arrives
## later — hence a service that sends a request and a separate `apply…` call
## that lands the result.

type
  ReviewDatasetRequestKind* = enum
    ## Why the dataset is being read.  The distinction is not cosmetic: a
    ## dataset carries every reviewed file's full source text, so shipping one
    ## across the process boundary for each evidence call in a session — when
    ## all the card needs is a file count and a commit — would be paid on
    ## every session load.
    rdrInspect = "inspect"
      ## Answer with the dataset's *shape* only.
    rdrOpen = "open"
      ## Read it and enter a review over it.

  ReviewDatasetRequest* = object
    ## A dataset to read.  Flat strings only, for the reason
    ## `TraceOpenRequest` is flat: this crosses from headless ViewModel code
    ## into the renderer's IPC.
    anchorId*: string
      ## The feed entry that asked, so the answer can be routed back to it.
    datasetPath*: string
      ## Exactly the path the agent's command named.  It may be the
      ## `review.json` itself or the directory `ct review collect --output`
      ## wrote — the host resolves that the same way `ct review <PATH>` does,
      ## so the two spellings cannot diverge.
    kind*: ReviewDatasetRequestKind

  ReviewOpenService* = ref object
    ## The host's implementation of "read this".  Nil-safe on purpose: a
    ## headless ViewModel is fully constructible without a renderer, and a
    ## test that never wires one gets silence rather than a crash.
    requestProc*: proc(request: ReviewDatasetRequest)

proc requestDataset*(service: ReviewOpenService;
                     request: ReviewDatasetRequest) =
  if not service.isNil and not service.requestProc.isNil:
    service.requestProc(request)
