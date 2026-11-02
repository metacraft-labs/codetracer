## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI.
## See `host/native_host.nim`'s header for the full rule.
##
## host/terminal_cache.nim — PLAT-71 (CodeTracer-TUI-Terminal-Adaptation.md
## §4.7): the per-terminal cache, `<state root>/terminal-profiles.json`.
##
## What it is for: to make frame 0 right on a slow link BEFORE the answers
## arrive. It is never a substitute for asking — the round still runs on
## every start, and a live answer always replaces a cached one (TA-12, in
## `capabilities.resolveCapabilities`). What is remembered and how it is
## keyed is `app/theme/terminal_profile`'s (pure); this module only reads and
## writes the file. A file that cannot be read is reported and LEFT AS IT IS
## (the `tui-layout.json` rule): it is not overwritten with a fresh one.

when defined(js):
  {.error: "src/frontend/tui/host is native-only.".}

import std/[os, times]

import ../../viewmodel/host/native_state
import ./capabilities

export capabilities

const TerminalCacheFile* = "terminal-profiles.json"

proc terminalCachePath*(): string =
  nativeStateRoot() / TerminalCacheFile

type
  CacheLoad* = object
    entries*: seq[CachedProfile]
    readable*: bool
      ## False when the file exists and is not a cache — then it is never
      ## written over.
    message*: string

proc loadTerminalCache*(): CacheLoad =
  let path = terminalCachePath()
  result.readable = true
  if not fileExists(path):
    return
  var text = ""
  try:
    text = readFile(path)
  except CatchableError as e:
    result.readable = false
    result.message = "the terminal cache could not be read: " & path & ": " &
                     e.msg
    return
  let (ok, entries, why) = decodeCache(text)
  if not ok:
    result.readable = false
    result.message = "the terminal cache is not one (" & why & "), left as it " &
                     "is: " & path
    return
  result.entries = entries

proc nowSeconds*(): int64 = getTime().toUnix()

proc cacheKeyOf*(env: TerminalEnv): string =
  ## §4.7's key: what the environment says BEFORE any answer.
  var mux: seq[string] = @[]
  if env.tmux.len > 0: mux.add "tmux"
  if env.sty.len > 0: mux.add "screen"
  if env.zellij.len > 0: mux.add "zellij"
  cacheKey(env.term, env.termProgram, env.termProgramVersion, mux,
           env.sshConnection.len > 0 or env.sshTty.len > 0,
           isUtf8Locale(effectiveLocale(env)))

proc cacheEntryOf*(key: string; probe: TerminalProbe;
                   caps: TerminalCapabilities): CachedProfile =
  ## What a session that was answered remembers.
  result = CachedProfile(key: key, identityName: caps.identity.name,
                         identityVersion: caps.identity.version,
                         sync2026: (if probe.sync2026Answered: probe.sync2026
                                    else: -1),
                         grapheme2027: (if probe.grapheme2027Answered:
                                          probe.grapheme2027 else: -1),
                         truecolor: probe.truecolor or probe.tmuxRgb,
                         rttMs: (if probe.rttMeasured: probe.rttMs else: -1),
                         stampSec: nowSeconds())
  result.widths = noWidthAnswers()
  var i = 0
  for p in WidthProbe:
    if i < probe.cprAnswers.len:
      result.widths[p] = probe.cprAnswers[i]
    inc i

proc saveTerminalCache*(entries: seq[CachedProfile]): string =
  ## "" on success, else why not.
  writeStaged(terminalCachePath(), encodeCache(entries))
