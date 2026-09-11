## plugin_model/distribution.nim — PLAT-10 deliverables 1 and 2, the half that
## needs no filesystem.
##
## ## THE LAUNCHER IS THE PACKAGE MANAGER AND THIS MODULE IS NOT A SECOND ONE
##
## Extensibility-Model.md §8.3 is a list of things that already exist:
##
##     ct install <name>[@<version>]     mirror-probed download + install
##     ct uninstall <name>@<version>     remove a user-level component
##     .ctrc                             version pins, parsed by the launcher
##     <components-root>/<name>@<version>/{capabilities,bin/}
##
## "**A plugin is a component**, and plugin distribution should be that
## mechanism rather than a second one." So there is NO downloader here, NO
## mirror list, NO registry, NO install, NO uninstall and NO directory to
## create. `ct install` does all of that already, and the end-to-end suite
## (`src/ct/launch/plugin_distribution_e2e_test.nim`) drives the real binary
## rather than anything in this repository.
##
## What this module is, exactly: **a READER of three grammars the launcher
## already writes**, so that a running CodeTracer selects the same version of
## an installed plugin that `ct` would select of an installed component.
##
##   1. `<name>@<version>` — the directory name `install_one` creates
##      (`codetracer-launcher/src/install.nim`, `DST="$R/components/v1/$C@$V"`).
##   2. `.ctrc` — `name = version`, the launcher's `parseCtrcBuf`.
##   3. The three eligibility rules of `scanLevelForCommand` /
##      `versionEligible`: a pin wins outright, then the `active/<name>`
##      symlink, then the lexicographically greatest version AT THAT LEVEL.
##
## **Reading a format is not owning it.** The distinction is worth stating
## because it is the verification gate: if this file grew a `download`, a
## `resolveLatest` or a `mkdir`, the milestone would have failed. It has none,
## and `plugin_distribution_test.nim` asserts the *absence* by driving the real
## `ct` for every one of those verbs.
##
## ## RULE 3 IS LEXICOGRAPHIC AND THAT IS DELIBERATE, NOT AN OVERSIGHT
##
## `1.10.0` sorts BELOW `1.9.0` byte by byte, which is wrong semantically and
## is what the launcher does — `versionEligible` compares `d_name` bytes. A
## semantic comparison here would make a running CodeTracer load a different
## version of a plugin than `ct` would exec, for the one input where the two
## disagree, and a silent divergence between the dispatcher and the loader is a
## worse defect than an ordering somebody can pin around. `selectVersion`
## therefore carries the launcher's rule, and `VersionSelection` records WHICH
## rule decided, so a caller can say so.
##
## ## THE SEPARATION THE MILESTONE ASKS FOR
##
## "A plugin manifest distinct from a capability file — sharing distribution
## must not imply sharing the exec-by-command-word dispatch."
##
## `capabilities` is the launcher's file. Its first token per line is a COMMAND
## WORD (`caps.matches`), which is exactly the dispatch a plugin must not
## acquire. `plugin.json` is the plugin manifest. They are different names in
## the same directory, and `componentRole` is the classification:
##
##   `crCommandComponent`  only `capabilities` — routable as `ct <word>`
##   `crPlugin`            only `plugin.json`  — loaded by a running CodeTracer
##   `crAmbiguous`         BOTH — refused as a plugin, naming both files
##   `crUnclassified`      neither
##
## `crAmbiguous` is the deliverable's teeth. Without it the rule would be a
## convention: ship both files and the component is dispatchable AND loaded.
## With it the two sets are disjoint by a check that can fail, and the check is
## a refusal a user reads rather than a silent preference for one file.

import ./diagnostics

const
  PluginManifestFile* = "plugin.json"
    ## The plugin manifest's name inside a component directory. Chosen so that
    ## it CANNOT be mistaken for the launcher's `capabilities`: different name,
    ## different syntax (JSON, not whitespace-separated tokens), different
    ## reader, different process.

  CapabilityFile* = "capabilities"
    ## The launcher's file. Named here so the ambiguity check has one spelling
    ## of it rather than a literal at each site.

  ComponentSeparator* = '@'

  MaxCtrcPins* = 16
    ## `codetracer-launcher/src/launcher.nim`'s `maxPins`. A `.ctrc` with more
    ## makes the LAUNCHER exit 1 (`S_ERR_CTRC_PINS`), so a reader that quietly
    ## took the first sixteen would disagree with the process that refuses to
    ## start at all.

  MaxComponentNameBytes* = 256
    ## `caps.CAP_NAME_BYTES`.

  MaxComponentVersionBytes* = 64
    ## The launcher's `Pin.version` array.

type
  ComponentRefProblem* = enum
    ## Why a directory name is not `<name>@<version>`.
    crpOk
    crpNoSeparator       ## no `@` at all — not a component directory
    crpMultipleSeparators
      ## Two or more. The launcher reads the separator position TWICE with two
      ## different rules — `scanLevelForCommand` takes the FIRST `@` and
      ## `install --list`'s shell takes the LAST — and they agree on every name
      ## with exactly one. Refusing the rest removes the divergence instead of
      ## picking a side of it.
    crpEmptyName
    crpEmptyVersion
    crpNameTooLong
    crpVersionTooLong
    crpBadNameChar
      ## A byte a DIRECTORY NAME may not carry — a path separator, or anything
      ## outside the printable range. This is deliberately NOT the `.ctrc` pin
      ## grammar: see `isPinnableComponentName`. `ct install acme.metrics`
      ## really does create `acme.metrics@1.0.0` and really does dispatch and
      ## uninstall it, so a reader that refused the directory would be refusing
      ## something the package manager supports.
    crpBadVersionChar    ## the launcher's `isVerChar`: printable, non-space

  ComponentRef* = object
    name*: string
    version*: string

  ComponentRole* = enum
    crUnclassified      ## neither file
    crCommandComponent  ## `capabilities` only
    crPlugin            ## `plugin.json` only
    crAmbiguous         ## both — see the module header

  CtrcPin* = object
    name*: string
    version*: string

  CtrcProblem* = enum
    cpOk
    cpTooManyPins       ## the launcher exits 1 on this; so does a caller here

  VersionSelectionRule* = enum
    ## WHICH of the launcher's three rules chose the version, so a caller can
    ## say so and a test can assert the rule rather than the outcome. Two
    ## rules producing the same answer on a one-version install is exactly the
    ## case where asserting only the answer proves nothing.
    vsrNone             ## nothing was eligible
    vsrPinned           ## `.ctrc` named this version and it is installed
    vsrPinnedMissing    ## `.ctrc` named a version that is NOT installed
    vsrActiveSymlink    ## `<level>/active/<name>` points at it
    vsrHighest          ## lexicographically greatest at this level

  VersionSelection* = object
    rule*: VersionSelectionRule
    version*: string    ## empty unless `rule` is one that selected

# ---------------------------------------------------------------------------
# `<name>@<version>`
# ---------------------------------------------------------------------------

func isComponentNameStart*(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')

func isComponentNameChar*(c: char): bool =
  ## The launcher's `isNameChar`, byte for byte.
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
    (c >= '0' and c <= '9') or c == '-'

func isComponentVersionChar*(c: char): bool =
  ## The launcher's `isVerChar`: any printable non-space byte. `@` and `/` are
  ## excluded separately by `componentRefProblem`, because a version carrying
  ## either would make the directory name ambiguous or escape the level.
  c >= '!' and c <= '~'

func isPinnableComponentName*(name: string): bool =
  ## Could a `.ctrc` line ever name this component?
  ##
  ## THE TWO GRAMMARS ARE NOT THE SAME AND THAT IS A FACT ABOUT THE LAUNCHER,
  ## not a choice made here. `install_one` will create a directory for any
  ## name the user typed, and `scanLevelForCommand` will dispatch it; but
  ## `parseCtrcBuf` reads a pin name as a letter followed by `[A-Za-z0-9-]`, so
  ## a component called `acme.metrics` installs, dispatches and uninstalls
  ## perfectly and **cannot be pinned**. A plugin author who wants §8.3's
  ## version pinning — "which a project will want, `.ctrc` is already checked
  ## in beside the code" — has to choose a pin-safe id, and this predicate is
  ## how a user is told which they have.
  if name.len == 0: return false
  if name.len >= MaxComponentNameBytes: return false
  if not isComponentNameStart(name[0]): return false
  for c in name:
    if not isComponentNameChar(c): return false
  true

func pinnabilityNote*(name: string): string =
  if isPinnableComponentName(name):
    "'" & name & "' can be pinned in .ctrc as '" & name & " = <version>'"
  else:
    "'" & name & "' cannot be pinned: a .ctrc pin name is a letter followed " &
      "by [A-Za-z0-9-], and the launcher's parser skips any line outside " &
      "that. The component installs, dispatches and uninstalls normally; only " &
      "the pin is unavailable"

func componentNameProblem*(name: string): ComponentRefProblem =
  if name.len == 0: return crpEmptyName
  if name.len > MaxComponentNameBytes: return crpNameTooLong
  for c in name:
    if c == '/' or c == '\\' or c < ' ' or c > '~': return crpBadNameChar
  crpOk

func componentVersionProblem*(version: string): ComponentRefProblem =
  if version.len == 0: return crpEmptyVersion
  if version.len > MaxComponentVersionBytes: return crpVersionTooLong
  for c in version:
    if not isComponentVersionChar(c) or c == ComponentSeparator or c == '/':
      return crpBadVersionChar
  crpOk

func parseComponentRef*(dirName: string; dest: var ComponentRef):
                        ComponentRefProblem =
  ## Split a component DIRECTORY NAME into its two halves. Total: every
  ## rejection has its own value, so a caller can say which one.
  var seps = 0
  var at = -1
  for i, c in dirName:
    if c == ComponentSeparator:
      inc seps
      if at < 0: at = i
  if seps == 0: return crpNoSeparator
  if seps > 1: return crpMultipleSeparators
  let name = dirName[0 ..< at]
  let version = dirName[at + 1 .. ^1]
  let np = componentNameProblem(name)
  if np != crpOk: return np
  let vp = componentVersionProblem(version)
  if vp != crpOk: return vp
  dest = ComponentRef(name: name, version: version)
  crpOk

func `$`*(c: ComponentRef): string =
  c.name & ComponentSeparator & c.version

func describe*(p: ComponentRefProblem; dirName: string): string =
  case p
  of crpOk: "'" & dirName & "' is a component directory"
  of crpNoSeparator:
    "'" & dirName & "' carries no '" & ComponentSeparator &
      "', so it is not a '<name>" & ComponentSeparator &
      "<version>' component directory"
  of crpMultipleSeparators:
    "'" & dirName & "' carries more than one '" & ComponentSeparator &
      "'. The launcher reads the separator position with two different rules " &
      "that agree only when there is exactly one"
  of crpEmptyName: "'" & dirName & "' names no component"
  of crpEmptyVersion: "'" & dirName & "' names no version"
  of crpNameTooLong:
    "'" & dirName & "' has a component name longer than " &
      $MaxComponentNameBytes & " bytes, which the launcher's parse buffer " &
      "cannot hold"
  of crpVersionTooLong:
    "'" & dirName & "' has a version longer than " &
      $MaxComponentVersionBytes & " bytes, which a '.ctrc' pin cannot hold"
  of crpBadNameChar:
    "'" & dirName & "' has a path separator or a non-printable byte in its " &
      "component name"
  of crpBadVersionChar:
    "'" & dirName & "' has a character outside the launcher's version " &
      "grammar (printable, no space, no '" & ComponentSeparator & "', no '/')"

# ---------------------------------------------------------------------------
# The role: plugin, command component, or the refusal
# ---------------------------------------------------------------------------

func componentRole*(hasPluginManifest, hasCapabilityFile: bool): ComponentRole =
  ## One predicate, one function (Verification-Harness-Traps §14). The
  ## discovery walk and the diagnostic both call THIS, so "is it a plugin"
  ## cannot be answered two ways.
  if hasPluginManifest and hasCapabilityFile: crAmbiguous
  elif hasPluginManifest: crPlugin
  elif hasCapabilityFile: crCommandComponent
  else: crUnclassified

func ambiguousComponentDetail*(dirName: string): string =
  ## §8.3: "Sharing the *distribution* format must not imply sharing the
  ## dispatch model, and the capability file's command vocabulary does not
  ## apply." The refusal names BOTH files, because either one may be the
  ## mistake and an author told only "ambiguous" has to guess which to delete.
  "the component directory '" & dirName & "' carries both '" &
    PluginManifestFile & "' and '" & CapabilityFile & "'. A plugin is loaded " &
    "by a running CodeTracer; a component carrying '" & CapabilityFile &
    "' is exec'd by the launcher on a command word. Sharing distribution " &
    "does not share dispatch, so a component may be one or the other and is " &
    "refused as a plugin while it claims to be both. Delete '" &
    CapabilityFile & "' to ship a plugin, or '" & PluginManifestFile &
    "' to ship a command component"

func roleError*(id: PluginId; dirName: string): PluginError =
  pluginError(id, pecPluginAlsoDispatchable, ambiguousComponentDetail(dirName))

# ---------------------------------------------------------------------------
# `.ctrc`
# ---------------------------------------------------------------------------

func parseCtrcPins*(text: string; dest: var seq[CtrcPin]): CtrcProblem =
  ## The launcher's `parseCtrcBuf`, in Nim that allocates.
  ##
  ## Every skip arm below is the launcher's: a blank line, a `#` comment, a
  ## first token that does not start with a letter, a missing `=`, an empty
  ## version, an over-long name or version. None of them is an error — the
  ## launcher `continue`s past each — and only the pin OVERFLOW is, because
  ## only the overflow makes the launcher itself exit.
  ##
  ## Written as one pass over bytes rather than `splitLines` + `split('=')`
  ## because the launcher tolerates `name=version` with no spaces, a trailing
  ## comment after the version, and a `\r` line ending; a split-based reader
  ## agrees with it on the examples somebody thought of and diverges on the
  ## rest.
  dest = @[]
  var i = 0
  let n = text.len
  while i < n:
    while i < n and (text[i] == ' ' or text[i] == '\t'): inc i
    if i < n and (text[i] == '#' or text[i] == '\n' or text[i] == '\r'):
      while i < n and text[i] != '\n': inc i
      if i < n: inc i
      continue
    let nStart = i
    if i >= n or not isComponentNameStart(text[i]):
      while i < n and text[i] != '\n': inc i
      if i < n: inc i
      continue
    while i < n and isComponentNameChar(text[i]): inc i
    let nEnd = i
    while i < n and (text[i] == ' ' or text[i] == '\t'): inc i
    if i >= n or text[i] != '=':
      while i < n and text[i] != '\n': inc i
      if i < n: inc i
      continue
    inc i
    while i < n and (text[i] == ' ' or text[i] == '\t'): inc i
    let vStart = i
    while i < n and isComponentVersionChar(text[i]): inc i
    let vEnd = i
    if vEnd == vStart:
      while i < n and text[i] != '\n': inc i
      if i < n: inc i
      continue
    while i < n and text[i] != '\n': inc i
    if i < n: inc i
    let nameLen = nEnd - nStart
    let verLen = vEnd - vStart
    if nameLen >= MaxComponentNameBytes or verLen >= MaxComponentVersionBytes:
      continue
    if dest.len >= MaxCtrcPins:
      return cpTooManyPins
    dest.add CtrcPin(name: text[nStart ..< nEnd], version: text[vStart ..< vEnd])
  cpOk

func pinFor*(pins: openArray[CtrcPin]; name: string): string =
  ## The FIRST pin for this name, which is the launcher's `findPin`: it scans
  ## forward and returns the first index whose name matches, so a `.ctrc` that
  ## pins one component twice is decided by the earlier line.
  for p in pins:
    if p.name == name: return p.version
  ""

# ---------------------------------------------------------------------------
# The launcher's three eligibility rules
# ---------------------------------------------------------------------------

func lexGreater*(a, b: string): bool =
  ## `versionEligible`'s comparison: unsigned byte by byte, then by length.
  ## `system.>` on `string` already does exactly this on every platform Nim
  ## targets; it is named here so the rule has a place to be read and so the
  ## mutation harness has one line to aim at.
  let minL = min(a.len, b.len)
  for k in 0 ..< minL:
    let x = uint8(a[k])
    let y = uint8(b[k])
    if x != y: return x > y
  a.len > b.len

func selectVersion*(installed: openArray[string]; pin: string;
                    activeVersion: string): VersionSelection =
  ## Which installed version of ONE component this level offers.
  ##
  ## * `installed` — every version present at this level, in any order.
  ## * `pin` — `.ctrc`'s version for this component, or `""`.
  ## * `activeVersion` — the version `<level>/active/<name>` points at, or `""`.
  ##
  ## THE ORDER IS THE LAUNCHER'S AND THE PIN IS ABSOLUTE. `scanLevelForCommand`
  ## `continue`s past every directory whose version is not the pinned one, so a
  ## pinned version that is not installed leaves the component unresolved at
  ## that level — it does NOT fall back to the highest. That is the behaviour a
  ## checked-in `.ctrc` is for, and `vsrPinnedMissing` is how a caller says so.
  if pin.len > 0:
    for v in installed:
      if v == pin:
        return VersionSelection(rule: vsrPinned, version: v)
    return VersionSelection(rule: vsrPinnedMissing, version: "")
  if activeVersion.len > 0:
    for v in installed:
      if v == activeVersion:
        return VersionSelection(rule: vsrActiveSymlink, version: v)
    # The symlink names a version that is not there. The launcher's
    # `versionEligible` returns false for EVERY peer in that case — the target
    # version equals none of them — so the level offers nothing.
    return VersionSelection(rule: vsrNone, version: "")
  var best = ""
  for v in installed:
    if best.len == 0 or lexGreater(v, best): best = v
  if best.len == 0: VersionSelection(rule: vsrNone, version: "")
  else: VersionSelection(rule: vsrHighest, version: best)

func describe*(s: VersionSelection; name: string): string =
  case s.rule
  of vsrNone: "no version of '" & name & "' is eligible here"
  of vsrPinned: "'" & name & "' is pinned to " & s.version & " by .ctrc"
  of vsrPinnedMissing:
    "'" & name & "' is pinned by .ctrc to a version that is not installed. " &
      "Run 'ct install " & name & "@<the pinned version>'"
  of vsrActiveSymlink:
    "'" & name & "' resolves to " & s.version & " through active/" & name
  of vsrHighest:
    "'" & name & "' resolves to " & s.version & ", the highest installed here"

func installHintFor*(name: string; version = ""): string =
  ## The ONE place that spells the install command. §8.3's mechanism, in the
  ## words a user types — and a single definition so the day the command word
  ## changes, it changes here.
  "ct install " & name & (if version.len > 0: "@" & version else: "")

func uninstallHintFor*(c: ComponentRef): string =
  "ct uninstall " & $c
