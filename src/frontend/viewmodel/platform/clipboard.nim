## The clipboard facade.
##
## Desktop: Electron's `clipboard`. Web: the async Clipboard API, write only.
## Container: the browser's clipboard, because the shell is the tab.
##
## ## Why write and read are separate capabilities
##
## `renderer.nim` today pairs `clipboardCopy` and `clipboardPaste` as if they
## were one facility. They are not, and the asymmetry is a platform fact rather
## than an implementation detail: a browser grants `writeText` on a user
## gesture and gates `readText` behind a permission prompt the product does not
## want to show. A single `capClipboard` would leave a Paste menu item present
## and inert, which is worse than absent — Noir-Studio.md §1a.2's whole point
## is that an action absent for a reason is the correct behaviour.
##
## ## Why it is async even on the desktop
##
## Electron's clipboard is synchronous and the browser's is not. Signature
## follows the harder platform, per NS1's "no capability assumes synchronous,
## in-process access"; the desktop instantiation returns an already-resolved
## future and pays nothing for it.

import ./outcome
import ./capabilities

export outcome

type
  ClipboardFacade* {.requiresInit.} = ref object
    ## `{.requiresInit.}` for the reason spelled out on `FileSystemFacade` in
    ## `fs.nim`: without it, an unassigned field is `nil` rather than a compile
    ## error, and an operation that only makes sense in-process could be added
    ## without `host/remote_stub.nim` noticing.
    profile*: PlatformProfile

    writeText*: proc(text: string): PlatformFuture[PlatformOutcome[Nothing]]
    readText*: proc(): PlatformFuture[PlatformOutcome[string]]

    writeHtml*: proc(html, plainText: string): PlatformFuture[PlatformOutcome[Nothing]]
      ## `plainText` is not optional: a clipboard entry with no text fallback
      ## pastes as nothing in most targets, and every platform can supply one.

proc unavailableClipboard*(profile: PlatformProfile): ClipboardFacade =
  ClipboardFacade(
    profile: profile,
    writeText: proc(text: string): auto =
      resolvedUnsupported[Nothing]("copying to the clipboard"),
    readText: proc(): auto =
      resolvedUnsupported[string]("reading the clipboard"),
    writeHtml: proc(html, plainText: string): auto =
      resolvedUnsupported[Nothing]("copying to the clipboard"))
