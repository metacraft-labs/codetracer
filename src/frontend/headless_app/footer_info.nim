## headless_app/footer_info.nim — THE STATUS BAR'S FILE INFO, for the native
## front-ends.
##
## The desktop's status bar opens with the current file's language and
## encoding (`isonim_status_view`: `#file-info-status`, "Python | UTF-8";
## `ui/status.statusBaseModel` reads `toName(editor.lang)` and the editor's
## encoding, which is always UTF-8 — `utils.nim`), and only AFTER them come
## the bottom auto-hide labels (`#auto-hide-bottom-strip`), then the location
## on the right — measured on the real desktop
## (`plat49-panes-capture.spec.ts`: file info at x 10..327, the labels from
## 327). The terminal's status row and GPUI's footer keep that order, from
## this one answer: the language is `common_lang`'s name for the file's
## extension, the table the desktop's `fromPath` reads.

import std/strutils

from ../../common/lang import toLangFromFilename, toName

const
  FooterEncoding* = "UTF-8"
    ## The editor's encoding on every front-end (`utils.nim`'s
    ## `encoding: "UTF-8"`).
  FooterInfoSeparator* = " | "
    ## The desktop's `.separate-bar` between language and encoding.

proc footerFileInfoParts*(path: string): seq[string] =
  ## The file info's parts for the file at `path`: its language's name and
  ## the encoding. Empty with no file (the desktop draws `_` placeholders
  ## there; a native footer draws nothing and the labels start the row).
  if path.strip.len == 0:
    return @[]
  @[toName(toLangFromFilename(path)), FooterEncoding]

proc footerFileInfoText*(path: string): string =
  ## `Python | UTF-8`, or "" with no file.
  footerFileInfoParts(path).join(FooterInfoSeparator)
