## The download-and-dialogs facade.
##
## Desktop: Electron's `dialog` and a write to the chosen path. Web: an
## anchor download and the File System Access pickers. Container: the browser's
## pickers, with the bytes crossing the endpoint.
##
## ## Why "download" and "save dialog" are one module and two capabilities
##
## They are the same user intent — *get this out of the product* — reached two
## ways. On the desktop a save dialog returns a path and the caller writes to
## it; on the web there is no path and the bytes go straight to the browser's
## download machinery. A caller that wants to hand the user a file should ask
## for `offerFile` and let the instantiation decide which of those it is. The
## path-returning `saveFileDialog` stays available for the desktop-only flows
## that genuinely need a path afterwards, and it is capability-gated so the web
## build cannot reach for it by accident.
##
## This is also where NS1's archive export (Noir-Studio.md §6.2) lands: "your
## work leaves with you" is `offerFile` over a zip, and it needs no git engine.

import ./outcome
import ./capabilities

export outcome

type
  FileFilter* = object
    name*: string
      ## Shown in the dialog's type dropdown, e.g. "Noir sources".
    extensions*: seq[string]
      ## Without the leading dot. `@["*"]` means everything.

  OpenDialogOptions* = object
    title*: string
    defaultPath*: string
    filters*: seq[FileFilter]
    allowMultiple*: bool

  SaveDialogOptions* = object
    title*: string
    suggestedName*: string
      ## Not `defaultPath`: the web has no path to default to, and a caller
      ## that supplies one is writing desktop-only code without noticing.
    defaultDirectory*: string
      ## A hint the desktop honours and the web ignores. Separate from the
      ## name so ignoring it costs the caller nothing.
    filters*: seq[FileFilter]

  DownloadFacade* {.requiresInit.} = ref object
    ## `{.requiresInit.}` for the reason spelled out on `FileSystemFacade` in
    ## `fs.nim`: without it, an unassigned field is `nil` rather than a compile
    ## error, and an operation that only makes sense in-process could be added
    ## without `host/remote_stub.nim` noticing.
    profile*: PlatformProfile

    offerFile*: proc(suggestedName: string; content: seq[byte];
                     mimeType: string): PlatformFuture[PlatformOutcome[Nothing]]
      ## Hand the user a file, however this platform does that. Succeeds when
      ## the platform has accepted it — not when the user has finished with
      ## it, which no platform reports.
    offerText*: proc(suggestedName, content,
                     mimeType: string): PlatformFuture[PlatformOutcome[Nothing]]

    openFileDialog*: proc(options: OpenDialogOptions
                         ): PlatformFuture[PlatformOutcome[seq[string]]]
      ## An empty seq means the user cancelled — a normal outcome, not
      ## `pkCancelled`. Reserving the error channel for actual errors is what
      ## keeps callers from treating a cancel as a failure to report.
    saveFileDialog*: proc(options: SaveDialogOptions
                         ): PlatformFuture[PlatformOutcome[string]]
      ## Empty string means cancelled, for the same reason.
    pickDirectory*: proc(options: OpenDialogOptions
                        ): PlatformFuture[PlatformOutcome[string]]

proc unavailableDownload*(profile: PlatformProfile): DownloadFacade =
  DownloadFacade(
    profile: profile,
    offerFile: proc(suggestedName: string; content: seq[byte];
                    mimeType: string): auto =
      resolvedUnsupported[Nothing]("downloading files"),
    offerText: proc(suggestedName, content, mimeType: string): auto =
      resolvedUnsupported[Nothing]("downloading files"),
    openFileDialog: proc(options: OpenDialogOptions): auto =
      resolvedUnsupported[seq[string]]("the file picker"),
    saveFileDialog: proc(options: SaveDialogOptions): auto =
      resolvedUnsupported[string]("the save dialog"),
    pickDirectory: proc(options: OpenDialogOptions): auto =
      resolvedUnsupported[string]("the directory picker"))
