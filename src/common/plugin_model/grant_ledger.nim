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
## ## THE ROW GRAMMAR IS CLOSED, BECAUSE THE PLUGIN FIELD IS A PLUGIN'S OWN TEXT
##
## The ledger is one row per line with a TAB between fields, and until
## 2026-09-13 nothing checked that a field could be written in it. `plugin` is a
## `PluginId`, and a `PluginId` is `plugin.json`'s `id` — a string a third party
## writes. Measured on 2026-09-13, before this existed:
##
##     id: "evil-plugin\ngrant\t<victim>\tprocess\t<when>\t<note>"
##     ONE `grant` call for `fs:read`  -> 1 row emitted
##     `parseLedger` reads it back     -> 1 row, 1 problem
##       the VICTIM, declaring {process}: granted {process}
##       the EVIL plugin, declaring {fs:read}: granted {}
##       `decide(spawn)` for the victim: PERMITTED
##
## The attacker TRADES AWAY its own grant to do it, and the single problem reads
## like an ordinary corrupt line. `process` is the capability PLAT-8 models as
## subsuming every other, held by a plugin nobody granted anything.
##
## The answer is a closed grammar and not an encoder, which is
## `project_trust.representableField`'s decision taken again for the reason it
## was taken there: an encoder is a second grammar with a second parser that
## must agree with the first for ever over rows written by older builds, while a
## refusal has one rule and no version. So `representableGrantField` refuses a
## TAB, a NEWLINE or a CARRIAGE RETURN in `plugin`, `at` or `note`; `record` is
## the one constructor and enforces it, so a `GrantEntry` literal built
## elsewhere cannot get in through `grant`; `parseLedger` goes through the same
## `record`; and a row with more fields than the grammar declares is a PROBLEM
## rather than a rejoined note.
##
## THE PRODUCER REFUSES FIRST, AND THE TWO REFUSALS HAVE DISJOINT EVIDENCE
## (Verification-Harness-Traps §16a). `manifest.parseManifest` refuses an `id`
## outside `contributed_pane_id.segmentProblem`'s closed charset, so a hostile
## id never becomes a loaded plugin at all; this refusal is what stands between
## the ledger and a `record` reached any other way — a suite, a future call
## site, a `GrantLedger` built by hand. Each has a case only it can satisfy:
## `acme tool` is a legal ledger field and an illegal plugin id, and an `at` or
## a `note` carrying a newline is nothing the manifest has an opinion about.
##
## AND THE PREDICATE IS THIS PACKAGE'S OWN COPY, DELIBERATELY. `project_trust`
## has the same three characters in `representableField`, and there are exactly
## TWO copies in the tree (§14b: count them, rather than believing an extraction
## is done). Sharing one would mean moving that function out of
## `project_trust.nim` — `project_trust` imports `plugin_model/capabilities`, so
## the dependency can only run that way — and PLAT-13's arms T13 and T13b quote
## its literal lines, which §16 is precisely about. The two are graded
## separately, by an arm each, in the harness that owns each ledger.
##
## ## AND A REFUSAL THAT NOBODY CAN TELL FROM A NO-OP IS A REFUSAL NOBODY HEARS
##
## Closing the grammar makes `record` refuse a row, and `grant`/`revoke`
## answered `false` for that — where `false` already meant "the decision you
## asked for is already the one in force", which is benign and which every
## caller correctly ignored. That is Verification-Harness-Traps §5a, and PLAT-13
## paid for it: a revocation reported success, wrote nothing, and the code the
## user withdrew consent from went on running. So `grant` and `revoke` answer a
## `GrantRecordOutcome`, `decisionStands` is the ONE function saying which
## non-records are benign, and neither is `{.discardable.}`.
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

  GrantRecordOutcome* = enum
    ## WHAT HAPPENED TO ONE DECISION, AS A CLOSED ENUM WITH ONE MEANING PER
    ## VALUE.
    ##
    ## `grant` and `revoke` returned a `bool {.discardable.}` until 2026-09-13.
    ## It meant "this changed the state in force", so `false` meant "the
    ## decision you asked for is already the one in force" — benign, common, and
    ## correctly ignored. Closing the row grammar gave that same `false` a second
    ## meaning — "nothing was written at all" — and the two have opposite
    ## consequences. Verification-Harness-Traps §5a is that collision, and it is
    ## recorded there from PLAT-13's landing pass, where the merged value was
    ## read as the benign one at both call sites and a revocation reported
    ## success while the code went on running.
    ##
    ## THE DIRECTION IS WHY THIS IS NOT A TIDY-UP. A grant that is not recorded
    ## fails CLOSED: nothing runs that was not going to run. A REVOCATION that is
    ## not recorded fails OPEN — the user asked for a capability to stop and was
    ## told it had. `grant_store.updateGrantLedger`'s own comment already names
    ## that as the one direction this record must never fail in.
    ##
    ## THE ZERO VALUE IS A NON-RECORD, like `GrantState`'s: a producer that
    ## forgets to set the field reports "nothing was written" rather than "it is
    ## recorded and in force".
    groNoPlugin
      ## THE DEFAULT, and the zero value. There is no plugin to record against.
      ## An empty id is also what `parseLedger` refuses in a row, so writing one
      ## would be writing a row this module cannot read back.
    groUnchanged
      ## THE DECISION ASKED FOR IS ALREADY THE ONE IN FORCE. Nothing was
      ## appended and nothing needed to be — a success for a caller, and why
      ## `decisionStands` exists rather than `recorded` alone.
    groUnwritableField
      ## A field carries a tab, a newline or a carriage return, so NOTHING WAS
      ## APPENDED and what is in force is NOT what the caller asked for. This is
      ## the value that must never be confused with `groUnchanged`.
    groRecorded
      ## One row was appended and it is in force.

  GrantDeclaredOutcome* = object
    ## The acceptance step's answer. It was a bare `int` — "how many rows were
    ## recorded" — and `0` already meant "every declared capability was already
    ## decided", which is §5a's collision one type along: a refused field would
    ## have been a second reason for the same `0`.
    ##
    ## Every capability in one call shares one `plugin`, one `at` and one `note`,
    ## so the grammar's verdict is the same for all of them: the call records
    ## every undecided capability or it records none.
    outcome*: GrantRecordOutcome
    rows*: int
      ## How many were appended.

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

func representableGrantField*(s: string): bool =
  ## MAY THIS STRING BE A FIELD OF A LEDGER ROW?
  ##
  ## THE GRAMMAR IS CLOSED AND THE ANSWER IS A REFUSAL, NOT AN ENCODER — see the
  ## module header for the measurement and for why escaping was refused. The
  ## format is one row per line with one TAB between fields, so a field carrying
  ## a TAB becomes two fields and a field carrying a NEWLINE becomes a ROW.
  ##
  ## `\r` is refused with the other two because `parseLedger` strips a trailing
  ## `\r` for CRLF files, so a `\r` INSIDE a field would survive a round trip on
  ## one platform and not on another.
  for c in s:
    if c == LedgerFieldSeparator or c == '\n' or c == '\r': return false
  true

func unrepresentableGrantFieldText*(): string =
  ## What a refusal says, in one place so the message cannot acquire two
  ## spellings (`codeText`'s rule).
  "a tab, a newline or a carriage return, which a ledger row cannot carry"

func recorded*(o: GrantRecordOutcome): bool =
  ## Did this append a row? A FUNCTION and not `o == groRecorded` at each call
  ## site (§14): a new outcome cannot become "recorded" by accident at the site
  ## somebody forgot.
  o == groRecorded

func decisionStands*(o: GrantRecordOutcome): bool =
  ## IS WHAT THE CALLER ASKED FOR WHAT IS IN FORCE NOW? — which is the question
  ## a user action has, and it is NOT `recorded`. Re-granting a decision already
  ## recorded appends nothing and is a success; a field that could not be
  ## written appends nothing and is a failure. ONE function, so the grant's
  ## reporting and the revocation's cannot come to disagree about which
  ## non-records are benign (§14).
  o in {groRecorded, groUnchanged}

func outcomeText*(o: GrantRecordOutcome): string =
  ## What a caller reports, in one place so one outcome cannot acquire two
  ## spellings. TOTAL over the enum, so a new outcome is a compile error here
  ## rather than an unreportable answer.
  case o
  of groRecorded: "recorded"
  of groUnchanged: "that decision was already the one in force"
  of groNoPlugin: "there is no plugin id to record it against"
  of groUnwritableField: "a field carries " & unrepresentableGrantFieldText()

proc record*(ledger: var GrantLedger; plugin: PluginId; cap: Capability;
             decision: GrantDecision; at, note: string): bool
             {.discardable.} =
  ## Append one row. `false`, AND NOTHING APPENDED, when any field is not
  ## representable — see `representableGrantField`.
  ##
  ## THIS ONE STAYS A `bool` BECAUSE IT HAS ONE FAILURE MODE. `grant` and
  ## `revoke` answer a `GrantRecordOutcome` because their `false` meant two
  ## different things; this function's does not — a row is appended or a field
  ## could not be written.
  ##
  ## THIS IS THE ONE PLACE THIS MODULE CONSTRUCTS A `GrantEntry`, which is what
  ## makes `render` total over what it can be handed: `grant`, `revoke`,
  ## `grantDeclared` and the suites all come through here, and `parseLedger` —
  ## the only other producer — splits on exactly the characters this refuses, so
  ## no field it yields can contain one. A third party constructing a
  ## `GrantEntry` literal and pushing it onto `entries` is outside that closure;
  ## the fields are exported because `describe` and the suites read them, and Nim
  ## has no read-only export.
  if not representableGrantField(plugin) or not representableGrantField(at) or
     not representableGrantField(note):
    return false
  ledger.entries.add GrantEntry(plugin: plugin, capability: cap,
                                decision: decision, at: at, note: note)
  true

proc grant*(ledger: var GrantLedger; plugin: PluginId; cap: Capability;
            at: string; note = ""): GrantRecordOutcome =
  ## Record a grant for ONE plugin and ONE capability, and say WHICH of the four
  ## things happened.
  ##
  ## A second `grant` of a capability already granted appends nothing, so an
  ## acceptance step that runs on every start does not grow the file without
  ## bound — and that is `groUnchanged`, which `decisionStands` calls a success.
  ##
  ## NOT `{.discardable.}`, AND `record` STILL IS. Dropping this answer is how a
  ## decision goes unrecorded in silence, so a caller that does not want it has
  ## to write `discard` and be seen doing it. `record` keeps the pragma because
  ## the suites build ledgers with it and its answer has one meaning.
  if plugin.len == 0: return groNoPlugin
  if ledger.stateOf(plugin, cap) == gsGranted: return groUnchanged
  if ledger.record(plugin, cap, gdGranted, at, note): groRecorded
  else: groUnwritableField

proc revoke*(ledger: var GrantLedger; plugin: PluginId; cap: Capability;
             at: string; note = ""): GrantRecordOutcome =
  ## `grant`'s twin, with the same four answers and the same reason for them.
  ##
  ## REVOKING AN UNDECIDED CAPABILITY IS RECORDED, not ignored, and the
  ## asymmetry with `grant` is deliberate. An undecided capability is already
  ## refused, so the entry changes no behaviour today — what it changes is
  ## TOMORROW: `grantDeclared` grants what is undecided, so without the entry a
  ## user who pre-emptively revoked a capability would find the next
  ## acceptance step granting it.
  ##
  ## AND THE OUTCOME MATTERS MOST ON THIS SIDE. A grant that is not recorded
  ## fails closed. A REVOCATION that is not recorded fails OPEN: the user asked
  ## for the capability to stop, and it does not. Everything other than
  ## `groRecorded` here has to reach the caller.
  if plugin.len == 0: return groNoPlugin
  if ledger.stateOf(plugin, cap) == gsRevoked: return groUnchanged
  if ledger.record(plugin, cap, gdRevoked, at, note): groRecorded
  else: groUnwritableField

proc grantDeclared*(ledger: var GrantLedger; plugin: PluginId;
                    declared: set[Capability]; at: string;
                    note = ""): GrantDeclaredOutcome =
  ## The acceptance step: record a grant for every capability this manifest
  ## declares that has NO decision yet, and say how many and what happened.
  ##
  ## It leaves `gsRevoked` alone. See the module header — an acceptance that
  ## overwrote a revocation would make revocation last until the next install.
  ##
  ## IT IS ALL OR NOTHING ON THE GRAMMAR, and that is a property rather than a
  ## choice: every row this call writes carries the same `plugin`, `at` and
  ## `note`, so the first refusal is every refusal. `rows` is therefore 0
  ## whenever `outcome` is `groUnwritableField`, and a caller never has to
  ## reason about a half-written acceptance.
  if plugin.len == 0: return GrantDeclaredOutcome(outcome: groNoPlugin)
  result.outcome = groUnchanged
  for c in Capability:
    if c notin declared: continue
    if ledger.stateOf(plugin, c) != gsUndecided: continue
    if not ledger.record(plugin, c, gdGranted, at, note):
      return GrantDeclaredOutcome(outcome: groUnwritableField, rows: 0)
    inc result.rows
    result.outcome = groRecorded

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
  ##
  ## IT DOES NOT ESCAPE AND IT DOES NOT NEED TO: every entry this module
  ## produces came through `record`, which refuses a field carrying a tab, a
  ## newline or a carriage return. `<decision>` is `$GrantDecision` and
  ## `<capability>` is `$Capability`, so those two are closed by their types.
  ## That is the whole argument for there being no encoder here, and it is only
  ## sound while `record` is the one constructor — which is what its own comment
  ## records.
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
    if parts.len < 4 or parts.len > 5:
      # THE ROW HAS FOUR FIELDS OR FIVE, AND NEVER MORE. The note used to be
      # `parts[4 .. ^1].join(tab)`, which is a decoder for an encoding the
      # writer no longer emits — `record` refuses a field carrying a tab
      # (`representableGrantField`). Rejoining is how a reader and a writer come
      # to disagree about how many fields a row has, and a six-field row can now
      # only be a hand edit or an injection attempt: both are worth naming.
      result.problems.add "line " & $lineNo & ": expected four or five " &
        "tab-separated fields (decision, plugin, capability, when, and an " &
        "optional note), got " & $parts.len
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
    # THROUGH `record`, so the reader cannot admit a row the writer would
    # refuse (§14: one predicate, one function). It cannot fail here — the
    # split removed every tab and `splitLines` every newline — and going
    # through it anyway is what keeps that true if either rule changes.
    if not result.ledger.record(parts[1], cap, decision, parts[3],
                                (if parts.len > 4: parts[4] else: "")):
      result.problems.add "line " & $lineNo & ": a field carries " &
        unrepresentableGrantFieldText()
