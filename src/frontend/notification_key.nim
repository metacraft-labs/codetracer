## What makes two notifications "the same one" for the status bar.
##
## The status bar shows a sentence once however many times it arrives
## (`status.onNotification`). Comparing the raw text was not enough: a
## replay whose every worker failed to start reported each worker's failure
## in rr's words, and rr names the address it was at, so the same failure
## from three workers arrived as three sentences differing only in a
## `0x7ffd…` and stacked three toasts. The key replaces every hexadecimal
## number written with a `0x` prefix by `0x…`, so those compare equal, while
## any difference in the words themselves still keeps two notices apart.

import std/strutils

proc notificationKey*(text: string): string =
  ## `text` with each `0x`-prefixed hexadecimal number replaced by `0x…`.
  ## A `0x` inside a longer identifier (`a0x1`) is left alone: it is part of
  ## a name, not an address.
  result = newStringOfCap(text.len)
  var i = 0
  while i < text.len:
    let startsNumber =
      i + 2 < text.len and text[i] == '0' and text[i + 1] in {'x', 'X'} and
      text[i + 2] in HexDigits and (i == 0 or text[i - 1] notin IdentChars)
    if startsNumber:
      result.add "0x…"
      i += 2
      while i < text.len and text[i] in HexDigits:
        inc i
    else:
      result.add text[i]
      inc i
