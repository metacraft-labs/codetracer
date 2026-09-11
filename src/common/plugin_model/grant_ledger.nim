## plugin_model/grant_ledger.nim — PLAT-10 deliverable 3: "the capability grant
## recorded per plugin, inspectable and revocable".
##
## PLAT-8 built the model (`capabilities.decide`) and its disclosure
## (`describeGrants`). Both are about ONE moment: the manifest says what the
## plugin may do and the policy answers. Neither remembers anything, so
## "the user granted `process` last month" was not a fact the product held —
## which is the whole of what this module adds, and the whole of what makes
## revocation possible at all.
##
## ## A REVOKED GRANT IS NOT A RECORD, IT IS A NARROWER `GrantSet`
##
## The one design decision here, and the reason the rest of the file is small.
##
## The tempting shape is a `revoked` flag consulted wherever a capability is
## used. That is theatre: it puts a second decision beside
## `capabilities.decide`, and the day somebody adds a seventh power they write
## the `decide` arm and forget the flag. Worse, it is unfalsifiable from the
## outside — a suite can only assert that the RECORD says revoked.
##
## So revocation produces a `GrantSet` with the capability **removed**, and
## that narrowed set is what `plugin_api.grantsOf` hands to `decide`. There is
## no new gate, no new predicate and no second opinion: a revoked `process`
## plugin is refused by the same `if capProcess notin g.capabilities` arm that
## refuses a plugin that never asked for it, and the refusal is measurable as
## an EFFECT — the child never runs.
##
## ## UNDECIDED IS NOT GRANTED
##
## `grantedCapabilities` intersects the declared set with the set the ledger
## says `gdGranted`. A capability the ledger has never seen is therefore
## REFUSED, and that is the property that makes an upgrade safe:
##
##   a plugin installed at 1.0.0 declaring `fs:read`, granted, then upgraded to
##   2.0.0 whose manifest adds `process` — `process` is undecided, so the new
##   power is not inherited from the old consent.
##
## `grantDeclared` is the explicit acceptance step, and it is deliberately
## **not** a blanket overwrite: it records `grant` for capabilities that are
## UNDECIDED and leaves a `gdRevoked` entry alone. Reinstalling a plugin
## therefore does not resurrect a grant the user took back, which is the
## cheapest way for a revocation to quietly stop meaning anything.
##
## ## THE LEDGER IS APPEND-ONLY AND THE LAST ENTRY WINS
##
## History is the inspectable half — "a user who granted `process` last month
## must be able to see that and take it back" is a sentence about a record with
## a date in it. So `revoke` appends rather than deleting, `stateOf` reads the
## last entry for the pair, and `describe` prints the whole history in order.
##
## ## PURE
##
## No filesystem, no clock. The timestamp is a string the caller supplies, for
## the reason `capabilities.nim` is pure: this file runs in `common-units`,
## which links no renderer and opens no handle, and every assertion below is
## made without a machine. `src/ct/launch/grant_store.nim` is the half that
## reads and writes a file, and it is somewhere else on purpose.

import std/strutils

import ./capabilities
import ./diagnostics

type
  GrantDecision* = enum
    gdGranted = "grant"
    gdRevoked = "revoke"

  GrantEntry* = object
    plugin*: PluginId
    capability*: Capability
    decision*: GrantDecision
    at*: string
      ## When the decision was taken, as the caller spelled it. Never parsed —
      ## it is shown to a user and compared for equality by tests, and a
      ## ledger that could fail to load because a date did not parse would be
      ## a ledger that fails OPEN on the day the format drifts.
    note*: string
      ## Free text, last field on the line. Why the decision was taken.

  GrantLedger* = object
    entries*: seq[GrantEntry]

  GrantState* = enum
    gsUndecided
    gsGranted
    gsRevoked

  LedgerParse* = object
    ledger*: GrantLedger
    problems*: seq[string]
      ## One per unusable line, naming the line number and what was wrong. A
      ## ledger with problems is still a ledger: the lines that DID parse are
      ## kept, because dropping a whole file over one bad line would silently
      ## re-grant every plugin in it (undecided is refused, but an empty
      ## ledger also makes `grantDeclared` re-grant everything on the next
      ## acceptance). The problems are reported, never swallowed.

const
  LedgerHeader* = "# codetracer plugin capability grants, v1"
  LedgerFieldSeparator* = '\t'
    ## TAB, so a `note` may contain spaces and a reader needs no quoting rules.

# ---------------------------------------------------------------------------
# Reading the ledger
# ---------------------------------------------------------------------------

func stateOf*(ledger: GrantLedger; plugin: PluginId;
              cap: Capability): GrantState =
  ## THE LAST ENTRY WINS. Scanned backwards so the answer is O(1) in the common
  ## case and so the rule is visible rather than implied by a fold.
  for i in countdown(ledger.entries.high, 0):
    let e = ledger.entries[i]
    if e.plugin == plugin and e.capability == cap:
      return (if e.decision == gdGranted: gsGranted else: gsRevoked)
  gsUndecided

func decidedAt*(ledger: GrantLedger; plugin: PluginId;
                cap: Capability): string =
  ## When the decision that is in force was taken. Empty when undecided.
  for i in countdown(ledger.entries.high, 0):
    let e = ledger.entries[i]
    if e.plugin == plugin and e.capability == cap:
      return e.at
  ""

func grantedCapabilities*(declared: set[Capability]; ledger: GrantLedger;
                          plugin: PluginId): set[Capability] =
  ## The intersection. A capability the manifest does not declare is not
  ## grantable — a ledger entry for it is inert rather than a widening — and a
  ## declared capability the ledger has not granted is refused.
  for c in Capability:
    if c notin declared: continue
    if ledger.stateOf(plugin, c) == gsGranted:
      result.incl c

func effectiveGrants*(declared: GrantSet; ledger: GrantLedger;
                      plugin: PluginId): GrantSet =
  ## The `GrantSet` the host hands to `decide`.
  ##
  ## ONLY `capabilities` IS NARROWED, and the declared target sets are carried
  ## through unchanged. That is not laziness: `decide` tests the capability
  ## FIRST on every arm, so a revoked `process` is refused before
  ## `declaresExecutable` is ever consulted, and `describeGrants` iterates the
  ## capabilities and prints the declared set only for the ones still present.
  ## Clearing the sets as well would mean two places that have to agree about
  ## what revocation removes.
  result = declared
  result.capabilities = grantedCapabilities(declared.capabilities, ledger,
                                            plugin)

func plugins*(ledger: GrantLedger): seq[PluginId] =
  ## Every plugin the ledger has an opinion about, in first-mention order.
  for e in ledger.entries:
    if e.plugin notin result: result.add e.plugin

func describe*(ledger: GrantLedger; plugin: PluginId): string =
  ## What a user reads when they ask what this plugin was granted, and when.
  ## The history is in the answer — "granted 2026-08-14, revoked 2026-09-11"
  ## is the fact the deliverable is about, and a view that showed only the
  ## current state could not tell a user they had ever granted it.
  var lines: seq[string] = @[]
  for e in ledger.entries:
    if e.plugin != plugin: continue
    lines.add "  " & (if e.decision == gdGranted: "granted" else: "REVOKED") &
      " " & $e.capability & " at " & e.at &
      (if e.note.len > 0: " — " & e.note else: "")
  if lines.len == 0:
    return "plugin '" & plugin & "': no capability decision has been recorded"
  var current: seq[string] = @[]
  for c in Capability:
    if ledger.stateOf(plugin, c) == gsGranted: current.add $c
  "plugin '" & plugin & "':\n" & lines.join("\n") & "\n  in force now: " &
    (if current.len == 0: "(nothing)" else: current.join(", "))

# ---------------------------------------------------------------------------
# Writing the ledger
# ---------------------------------------------------------------------------

proc record*(ledger: var GrantLedger; plugin: PluginId; cap: Capability;
             decision: GrantDecision; at, note: string) =
  ledger.entries.add GrantEntry(plugin: plugin, capability: cap,
                                decision: decision, at: at, note: note)

proc grant*(ledger: var GrantLedger; plugin: PluginId; cap: Capability;
            at: string; note = ""): bool {.discardable.} =
  ## `true` when this changed the state in force. A second `grant` of a
  ## capability already granted appends nothing, so an acceptance step that
  ## runs on every start does not grow the file without bound.
  if ledger.stateOf(plugin, cap) == gsGranted: return false
  ledger.record(plugin, cap, gdGranted, at, note)
  true

proc revoke*(ledger: var GrantLedger; plugin: PluginId; cap: Capability;
             at: string; note = ""): bool {.discardable.} =
  ## `true` when this changed the state in force.
  ##
  ## REVOKING AN UNDECIDED CAPABILITY IS RECORDED, not ignored, and the
  ## asymmetry with `grant` is deliberate. An undecided capability is already
  ## refused, so the entry changes no behaviour today — what it changes is
  ## TOMORROW: `grantDeclared` grants what is undecided, so without the entry a
  ## user who pre-emptively revoked a capability would find the next
  ## acceptance step granting it.
  if ledger.stateOf(plugin, cap) == gsRevoked: return false
  ledger.record(plugin, cap, gdRevoked, at, note)
  true

proc grantDeclared*(ledger: var GrantLedger; plugin: PluginId;
                    declared: set[Capability]; at: string; note = ""): int
                    {.discardable.} =
  ## The acceptance step: record a grant for every capability this manifest
  ## declares that has NO decision yet. Returns how many were recorded.
  ##
  ## It leaves `gsRevoked` alone. See the module header — an acceptance that
  ## overwrote a revocation would make revocation last until the next install.
  for c in Capability:
    if c notin declared: continue
    if ledger.stateOf(plugin, c) != gsUndecided: continue
    ledger.record(plugin, c, gdGranted, at, note)
    inc result

proc forget*(ledger: var GrantLedger; plugin: PluginId): int {.discardable.} =
  ## Drop every entry for a plugin. This is what `ct uninstall` means for the
  ## ledger, and it is the ONE operation that is not append-only — because a
  ## ledger that kept grants for plugins that are gone would re-grant them on
  ## reinstall without anybody deciding anything.
  var kept: seq[GrantEntry] = @[]
  for e in ledger.entries:
    if e.plugin == plugin: inc result
    else: kept.add e
  ledger.entries = kept

# ---------------------------------------------------------------------------
# Serialisation
# ---------------------------------------------------------------------------

func render*(ledger: GrantLedger): string =
  ## `<decision>\t<plugin>\t<capability>\t<at>\t<note>` per entry, in order.
  var lines: seq[string] = @[LedgerHeader]
  for e in ledger.entries:
    lines.add [$e.decision, e.plugin, $e.capability, e.at, e.note].join(
      $LedgerFieldSeparator)
  lines.join("\n") & "\n"

func parseLedger*(text: string): LedgerParse =
  ## Total. Every unusable line becomes a problem naming its number; nothing
  ## raises, because this is read at start-up and a start-up that dies on a
  ## stray byte in a state file is worse than one that says what it could not
  ## read.
  var lineNo = 0
  for rawLine in text.splitLines():
    inc lineNo
    let line = rawLine.strip(leading = false, trailing = true, chars = {'\r'})
    if line.len == 0: continue
    if line[0] == '#': continue
    let parts = line.split(LedgerFieldSeparator)
    if parts.len < 4:
      result.problems.add "line " & $lineNo & ": expected at least four " &
        "tab-separated fields (decision, plugin, capability, when), got " &
        $parts.len
      continue
    var decision: GrantDecision
    var decisionOk = false
    for d in GrantDecision:
      if $d == parts[0]:
        decision = d
        decisionOk = true
    if not decisionOk:
      result.problems.add "line " & $lineNo & ": '" & parts[0] &
        "' is neither 'grant' nor 'revoke'"
      continue
    if parts[1].len == 0:
      result.problems.add "line " & $lineNo & ": the plugin id is empty"
      continue
    var cap: Capability
    var capOk = false
    for c in Capability:
      if $c == parts[2]:
        cap = c
        capOk = true
    if not capOk:
      var known: seq[string] = @[]
      for c in Capability: known.add $c
      result.problems.add "line " & $lineNo & ": '" & parts[2] &
        "' is not a capability — §8.1.2's set is " & known.join(", ")
      continue
    result.ledger.entries.add GrantEntry(
      plugin: parts[1], capability: cap, decision: decision, at: parts[3],
      note: (if parts.len > 4: parts[4 .. ^1].join($LedgerFieldSeparator)
             else: ""))
