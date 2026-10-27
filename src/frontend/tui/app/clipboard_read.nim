## clipboard_read.nim — PLAT-68: PASTE READS THE TERMINAL'S CLIPBOARD WHERE THE
## TERMINAL ANSWERS.
##
## A terminal front-end cannot read the system clipboard itself; it can ASK
## the terminal, with xterm's OSC 52 query (`ESC ] 52 ; c ; ? BEL`,
## "Manipulate Selection Data",
## https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Operating-System-Commands),
## and a terminal that allows it answers `ESC ] 52 ; c ; <base64> BEL` (or ST).
## Many do not — xterm unless `allowWindowOps`, WezTerm, the harness's
## libvterm — and say nothing. So a paste is a short conversation:
##
##   1. the paste operation is HELD and the query is written with the next
##      frame (`PendingPaste`, `ClipboardRead.requested`);
##   2. an answer within `ClipboardReadWaitMs` is the text pasted, and is kept
##      as the internal clipboard too;
##   3. silence until the deadline pastes the INTERNAL clipboard (what this
##      session last copied), and the terminal is not asked again this
##      session (`crsSilent`) — a paste must not wait on every key for a
##      terminal that never answers.
##
## Pure: the bytes, the reply's decoding and the state; the host writes and
## reads, the runtime performs the paste.

import std/[base64, strutils]

import codetracer_embed

const
  ClipboardQuery* = "\e]52;c;?\a"
    ## The OSC 52 read: the terminal is asked for the `c` (clipboard)
    ## selection's contents.
  ClipboardReplyPrefix* = "\e]52;"
  ClipboardReadWaitMs* = 300'i64
    ## How long a paste waits for the terminal's answer: a reply is one round
    ## trip on a local terminal, and a terminal that does not answer never
    ## will. (The framer holds a clipboard reply up to
    ## `terminal_driver.MaxClipboardReplyBytes`.)

type
  ClipboardReadSupport* = enum
    crsUnknown   ## not asked yet this session
    crsAnswers   ## answered a query
    crsSilent    ## did not answer within the wait: not asked again

  PasteTarget* = enum
    ptEditor     ## the editor's document (`clipboard-paste`)
    ptPrompt     ## the command line or the find field (`input.paste`)
    ptPalette    ## the palette's field (`input.paste`)

  PendingPaste* = object
    ## A paste held while the terminal is asked for its clipboard.
    active*: bool
    target*: PasteTarget
    resolution*: EditingResolution
      ## The editor's paste resolution, run once the text is known.

  ClipboardRead* = object
    support*: ClipboardReadSupport
    requested*: bool
      ## The runtime wants the query written with the next frame.
    open*: bool
      ## The query was written; the answer is awaited until `deadlineMs`.
    deadlineMs*: int64
    pending*: PendingPaste

func asks*(c: ClipboardRead): bool =
  ## Whether a paste should ask the terminal first.
  c.support != crsSilent

func isClipboardReply*(token: string): bool =
  token.startsWith(ClipboardReplyPrefix)

func decodeClipboardReply*(token: string): tuple[ok: bool, text: string] =
  ## The text of an OSC 52 answer, `ESC ] 52 ; <selection> ; <base64>`
  ## ended by BEL or ST. A reply that is not base64 (or is the query's `?`
  ## echoed back) is not an answer.
  if not token.isClipboardReply:
    return (false, "")
  var body = token[ClipboardReplyPrefix.len .. ^1]
  if body.endsWith("\a"): body.setLen(body.len - 1)
  elif body.endsWith("\e\\"): body.setLen(body.len - 2)
  let semi = body.find(';')
  if semi < 0:
    return (false, "")
  let payload = body[semi + 1 .. ^1]
  if payload == "?":
    return (false, "")
  try:
    (true, base64.decode(payload))
  except ValueError:
    (false, "")
