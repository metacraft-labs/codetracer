## plugin_distribution_test.nim — PLAT-10's PURE half.
##
## Three subjects, none of which needs a machine:
##
##   1. `plugin_model/distribution.nim` — the three grammars the launcher
##      writes (`<name>@<version>`, `.ctrc`, and the version-eligibility
##      rules), read back so a running CodeTracer selects the version `ct`
##      would.
##   2. The plugin/capability-file separation: `componentRole`, and the
##      refusal that keeps "a component that is a plugin" and "a component the
##      launcher exec's on a command word" disjoint.
##   3. `plugin_model/grant_ledger.nim` — the per-plugin capability grant, its
##      history, and the narrowing that makes a revocation a smaller
##      `GrantSet` rather than a flag.
##
## ## WHAT THIS SUITE IS NOT
##
## It is not evidence that anything is installed, discovered or enforced.
##
##   * `src/ct/launch/plugin_components_test.nim` walks REAL directories,
##     including a `.ctrc` on disk and an `active/` symlink the kernel
##     resolves.
##   * `src/ct/launch/plugin_distribution_e2e_test.nim` runs the REAL `ct`
##     binary for `install`, `update`, `uninstall` and `install --list`, and
##     then attempts `ct <word>` against a plugin component.
##   * `src/frontend/viewmodel/tests/unit/test_plugin_grant_lifecycle.nim`
##     measures a revoked capability as an EFFECT: the child process that does
##     not run, the sentinel file that is not written.
##
## A narrowing function agreeing with itself is exactly what this file can
## prove and exactly what would not be worth much on its own.
##
## ## NO MOCKS
##
## Every input is a literal — a directory name, a `.ctrc` body, a ledger. The
## subjects are pure functions over them. There is no collaborator here for
## anything to stand in for.
##
## ## TRAP 13 (Verification-Harness-Traps §13)
##
## Every assertion helper in this file is a `template`. A `check` inside a
## plain `proc` assigns a module-level `testStatusIMPL` and the case reports
## `[OK]` with the failed comparison printed above it. There is one helper
## (`ck`) plus its equality shorthand (`ckEq`), and both wrap
## `unittest.check`.
##
## Compile and run:
##   nim c -r src/common/plugin_distribution_test.nim

import std/[algorithm, strutils, unittest]

import ./plugin_model

const ExpectedAssertions = 642
  ## Written from a run, and asserted against the tally at the end of the file.
  ## `ci/lib/run-nim-test-lane.sh` reads this name.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

# ---------------------------------------------------------------------------
# 1. `<name>@<version>`
# ---------------------------------------------------------------------------

suite "PLAT-10: the component directory grammar":

  test "a well-formed directory name splits into a name and a version":
    var c: ComponentRef
    ckEq parseComponentRef("demo-plugin@1.0.0", c), crpOk
    ckEq c.name, "demo-plugin"
    ckEq c.version, "1.0.0"
    ckEq $c, "demo-plugin@1.0.0"

  test "a DOTTED component name is accepted, because `ct install` accepts it":
    # The launcher's `install_one` creates `$C@$V` for whatever `$C` the user
    # typed, and `scanLevelForCommand` dispatches it. A reader that refused
    # the directory would be refusing something the package manager supports —
    # this is the case that separates the DIRECTORY grammar from the PIN
    # grammar, and both are asserted here so neither can drift into the other.
    var c: ComponentRef
    ckEq parseComponentRef("acme.metrics@2.1.0", c), crpOk
    ckEq c.name, "acme.metrics"
    ck not isPinnableComponentName("acme.metrics")
    ck isPinnableComponentName("demo-plugin")
    ck pinnabilityNote("acme.metrics").contains("cannot be pinned")
    ck pinnabilityNote("demo-plugin").contains("can be pinned")

  test "every way a directory name can fail has its own answer":
    # Verification-Harness-Traps §4b: a refusal asserted only as "it refused"
    # passes when the refusal was for the wrong reason. Each row names the
    # value it must produce.
    var c: ComponentRef
    ckEq parseComponentRef("demo-plugin", c), crpNoSeparator
    ckEq parseComponentRef("a@b@c", c), crpMultipleSeparators
    ckEq parseComponentRef("@1.0.0", c), crpEmptyName
    ckEq parseComponentRef("demo@", c), crpEmptyVersion
    ckEq parseComponentRef("a".repeat(257) & "@1.0.0", c), crpNameTooLong
    ckEq parseComponentRef("demo@" & "1".repeat(65), c), crpVersionTooLong
    ckEq parseComponentRef("de/mo@1.0.0", c), crpBadNameChar
    ckEq parseComponentRef("demo@1 0", c), crpBadVersionChar
    ckEq parseComponentRef("demo@1/0", c), crpBadVersionChar

  test "the length bounds are the launcher's, and are asserted as numbers":
    # Not as `MaxComponentNameBytes + 1`, which would widen with the constant
    # and go on passing having asserted nothing (PLAT-9's M3, re-learned).
    ckEq MaxComponentNameBytes, 256
    ckEq MaxComponentVersionBytes, 64
    ckEq MaxCtrcPins, 16
    var c: ComponentRef
    ckEq parseComponentRef("a".repeat(256) & "@1.0.0", c), crpOk
    ckEq parseComponentRef("demo@" & "1".repeat(64), c), crpOk

  test "every problem describes itself, and names the input":
    var n = 0
    for p in ComponentRefProblem:
      let text = describe(p, "the-input@1.0.0")
      ck text.len > 0
      ck text.contains("the-input@1.0.0")
      inc n
    ckEq n, 9

# ---------------------------------------------------------------------------
# 2. The separation the milestone asks for
# ---------------------------------------------------------------------------

suite "PLAT-10: a plugin is not a component the launcher exec's":

  test "the two files have different names, and neither is the other":
    ckEq PluginManifestFile, "plugin.json"
    ckEq CapabilityFile, "capabilities"
    ck PluginManifestFile != CapabilityFile

  test "the role is decided by which files are present, all four ways":
    ckEq componentRole(hasPluginManifest = true, hasCapabilityFile = false),
         crPlugin
    ckEq componentRole(hasPluginManifest = false, hasCapabilityFile = true),
         crCommandComponent
    ckEq componentRole(hasPluginManifest = true, hasCapabilityFile = true),
         crAmbiguous
    ckEq componentRole(hasPluginManifest = false, hasCapabilityFile = false),
         crUnclassified

  test "the refusal names BOTH files and both remedies":
    # §8.3: "Sharing the distribution format must not imply sharing the
    # dispatch model." An author told only "ambiguous" has to guess which of
    # the two files to delete, so both are in the text and so is each way out.
    let e = roleError("demo-plugin", "demo-plugin@1.0.0")
    ckEq e.code, pecPluginAlsoDispatchable
    ck e.namesPlugin()
    ck e.detail.contains(PluginManifestFile)
    ck e.detail.contains(CapabilityFile)
    ck e.detail.contains("demo-plugin@1.0.0")
    ck render(e).contains("command dispatch")

  test "the install and uninstall hints are the launcher's own commands":
    # The ONE place the commands are spelled. If this ever reads anything but
    # `ct install` / `ct uninstall`, a second package mechanism has appeared.
    ckEq installHintFor("demo-plugin"), "ct install demo-plugin"
    ckEq installHintFor("demo-plugin", "1.2.0"), "ct install demo-plugin@1.2.0"
    ckEq uninstallHintFor(ComponentRef(name: "demo-plugin", version: "1.2.0")),
         "ct uninstall demo-plugin@1.2.0"

# ---------------------------------------------------------------------------
# 3. `.ctrc`
# ---------------------------------------------------------------------------

suite "PLAT-10: .ctrc version pins":

  test "the launcher's grammar, including the forms a split-based reader misses":
    var pins: seq[CtrcPin]
    let text = """
# a comment
demo-plugin = 1.0.0
tight=2.0.0
  indented-is-fine = 3.0.0
spaced   =   4.0.0
trailing = 5.0.0    # and a comment after the version

9leading-digit = 1.0.0
no-equals 6.0.0
empty-version =
"""
    ckEq parseCtrcPins(text, pins), cpOk
    ckEq pins.len, 5
    ckEq pinFor(pins, "demo-plugin"), "1.0.0"
    ckEq pinFor(pins, "tight"), "2.0.0"
    ckEq pinFor(pins, "indented-is-fine"), "3.0.0"
    ckEq pinFor(pins, "spaced"), "4.0.0"
    ckEq pinFor(pins, "trailing"), "5.0.0"
    # The three the launcher skips, skipped here for the same reasons.
    ckEq pinFor(pins, "9leading-digit"), ""
    ckEq pinFor(pins, "no-equals"), ""
    ckEq pinFor(pins, "empty-version"), ""
    ckEq pinFor(pins, "never-mentioned"), ""

  test "CRLF line endings parse the same as LF":
    var lf, crlf: seq[CtrcPin]
    ckEq parseCtrcPins("a = 1.0.0\nb = 2.0.0\n", lf), cpOk
    ckEq parseCtrcPins("a = 1.0.0\r\nb = 2.0.0\r\n", crlf), cpOk
    ckEq lf.len, 2
    ckEq crlf.len, 2
    ckEq pinFor(crlf, "a"), "1.0.0"
    ckEq pinFor(crlf, "b"), "2.0.0"

  test "more pins than the launcher holds is an error, not a silent truncation":
    # `parseCtrcBuf` returns false past `maxPins` and the launcher then prints
    # `ct: .ctrc has too many version pins` and EXITS 1. A reader that took the
    # first sixteen would disagree with a process that refuses to start.
    var pins: seq[CtrcPin]
    var body = ""
    for i in 0 ..< MaxCtrcPins:
      body.add "p" & $i & " = 1.0.0\n"
    ckEq parseCtrcPins(body, pins), cpOk
    ckEq pins.len, MaxCtrcPins
    body.add "p16 = 1.0.0\n"
    ckEq parseCtrcPins(body, pins), cpTooManyPins

  test "a duplicated pin is decided by the FIRST line, as `findPin` is":
    var pins: seq[CtrcPin]
    ckEq parseCtrcPins("dup = 1.0.0\ndup = 2.0.0\n", pins), cpOk
    ckEq pins.len, 2
    ckEq pinFor(pins, "dup"), "1.0.0"

# ---------------------------------------------------------------------------
# 4. Version eligibility — the launcher's three rules, in the launcher's order
# ---------------------------------------------------------------------------

suite "PLAT-10: which installed version is chosen":

  test "with no pin and no active symlink, the lexicographically highest wins":
    let s = selectVersion(["1.0.0", "1.2.0", "1.1.0"], pin = "",
                          activeVersion = "")
    ckEq s.rule, vsrHighest
    ckEq s.version, "1.2.0"

  test "the comparison is LEXICOGRAPHIC, which is what the launcher does":
    # `versionEligible` compares `d_name` BYTES. `1.10.0` therefore sorts below
    # `1.9.0`, which is wrong semantically and is the launcher's answer — and a
    # loader that disagreed with the dispatcher on this one input would load a
    # different version of a plugin than `ct` would exec.
    let s = selectVersion(["1.9.0", "1.10.0"], pin = "", activeVersion = "")
    ckEq s.rule, vsrHighest
    ckEq s.version, "1.9.0"
    ck lexGreater("1.9.0", "1.10.0")
    ck lexGreater("1.0.0-beta", "1.0.0")   # longer, equal prefix
    ck not lexGreater("1.0.0", "1.0.0")

  test "an active symlink beats the highest version":
    let s = selectVersion(["1.0.0", "2.0.0"], pin = "", activeVersion = "1.0.0")
    ckEq s.rule, vsrActiveSymlink
    ckEq s.version, "1.0.0"

  test "a pin beats the active symlink AND the highest version":
    let s = selectVersion(["1.0.0", "2.0.0", "3.0.0"], pin = "2.0.0",
                          activeVersion = "3.0.0")
    ckEq s.rule, vsrPinned
    ckEq s.version, "2.0.0"

  test "a pin to a version that is not installed selects NOTHING":
    # `scanLevelForCommand` `continue`s past every directory whose version is
    # not the pinned one, so there is no fallback to the highest. That is the
    # behaviour a checked-in `.ctrc` is for.
    let s = selectVersion(["1.0.0", "2.0.0"], pin = "9.9.9", activeVersion = "")
    ckEq s.rule, vsrPinnedMissing
    ckEq s.version, ""
    ck describe(s, "demo-plugin").contains("ct install demo-plugin@")

  test "an active symlink pointing at a version that is gone selects NOTHING":
    # `versionEligible` compares the symlink target's version against each
    # peer, so when the target is absent EVERY peer fails and the level offers
    # nothing. Folding this into "fall back to highest" would make a dangling
    # symlink silently promote a version nobody chose.
    let s = selectVersion(["1.0.0", "2.0.0"], pin = "",
                          activeVersion = "7.0.0")
    ckEq s.rule, vsrNone
    ckEq s.version, ""

  test "nothing installed selects nothing":
    let s = selectVersion([], pin = "", activeVersion = "")
    ckEq s.rule, vsrNone

  test "every selection rule describes itself and names the component":
    var n = 0
    for r in VersionSelectionRule:
      let text = describe(VersionSelection(rule: r, version: "1.2.3"),
                          "demo-plugin")
      ck text.len > 0
      ck text.contains("demo-plugin")
      inc n
    ckEq n, 5

# ---------------------------------------------------------------------------
# 5. The grant ledger
# ---------------------------------------------------------------------------

const
  At1 = "2026-08-14T09:00:00Z"
  At2 = "2026-09-11T14:30:00Z"

suite "PLAT-10: the capability grant is recorded per plugin":

  test "an undecided capability is not granted":
    var l: GrantLedger
    ckEq l.stateOf("demo-plugin", capProcess), gsUndecided
    ckEq l.decidedAt("demo-plugin", capProcess), ""

  test "grant, then revoke: the last entry in force, the history kept":
    var l: GrantLedger
    ck l.grant("demo-plugin", capProcess, At1, "installed")
    ckEq l.stateOf("demo-plugin", capProcess), gsGranted
    ckEq l.decidedAt("demo-plugin", capProcess), At1
    ck l.revoke("demo-plugin", capProcess, At2, "the user took it back")
    ckEq l.stateOf("demo-plugin", capProcess), gsRevoked
    ckEq l.decidedAt("demo-plugin", capProcess), At2
    # THE HISTORY IS THE INSPECTABLE HALF: "you granted this last month" is a
    # sentence about a record with a date in it, and a view showing only the
    # current state could not say it.
    ckEq l.entries.len, 2
    let text = l.describe("demo-plugin")
    ck text.contains(At1)
    ck text.contains(At2)
    ck text.contains("installed")
    ck text.contains("the user took it back")
    ck text.contains("in force now: (nothing)")

  test "a repeated decision changes nothing and appends nothing":
    var l: GrantLedger
    ck l.grant("demo-plugin", capTrace, At1)
    ck not l.grant("demo-plugin", capTrace, At2)
    ckEq l.entries.len, 1
    ck l.revoke("demo-plugin", capTrace, At2)
    ck not l.revoke("demo-plugin", capTrace, At2)
    ckEq l.entries.len, 2

  test "revoking an UNDECIDED capability is recorded, and that matters later":
    # It changes nothing today — undecided is already refused. What it changes
    # is the next acceptance step, which grants what is undecided.
    var l: GrantLedger
    ck l.revoke("demo-plugin", capFsWrite, At1, "pre-emptive")
    ckEq l.stateOf("demo-plugin", capFsWrite), gsRevoked
    ckEq l.grantDeclared("demo-plugin", {capFsWrite, capFsRead}, At2), 1
    ckEq l.stateOf("demo-plugin", capFsWrite), gsRevoked
    ckEq l.stateOf("demo-plugin", capFsRead), gsGranted

  test "two plugins do not share a decision":
    var l: GrantLedger
    ck l.grant("a", capProcess, At1)
    ckEq l.stateOf("b", capProcess), gsUndecided
    ck l.revoke("a", capProcess, At2)
    ck l.grant("b", capProcess, At2)
    ckEq l.stateOf("a", capProcess), gsRevoked
    ckEq l.stateOf("b", capProcess), gsGranted
    ckEq l.plugins(), @["a", "b"]

  test "forgetting a plugin removes its entries and nobody else's":
    var l: GrantLedger
    ck l.grant("a", capProcess, At1)
    ck l.revoke("a", capTrace, At1)
    ck l.grant("b", capProcess, At1)
    ckEq l.forget("a"), 2
    ckEq l.stateOf("a", capProcess), gsUndecided
    ckEq l.stateOf("a", capTrace), gsUndecided
    ckEq l.stateOf("b", capProcess), gsGranted

  test "a plugin with no decisions says so rather than showing an empty list":
    var l: GrantLedger
    ck l.describe("nobody").contains("no capability decision has been recorded")

suite "PLAT-10: a revocation is a smaller GrantSet, not a flag":

  test "the narrowing removes exactly the revoked capability":
    var declared: GrantSet
    declared.capabilities = {capProcess, capFsRead, capTrace}
    declared.executables = @["env"]
    declared.readPaths = @["/tmp"]
    var l: GrantLedger
    ckEq l.grantDeclared("demo", declared.capabilities, At1), 3
    ckEq effectiveGrants(declared, l, "demo").capabilities,
         {capProcess, capFsRead, capTrace}
    ck l.revoke("demo", capProcess, At2)
    let after = effectiveGrants(declared, l, "demo")
    ckEq after.capabilities, {capFsRead, capTrace}
    # The DECLARED sets travel unchanged: `decide` tests the capability first
    # on every arm, so a revoked `process` is refused before `executables` is
    # ever consulted. Two places that had to agree about what revocation
    # clears would be two places that could disagree.
    ckEq after.executables, @["env"]
    ckEq after.readPaths, @["/tmp"]

  test "UNDECIDED is refused, which is what makes an upgrade safe":
    # A plugin installed at 1.0.0 declaring `fs:read`, granted; upgraded to
    # 2.0.0 whose manifest ALSO declares `process`. The new power is undecided,
    # so it is not inherited from the old consent.
    var v1: GrantSet
    v1.capabilities = {capFsRead}
    var l: GrantLedger
    ckEq l.grantDeclared("demo", v1.capabilities, At1), 1
    var v2: GrantSet
    v2.capabilities = {capFsRead, capProcess}
    ckEq effectiveGrants(v2, l, "demo").capabilities, {capFsRead}
    ckEq l.stateOf("demo", capProcess), gsUndecided
    # And the acceptance step grants only what the upgrade ADDED.
    ckEq l.grantDeclared("demo", v2.capabilities, At2), 1
    ckEq effectiveGrants(v2, l, "demo").capabilities, {capFsRead, capProcess}

  test "a ledger entry cannot grant a capability the manifest never declared":
    var declared: GrantSet
    declared.capabilities = {capFsRead}
    var l: GrantLedger
    ck l.grant("demo", capFsRead, At1)
    ck l.grant("demo", capProcess, At1)
    ckEq l.stateOf("demo", capProcess), gsGranted
    ckEq effectiveGrants(declared, l, "demo").capabilities, {capFsRead}

  test "the narrowing is total over every one of the sixty-four subsets":
    # By ENUMERATION rather than over the three somebody thought of. For each
    # declared subset and each capability, the effective set is the declared
    # set minus that capability when it is revoked, and equal to it when it is
    # not declared at all.
    var caps: seq[Capability] = @[]
    for c in Capability: caps.add c
    ckEq caps.len, 6
    var subsets = 0
    var revocationsChecked = 0
    for mask in 0 ..< (1 shl caps.len):
      var declared: GrantSet
      for i, c in caps:
        if (mask and (1 shl i)) != 0: declared.capabilities.incl c
      inc subsets
      for victim in caps:
        var l: GrantLedger
        discard l.grantDeclared("demo", declared.capabilities, At1)
        discard l.revoke("demo", victim, At2)
        let eff = effectiveGrants(declared, l, "demo").capabilities
        inc revocationsChecked
        if victim in declared.capabilities:
          ckEq eff, declared.capabilities - {victim}
        else:
          ckEq eff, declared.capabilities
    ckEq subsets, 64
    ckEq revocationsChecked, 384

suite "PLAT-10: the ledger round-trips through its own text":

  test "render then parse is the identity, fields and order":
    var l: GrantLedger
    ck l.grant("acme.metrics", capProcess, At1, "accepted at install")
    ck l.grant("acme.metrics", capTrace, At1, "")
    ck l.revoke("acme.metrics", capProcess, At2,
                "a note with spaces and a comma, too")
    ck l.grant("other", capSocketLocal, At2)
    let parsed = parseLedger(l.render())
    ckEq parsed.problems.len, 0
    ckEq parsed.ledger.entries.len, l.entries.len
    var n = 0
    for i, e in l.entries:
      ckEq parsed.ledger.entries[i].plugin, e.plugin
      ckEq parsed.ledger.entries[i].capability, e.capability
      ckEq parsed.ledger.entries[i].decision, e.decision
      ckEq parsed.ledger.entries[i].at, e.at
      ckEq parsed.ledger.entries[i].note, e.note
      inc n
    ckEq n, 4
    ckEq parsed.ledger.stateOf("acme.metrics", capProcess), gsRevoked
    ckEq parsed.ledger.stateOf("acme.metrics", capTrace), gsGranted

  test "every capability spelling survives the round trip":
    # The set is §8.1.2's and the spellings carry a colon (`socket:local`), so
    # a separator chosen carelessly would silently split one.
    var l: GrantLedger
    var n = 0
    for c in Capability:
      ck l.grant("demo", c, At1, "cap " & $c)
      inc n
    ckEq n, 6
    let parsed = parseLedger(l.render())
    ckEq parsed.problems.len, 0
    for c in Capability:
      ckEq parsed.ledger.stateOf("demo", c), gsGranted

  test "an unusable line is reported by number and the rest is kept":
    let text = LedgerHeader & "\n" &
      "grant\tdemo\tprocess\t" & At1 & "\tfine\n" &
      "sideways\tdemo\ttrace\t" & At1 & "\n" &
      "grant\tdemo\tnot-a-capability\t" & At1 & "\n" &
      "grant\tdemo\n" &
      "grant\t\ttrace\t" & At1 & "\n" &
      "revoke\tdemo\tprocess\t" & At2 & "\tgone\n"
    let parsed = parseLedger(text)
    ckEq parsed.problems.len, 4
    ck parsed.problems[0].contains("line 3")
    ck parsed.problems[0].contains("sideways")
    ck parsed.problems[1].contains("line 4")
    ck parsed.problems[1].contains("not-a-capability")
    ck parsed.problems[2].contains("line 5")
    ck parsed.problems[3].contains("line 6")
    ck parsed.problems[3].contains("plugin id is empty")
    ckEq parsed.ledger.entries.len, 2
    ckEq parsed.ledger.stateOf("demo", capProcess), gsRevoked

  test "an empty ledger renders to a header and parses back to nothing":
    let l = GrantLedger()
    ck l.render().startsWith(LedgerHeader)
    let parsed = parseLedger(l.render())
    ckEq parsed.problems.len, 0
    ckEq parsed.ledger.entries.len, 0

# ---------------------------------------------------------------------------
# 6. The gate: no second package mechanism, asserted over this module's SOURCE
# ---------------------------------------------------------------------------

const
  DistributionSource = staticRead("plugin_model/distribution.nim")
    ## The module AS TEXT. `staticRead` resolves relative to this file and the
    ## module is already in the lane's compile closure, so nothing here depends
    ## on a sibling checkout.
  ComponentsSource = staticRead("../ct/launch/plugin_components.nim")
  GrantStoreSource = staticRead("../ct/launch/grant_store.nim")
    ## THE OTHER TWO SUBJECTS OF THE SAME GATE. Scanning only
    ## `distribution.nim` made the gate's SUBJECT a claim about one file while
    ## its SENTENCE — "no second package mechanism" — is about the milestone's
    ## whole surface (Verification-Harness-Traps §6: a scan that reports a clean
    ## sweep is also claiming its subject is the whole population). The fact
    ## held for the other two and nothing asserted it, so nothing would have
    ## noticed the day it stopped holding.
    ##
    ## They are scanned with THEIR OWN allowed sets rather than the same one,
    ## because the two do legitimately touch the filesystem: discovery reads
    ## manifests and `.ctrc` files, and the grant store writes a state file. A
    ## shared list would have to be the union — which is the weakest of the
    ## three and would let a downloader into `distribution.nim`.

func codeLines(source: string): seq[string] =
  ## Every line with its comments and its string literals removed, so a scan
  ## over it matches SYNTAX rather than VOCABULARY
  ## (Verification-Harness-Traps §4d). Without this, a header that explains
  ## "there is no `download` here" satisfies a scan for `download`.
  for raw in source.splitLines():
    var kept = ""
    var inString = false
    var i = 0
    while i < raw.len:
      let c = raw[i]
      if inString:
        if c == '\\': inc i
        elif c == '"': inString = false
      elif c == '"':
        inString = true
      elif c == '#':
        break
      else:
        kept.add c
      inc i
    result.add kept

type
  ScanSubject = object
    ## One module, its text, what it is allowed to reach for and why, and the
    ## exact import list it may have. ONE SCANNER, THREE SUBJECTS — the rule and
    ## every subject run through the same `codeLines` and the same loop, so a
    ## stripper that broke would redden all three rather than agreeing with
    ## itself on two (Verification-Harness-Traps §14).
    name: string
    source: string
    allowed: seq[string]
      ## Needles this module may contain, each one a deliberate exception. A
      ## name here is a decision, not an exclusion for convenience.
    imports: seq[string]
    anchor: string
      ## A declaration only this module has. It is the positive control
      ## (§4a): a `staticRead` that resolved to the wrong file, or a stripper
      ## that returned empty strings, satisfies every "must not contain" below
      ## and fails this.
    minCodeLines: int

const
  ForbiddenNeedles = ["download", "http", "curl", "wget", "mirror", "registry",
                      "createDir", "removeDir", "writeFile", "readFile",
                      "moveFile", "execProcess", "startProcess", "os."]
    ## §8.3's gate: "If you find yourself writing a downloader, a version
    ## resolver or a directory layout, stop — the launcher has them."

  ScanSubjects = [
    ScanSubject(
      name: "plugin_model/distribution.nim",
      source: DistributionSource,
      # NOTHING. This module is the grammar and the eligibility rules; it reads
      # no file and names no path. It is the one of the three whose allowed set
      # being empty is the whole point.
      allowed: @[],
      imports: @["import ./diagnostics"],
      anchor: "func selectVersion*",
      minCodeLines: 100),
    ScanSubject(
      name: "ct/launch/plugin_components.nim",
      source: ComponentsSource,
      allowed: @[
        # It READS. Discovery opens the manifest it found and the `.ctrc` it
        # walked to; that is the launcher's tree being read, not a second
        # mechanism for filling one. Every WRITE needle stays forbidden, which
        # is the line that matters: nothing here creates a directory, renames
        # a component or fetches anything.
        "readFile",
        # `component_roots.registryEnvVar` — it NAMES the launcher's registry
        # variable. Naming somebody else's registry is the opposite of
        # implementing one, and the alternative (dropping `registry` from the
        # list for this module) would also permit a `registry` of its own.
        "registry"],
      imports: @["import ../../common/plugin_model", "import ./component_roots",
                 "import std/[os, strutils]"],
      anchor: "proc discoverPlugins*",
      minCodeLines: 100),
    ScanSubject(
      name: "ct/launch/grant_store.nim",
      source: GrantStoreSource,
      allowed: @[
        # It WRITES ONE STATE FILE, and these four are that write: make the
        # directory, write the staging file, rename it into place, read it
        # back. `removeDir`, `execProcess`, `startProcess` and every fetch
        # needle stay forbidden — this module must not be able to delete a
        # component tree or reach a network any more than the other two.
        "createDir", "writeFile", "readFile", "moveFile"],
      imports: @["import ../../common/plugin_model/diagnostics",
                 "import ../../common/plugin_model/grant_ledger",
                 "import std/[os, strutils]", "import std/posix"],
      anchor: "proc saveGrantLedgerTo*",
      minCodeLines: 40)]

suite "PLAT-10: the verification gate, over this module's own code":

  test "the comment/literal stripper works, proved on a planted control":
    # Verification-Harness-Traps §4: a scanner that finds nothing passes every
    # "must not contain". The control is a line carrying the forbidden word in
    # all three positions — code, comment, literal — so the stripper's own
    # behaviour is visible rather than assumed.
    let control = codeLines(
      "proc download(): string = \"download\"  # download it\n" &
      "let x = 1  # download\n")
    ckEq control.len, 3
    ck control[0].contains("proc download()")
    ck not control[0].contains("\"download\"")
    ck not control[0].contains("# download it")
    ck not control[1].contains("download")

  test "the stripper reaches all three modules: it found code, not nothing":
    # The positive control (§4a), over each subject. A stripper that returned
    # empty strings, or a `staticRead` that resolved to the wrong file, would
    # satisfy every "must not contain" below and fails here.
    #
    # THE COUNT, NOT "AT LEAST ONE" (§4b): the membership is `ScanSubjects` and
    # its size is knowable, so a subject that silently dropped out of the loop
    # is a number that moves rather than a scan that says nothing.
    var checkedSubjects = 0
    for subject in ScanSubjects:
      inc checkedSubjects
      checkpoint("subject: " & subject.name)
      let lines = codeLines(subject.source)
      var withCode = 0
      for l in lines:
        if l.strip().len > 0: inc withCode
      ck withCode >= subject.minCodeLines
      var sawAnchor = false
      for l in lines:
        if l.contains(subject.anchor): sawAnchor = true
      ck sawAnchor
    ckEq checkedSubjects, 3

  test "no downloader, no mirror, no second registry, in any of the three":
    # PLAT-10's gate: "If you find yourself writing a downloader, a version
    # resolver or a directory layout, stop — the launcher has them." This is
    # the mechanical half of that sentence, over the code and not the prose.
    #
    # EACH MODULE CARRIES ITS OWN ALLOWED SET, because two of the three do
    # legitimately touch the filesystem and a shared list would have to be the
    # union of all three — the weakest of them, applied to the strictest.
    var checkedSubjects = 0
    var hits: seq[string] = @[]
    for subject in ScanSubjects:
      inc checkedSubjects
      var n = 0
      for needle in ForbiddenNeedles:
        inc n
        if needle in subject.allowed: continue
        for l in codeLines(subject.source):
          if l.toLowerAscii.contains(needle.toLowerAscii):
            hits.add subject.name & ": " & needle & " -> " & l.strip()
      ckEq n, 14
    ckEq checkedSubjects, 3
    checkpoint(hits.join("\n"))
    ckEq hits.len, 0

  test "every ALLOWED needle is one the module really uses, not a spare excuse":
    # THE TWIN OF THE ALLOWED SET (§4a), and the reason an exception list does
    # not quietly become a wish list. Each name a module is allowed to reach for
    # must OCCUR in that module: a needle that stopped occurring means the
    # allowance outlived the code it was written for, and the next person to
    # read the list would take it as a statement about what the module does.
    var checkedAllowances = 0
    for subject in ScanSubjects:
      for needle in subject.allowed:
        inc checkedAllowances
        checkpoint(subject.name & " is allowed " & needle)
        var seen = false
        for l in codeLines(subject.source):
          if l.toLowerAscii.contains(needle.toLowerAscii): seen = true
        ck seen
        # …and it is a name the scan would otherwise have caught, so an
        # allowance for something never forbidden cannot sit in the list.
        ck needle in ForbiddenNeedles
    ckEq checkedAllowances, 6

  test "and none of the three imports anything that could reach a machine":
    var checkedSubjects = 0
    for subject in ScanSubjects:
      inc checkedSubjects
      checkpoint("subject: " & subject.name)
      var imports: seq[string] = @[]
      for l in codeLines(subject.source):
        let s = l.strip()
        if s.startsWith("import "): imports.add s
      ckEq imports.sorted(), subject.imports.sorted()
    ckEq checkedSubjects, 3

# ---------------------------------------------------------------------------

suite "PLAT-10: the counted-assertion tally":

  test "the tally":
    # Verification-Harness-Traps §4c: a per-check assertion count is a
    # fingerprint, and a check that asserts its own count turns a silent skip
    # into a red run with no second run and no human noticing.
    check countedAssertions == ExpectedAssertions
