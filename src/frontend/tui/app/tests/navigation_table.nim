## navigation_table.nim — test support: CodeTracer-TUI.md §4.2's table AS THE
## TERMINAL'S SUITES READ IT, built from the shipped data.
##
## Since PLAT-68 the table is `viewmodel/keymap/navigation_keymap.
## NavigationRows` — the Vim and Kakoune bases' navigation layer, rows naming
## OPERATIONS, resolved by the one router. The §4.2 oracle and the modal
## suites still speak §4.1's modes and the terminal's `KeyAction`s; this module
## derives that view from the rows, one binding per (row, navigation mode),
## each row's operation read back through `operation_dispatch` — the table the
## runtime dispatches by. Nothing here is a second copy of a row: delete a row
## from the data and it is gone from this view too.
##
## No stand-ins: the shipped rows, the shipped normaliser, the shipped
## operation table.

import std/strutils

import codetracer_embed

export codetracer_embed

import ../input/keymap
import ../input/modal_state
import ../input/operation_dispatch

type
  NavBinding* = object
    mode*: ModalMode
    spelling*: string
      ## §4.2's own text for the key (`rf`, `t <tick> Enter`, `Ctrl+w h`).
    chords*: seq[string]
      ## Canonical key names, as the router matches them.
    action*: KeyAction

  NavKeymap* = object
    bindings*: seq[NavBinding]

const
  SpecSpellings*: seq[tuple[chords, spec: string]] = @[
    ## The rows whose §4.2 cell is not their chords: what the oracle reads
    ## the cell as.
    ("r f", "rf"), ("r c", "rc"), ("t", "t <tick> Enter"),
  ]

proc isTextEntry*(state: ModalState): bool =
  ## Whether the mode currently owns every printable key.
  ##
  ## COMMAND always does; SEARCH does only while its prompt is open. The
  ## modal machine's own answer, kept here for the suites that model it: since
  ## PLAT-68 the product's "which keys are text" is the router's (a pushed
  ## prompt layer's `textEntry`, `keymap_router`).
  case state.mode
  of mmCommand: true
  of mmSearch: state.phase == spTyping
  of mmNormal, mmInspect: false

func modalOf(m: NavigationMode): ModalMode =
  case m
  of nmNormal: mmNormal
  of nmCommand: mmCommand
  of nmSearch: mmSearch
  of nmInspect: mmInspect

proc navigationKeymap*(): NavKeymap =
  for row in NavigationRows:
    let names = normalizeChordSequence(row.chords)
    var spelling = names
    for (chords, spec) in SpecSpellings:
      if chords == row.chords: spelling = spec
    for m in row.navModes:
      result.bindings.add NavBinding(mode: modalOf(m), spelling: spelling,
                                     chords: names.splitWhitespace(),
                                     action: actionOfOperation(row.operation))

proc bindingsFor*(km: NavKeymap; mode: ModalMode): seq[NavBinding] =
  for b in km.bindings:
    if b.mode == mode: result.add b

proc bindingsOf*(km: NavKeymap; action: KeyAction): seq[NavBinding] =
  for b in km.bindings:
    if b.action == action: result.add b

proc prefixChords*(km: NavKeymap; mode: ModalMode): seq[string] =
  ## Every chord that only STARTS a sequence in `mode`, derived from the
  ## table.
  for b in km.bindings:
    if b.mode == mode and b.chords.len > 1 and b.chords[0] notin result:
      result.add b.chords[0]

# ---------------------------------------------------------------------------
# Resolution: the SHIPPED router, in the modal machine's terms
# ---------------------------------------------------------------------------

type
  NavResolution* = object
    ## One key through the router, read as §4.1 / §4.2 speak: `kind` is
    ## `action`, `pending`, `pending-abandoned`, `pending-timed-out`, `text`
    ## or `none`.
    kind*: string
    action*: KeyAction
    spelling*: string
    character*: string
    pending*: string
      ## The status line's pending indicator after the key (`g…`).
    timedOut*: bool
    reason*: string
      ## `inert-in-mode`'s sentence (Mode-Transitions §8.1) — the runtime's
      ## `performAction` answer for an action the product mode has no use
      ## for.

  NavResolver* = object
    ## The router a terminal runs under the Vim base, focused on the call
    ## trace (a list: no editor table between the key and §4.2).
    router*: KeymapRouter

proc newNavResolver*(base = bkVim): NavResolver =
  NavResolver(router: initKeymapRouter(base, KeyDelivery(
    frontEnd: feTerminal, platform: pkLinux, keyProtocol: kpLegacy)))

func navModeOf(m: ModalMode): NavigationMode =
  case m
  of mmNormal: nmNormal
  of mmCommand: nmCommand
  of mmSearch: nmSearch
  of mmInspect: nmInspect

proc resolve*(r: var NavResolver; state: ModalState; token: string;
              nowMs: int64; product = pmDebug): NavResolution =
  ## `token` (a byte token, decoded by `keyName`) in `state`: the scope path
  ## is the call trace, with the open prompt's field on it while the mode
  ## takes text — the path the runtime's own producer builds.
  var path = @[element(ekWindow, "window"), element(ekTab, "tab:1"),
               pane("calltrace")]
  if state.isTextEntry:
    if state.mode == mmCommand:
      path = @[element(ekWindow, "window"), element(ekOverlay, "command-line"),
               element(ekInput, "prompt")]
    else:
      path.add element(ekOverlay, "find")
      path.add element(ekInput, "find-query")
  let facts = SessionFacts(product: product, editor: sourceViewFacts())
  let res = r.router.route(facts, path, navModeOf(state.mode), keyName(token),
                           nowMs)
  result = NavResolution(spelling: res.spelling, character: res.character,
                         pending: r.router.pendingLabel, timedOut: res.timedOut,
                         action: kaNone)
  case res.kind
  of erOperation:
    result.kind = "action"
    result.action = actionOfOperation(
      if res.argument.len > 0: res.operation & "(" & res.argument & ")"
      else: res.operation)
    if not appliesIn(result.action, product):
      result.kind = "inert-in-mode"
      result.reason = inertReason(result.action, product)
  of erPending: result.kind = "pending"
  of erCharacter: result.kind = "text"
  of erNothing:
    result.kind = case res.reason
                  of nrPrefixAbandoned: "pending-abandoned"
                  of nrPrefixTimedOut: "pending-timed-out"
                  else: "none"
