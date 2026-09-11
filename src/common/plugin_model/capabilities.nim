## plugin_model/capabilities.nim — PLAT-8's capability POLICY, and nothing else.
##
## Extensibility-Model.md §8.1.2 gives six grants and §8.1.1 gives the four
## things the host keeps on its own side of the boundary. PLAT-7 parsed the six
## and carried them on the manifest; its own status section records what that
## was worth:
##
##   "**Capabilities are RECORDED, not enforced.** `Capability` is parsed,
##    validated against §8.1.2's six and carried on the manifest. Nothing checks
##    it, because there is nothing yet to check: PLAT-8 owns the processes,
##    sockets and streams a grant would gate. A reader must not read
##    deliverable 1's tick as 'the sandbox exists'."
##
## This module is the "something to check". It is the ONE place that decides
## whether a grant permits a request, and it is deliberately PURE — no process,
## no socket, no filesystem, no clock, no `isonim`. Three consequences, each of
## which is why the decision lives here rather than at the call site:
##
##   * it runs in `common-units`, a lane that links no renderer and opens no
##     handle, so every refusal below is asserted without a real machine;
##   * `plugin_io.nim`'s native arm and the JS arm of the facade read the SAME
##     decision, so "the browser build has different rules" cannot happen;
##   * one predicate, one function (Verification-Harness-Traps §14). The rule
##     and its control are the same `decide` call with different inputs.
##
## ## THE DECISION IS TAKEN ON THE ADDRESS, NOT ON THE PLUGIN'S WORD FOR IT
##
## §8.1.2 splits the network in two: `socket:local` is "Unix domain sockets,
## loopback TCP" and `socket:remote` is "outbound connections beyond loopback,
## to declared hosts". A plugin therefore does not get to say which one it is
## asking for — it names a target and `classifyHost` says what that target is.
## The classification is on the LITERAL the plugin wrote, and it has three
## outcomes rather than two:
##
##   `acLoopback`  a literal address in `127.0.0.0/8` or `::1`. `socket:local`.
##   `acRemote`    any other literal address, and any name that is not
##                 `localhost`. `socket:remote`, plus a declared-host match.
##   `acAmbiguous` the name `localhost`, refused by name.
##
## The third is not pedantry. `localhost` is a NAME, resolved by the machine's
## own configuration, and a name that resolves somewhere else is exactly how a
## loopback-only grant becomes a network grant without anybody editing a
## manifest. Refusing it costs an author eight characters (`127.0.0.1`) and
## removes the whole class.
##
## AND THE LITERAL IS NOT THE LAST WORD. A name that classifies as `acRemote`
## is still only a name until it is resolved, so `plugin_io.nim` re-runs this
## decision on the RESOLVED address before it connects — see
## `decideResolvedAddress`. That second pass is what makes the refusal a claim
## about the machine rather than about the string.
##
## ## `socket:remote` DOES NOT IMPLY `socket:local`, AND NEITHER IMPLIES THE OTHER
##
## §8.4: "grants are per-kind and separate, so a visualiser plugin never
## acquires `process` or `socket:remote`". Separate means separate in both
## directions: a plugin holding `socket:remote` and connecting to `127.0.0.1`
## is refused, because reaching a local daemon is a different power from
## reaching a published service and the user granted one of them.
##
## THAT SENTENCE IS TRUE OF THE TWO SOCKET GRANTS AND FALSE OF `process`, and
## the next section is the whole reason this module was rewritten on
## 2026-09-09.
##
## ## `process` SUBSUMES EVERY OTHER GRANT. THIS IS STATED, NOT MITIGATED.
##
## PLAT-8 shipped claiming "**`process` is not the hole that would make
## [`socket:remote` grantable] pointless**", on three arguments: the executable
## is declared by name, the grants are separate, and the residual is only that
## "a declared program is a program — `sort` could open a socket". **All three
## were measured false by a verification pass on 2026-09-08**, and the measured
## shape is not the one the residual describes:
##
##   a plugin declaring `trace`, `fs:read` and `process` with `env` as its one
##   declared executable — NO socket capability, NO declared host, NO
##   trace-egress grant — read a recording and shipped it over TCP to a real
##   listener. The same plugin reached a shell with `env sh -c …`, argv only,
##   no metacharacters, and the user was shown no exfiltration disclosure.
##
## The residual as written ("`sort` could open a socket") describes a program
## doing something incidental. What actually happens is different in kind: an
## exec wrapper or an interpreter — `env`, `xargs`, `find`, `python3`, `sh`,
## `perl`, `make`, and dozens more — runs an arbitrary program of the plugin's
## choosing with the user's full authority. So `process` is not one grant
## beside five others. It is a **superset** of all of them at once: it bypasses
## the declared-host set, the loopback/remote split, the declared fs roots, the
## `trace` gate and the egress gate simultaneously.
##
## **AND IT CANNOT BE CONSTRAINED BY NAMING PROGRAMS.** A denylist of exec
## wrappers is the same shape as PLAT-7's import-extractor blocklist, which
## took seven passes and still has a documented residual; and it is unsound in
## principle rather than merely hard, because the host cannot know what an
## arbitrary declared binary does with its argv. `SubsumingCapabilities` below
## is therefore the honest model: **granting `process` grants everything**, and
## the rest of this module is written so that every rule which asks "what may
## this plugin do" asks it of `effectiveCapabilities` rather than of the
## declared set.
##
## ## THE COMPOSITION THAT NEEDS ITS OWN GRANT
##
## §8.1.2, and PLAT-8's verification gate: "**The combination that matters is
## `trace` + `socket:remote`.** A plugin that can read a recording and reach
## the network is an exfiltration path for whatever the recorded program held —
## credentials, keys, customer data. That pair requires an explicit, informed
## grant and should say plainly what it permits."
##
## `needsTraceEgressGrant` binds that pair **over the effective set**, which is
## the fix and is deliberately a rule about capability COMPOSITION rather than
## about program names:
##
##   * `trace` + `socket:remote` needs the grant, as before;
##   * `process` needs it **on its own**, because the effective set of a plugin
##     holding `process` contains both halves of the pair. A `process` grant
##     with no `trace` and no socket capability can still `cat` a recording and
##     open a socket, so a rule that waited for `trace` to be declared would be
##     waiting for a declaration the attack does not need.
##
## `TraceEgressGrant` is that grant, and it is a SEPARATE FIELD rather than a
## seventh capability, for a reason that is the gate's own wording: it must be
## "not implied by any other grant". A seventh enum member would be implied by
## nothing either, but it would be reachable the same way the other six are —
## by adding one string to the `capabilities` array — and the point of this
## grant is that it is not that. It carries an acknowledgement and a statement,
## the way §4.2's eager activation carries a reason, and `traceEgressPermitted`
## is `false` for every one of the sixty-four capability subsets on its own.
## `plugin_capabilities_test` asserts exactly that, by enumeration — **forty**
## of the sixty-four need the grant now, where sixteen did before.
##
## ## THE INVARIANT THIS MODULE OWES ITS USER
##
## **No configuration lets a recording leave the machine without the user being
## told.** Two rules hold it, and each covers what the other cannot:
##
##   * reading recorded data through the SDK needs `trace` (`irReadTrace`), and
##     `fs:read` is not a way around it — `plugin_io.normalisedFor` resolves
##     symlinks so the containment test cannot be aliased past;
##   * every capability composition that can move bytes off the machine
##     — `socket:remote` with `trace`, or `process` at all — is refused at LOAD
##     unless the manifest carries the acknowledgement, and the acknowledgement
##     forces `traceEgressDisclosure` into what the user reads.

import std/[strutils]

import ./diagnostics

type
  Capability* = enum
    ## Extensibility-Model.md §8.1.2's table, verbatim in its own spellings.
    ##
    ## It lived in `manifest.nim` under PLAT-7 and moved here under PLAT-8,
    ## unchanged, because the decision that reads it must be usable without the
    ## JSON parser — `plugin_io.nim` asks `decide` on every spawn and every
    ## connect and has no manifest text in hand.
    capProcess = "process"
    capSocketLocal = "socket:local"
    capSocketRemote = "socket:remote"
    capFsRead = "fs:read"
    capFsWrite = "fs:write"
    capTrace = "trace"

  DeclaredHost* = object
    ## §8.1.2: `socket:remote` grants "outbound connections beyond loopback, to
    ## declared hosts", and §8.4 makes the declaration the thing "the user can
    ## read before granting". A host with `port == AnyPort` permits every port
    ## on that host; a host with a port permits that one.
    host*: string
    port*: int

  TraceEgressGrant* = object
    ## The explicit, informed grant for `trace` + `socket:remote`.
    ##
    ## `acknowledged` is the decision. `statement` is what the author wrote
    ## about why, and it is required for the same reason §4.2 requires a reason
    ## for eager activation: a grant nobody had to explain is a grant nobody
    ## read. What the grant PERMITS is not taken from `statement` — it is
    ## derived by `traceEgressDisclosure` from the declared hosts, so it cannot
    ## drift from what the plugin can actually do.
    acknowledged*: bool
    statement*: string

  GrantSet* = object
    ## Everything a plugin was granted, in one value. Built by
    ## `manifest.parseManifest` and carried on `PluginManifest`; handed to
    ## `decide` by the host on every request.
    capabilities*: set[Capability]
    executables*: seq[string]
    hosts*: seq[DeclaredHost]
    readPaths*: seq[string]
    writePaths*: seq[string]
    traceEgress*: TraceEgressGrant

  IoRequestKind* = enum
    ## Every distinct power the SDK can be asked for. There is no `irOther`
    ## and no default arm: a request the policy does not know about is a
    ## compile error here rather than a silent permit at a call site.
    irSpawnProcess
    irConnectTcp
    irListenTcp
    irConnectUnix
    irListenUnix
    irReadPath
    irWritePath
    irReadTrace

  IoRequest* = object
    kind*: IoRequestKind
    target*: string
      ## The executable name, the host, the socket path or the file path — the
      ## literal the plugin wrote, never a resolved or normalised form. The
      ## host normalises; the plugin's word is the subject of the decision.
    port*: int

  AddressClass* = enum
    acLoopback
    acRemote
    acAmbiguous
    acUnspecified
      ## `0.0.0.0/8`, `::`, and the bare `0` spelling — the UNSPECIFIED
      ## address, which is neither of the two things §8.1.2 grants and had to
      ## become its own outcome rather than be folded into either.
      ##
      ## It was `acRemote` until 2026-09-09, and a verification pass killed the
      ## milestone's claim that "neither grant implies the other, in both
      ## directions" with it: `0.0.0.0` classifies remote, RESOLVES to
      ## `0.0.0.0` so the second pass agrees, and `connect(0.0.0.0)` reaches
      ## **127.0.0.1** on Linux. A `socket:remote`-only plugin therefore
      ## reached a loopback daemon, with both capability passes green.
      ##
      ## The reason it cannot be `acLoopback` either is that the two directions
      ## disagree: connecting to it reaches loopback, and BINDING it publishes
      ## on every interface the machine has. One class cannot be right for both
      ## verbs, so it is refused by name for both — the same third-outcome
      ## shape `localhost` already has, and for the same reason: the remedy
      ## costs an author eight characters and removes the whole class.

  Decision* = object
    permitted*: bool
    capability*: Capability
      ## Which grant the request was measured against. Meaningful only when
      ## the decision named one; `capabilityNamed` says whether it did.
    capabilityNamed*: bool
    reason*: string
      ## Empty when permitted. When refused it names the plugin, the power and
      ## the target, in that order — `PluginError.render`'s rule, for the same
      ## audience.

const
  AnyPort* = 0
    ## A declared host with no port. Written out rather than left as a bare
    ## `0` at three call sites.

  MinTraceEgressStatement* = 16
    ## A statement shorter than this is not a statement. The number is a
    ## policy and a small one; what it exists to refuse is `"ok"`.

# ---------------------------------------------------------------------------
# Address classification
# ---------------------------------------------------------------------------

func isLoopbackLiteral*(host: string): bool =
  ## `127.0.0.0/8`, `::1`, and the long spelling of `::1`. Parsed by hand
  ## rather than through `std/net.parseIpAddress`, because this module must
  ## stay pure and `std/net` is not: it drags in sockets on every target and
  ## does not compile on the JS backend the facade also serves.
  let h = host.strip()
  if h.len == 0: return false
  if h == "::1": return true
  if h.len > 2 and h[0] == '[' and h[^1] == ']':
    return isLoopbackLiteral(h[1 .. ^2])
  # The long IPv6 spelling, `0:0:0:0:0:0:0:1`.
  if ':' in h:
    let parts = h.split(':')
    if parts.len == 8:
      for i, p in parts:
        if p.len == 0: return false
        var seen = 0
        for c in p:
          if c notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}: return false
          seen = seen * 16 + (
            if c in {'0' .. '9'}: ord(c) - ord('0')
            elif c in {'a' .. 'f'}: ord(c) - ord('a') + 10
            else: ord(c) - ord('A') + 10)
        let want = if i == 7: 1 else: 0
        if seen != want: return false
      return true
    return false
  let octets = h.split('.')
  if octets.len != 4: return false
  var first = -1
  for i, o in octets:
    if o.len == 0 or o.len > 3: return false
    var n = 0
    for c in o:
      if c notin {'0' .. '9'}: return false
      n = n * 10 + (ord(c) - ord('0'))
    if n > 255: return false
    if i == 0: first = n
  first == 127

func v4MappedPart*(host: string): string =
  ## The dotted quad inside an IPv4-mapped or IPv4-compatible IPv6 literal —
  ## `::ffff:127.0.0.1`, `::127.0.0.1` — or `""` for anything else.
  ##
  ## Without this, `::ffff:127.0.0.1` classified `acRemote`: the loopback
  ## parser sees a `:` and demands eight hex groups, and gets four pieces with
  ## a `.` in the last. It is unambiguously loopback and a policy that calls it
  ## remote is one the resolver disagrees with — measured on 2026-09-09, where
  ## the second capability pass was the only thing that refused it.
  let h = host.strip()
  if '.' notin h or ':' notin h: return ""
  let idx = h.rfind(':')
  if idx < 0 or idx + 1 > h.high: return ""
  let head = h[0 .. idx].toLowerAscii()
  if head == "::" or head == "::ffff:" or head == "::0:":
    return h[idx + 1 .. ^1]
  ""

func isUnspecifiedLiteral*(host: string): bool =
  ## `0.0.0.0/8`, `::`, `0:0:0:0:0:0:0:0`, and the bare integer spellings
  ## `getaddrinfo` turns into `0.0.0.0`.
  ##
  ## The whole `/8` and not just `0.0.0.0`, because `0.0.0.0/8` is "this
  ## network" and the kernel routes it the same way — a policy that special-
  ## cased the four-zero spelling would be evaded by `0.1.2.3`.
  var h = host.strip()
  if h.len == 0: return false
  if h.len > 2 and h[0] == '[' and h[^1] == ']': h = h[1 .. ^2]
  if h.len == 0: return false
  if ':' in h:
    # AN IPv6 LITERAL IS UNSPECIFIED IFF IT IS ALL ZEROS, and the compressed
    # spellings are why this is a character test rather than a group count.
    # `::`, `::0`, `0::0`, `0:0:0:0:0:0:0:0` and `0::` are all the same
    # address; only the last has eight groups, and a group-counting test read
    # `::0` as remote. Nothing with a nonzero hex digit can pass, so `::1` is
    # unaffected.
    for c in h:
      if c != ':' and c != '0': return false
    return true
  if '.' in h:
    let octets = h.split('.')
    if octets.len != 4: return false
    var first = -1
    for i, o in octets:
      if o.len == 0 or o.len > 3: return false
      var n = 0
      for c in o:
        if c notin {'0' .. '9'}: return false
        n = n * 10 + (ord(c) - ord('0'))
      if n > 255: return false
      if i == 0: first = n
    return first == 0
  # A bare integer: `0`, `00`, `0x0`. `inet_aton` accepts all of them and
  # yields the unspecified address.
  if h.len > 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'):
    for c in h[2 .. ^1]:
      if c notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}: return false
      if c != '0': return false
    return h.len > 2
  for c in h:
    if c notin {'0' .. '9'}: return false
    if c != '0': return false
  true

func classifyHost*(host: string): AddressClass =
  ## See the header. `localhost` is `acAmbiguous` BY NAME; `0.0.0.0/8` and `::`
  ## are `acUnspecified`; every other name is `acRemote`, so an author who
  ## wants loopback writes the address.
  ##
  ## THE ORDER IS THE POLICY. Unspecified is tested before loopback because
  ## `0.0.0.0` reaches loopback on a connect and must still not be treated as
  ## a loopback literal — see `acUnspecified`.
  var h = host.strip()
  if h.len > 2 and h[0] == '[' and h[^1] == ']': h = h[1 .. ^2]
  let mapped = v4MappedPart(h)
  if mapped.len > 0:
    # Recurses at most once: the tail carries no ':' by construction.
    return classifyHost(mapped)
  if isUnspecifiedLiteral(h): return acUnspecified
  if isLoopbackLiteral(h): return acLoopback
  if h.toLowerAscii() == "localhost" or
     h.toLowerAscii() == "localhost." or
     h.toLowerAscii().endsWith(".localhost"):
    return acAmbiguous
  acRemote

# ---------------------------------------------------------------------------
# The declared sets
# ---------------------------------------------------------------------------

func isBareExecutableName*(name: string): bool =
  ## §8.1.1: "The plugin names an executable; the host resolves it against a
  ## declared set and its own PATH policy. **A plugin does not hand over an
  ## absolute path of its choosing.**"
  ##
  ## So a name is a NAME: no separator in either spelling, no `..`, no leading
  ## dash (which `execve` would hand to the program as an option), nothing
  ## empty. Everything else is refused rather than sanitised, because
  ## sanitising a path is the filter §8.1.1 exists to not need.
  if name.len == 0: return false
  if '/' in name or '\\' in name: return false
  if name.startsWith("-"): return false
  if name == "." or name == "..": return false
  for c in name:
    if c in {'\0', '\n', '\r'}: return false
  true

func declaresExecutable*(g: GrantSet; name: string): bool =
  for e in g.executables:
    if e == name: return true
  false

func declaresHost*(g: GrantSet; host: string; port: int): bool =
  ## Exact host match, and either an exact port or the host's `AnyPort`.
  ## There is no wildcard on the host: `*.example.com` would be a pattern
  ## language, and a pattern language in a security declaration is a second
  ## place for a bug that the user reading the manifest cannot evaluate.
  for h in g.hosts:
    if h.host == host and (h.port == AnyPort or h.port == port):
      return true
  false

func pathIsUnder*(path, root: string): bool =
  ## Textual containment on already-normalised paths. The NORMALISATION is the
  ## host's (`plugin_io.nim` calls `absolutePath` + `normalizedPath` before it
  ## asks), because normalising here would need the filesystem this module
  ## refuses to touch. A `..` surviving into either argument is refused
  ## outright rather than resolved.
  if path.len == 0 or root.len == 0: return false
  if ".." in path or ".." in root: return false
  if path == root: return true
  let r = if root.endsWith("/"): root else: root & "/"
  path.startsWith(r)

func declaresReadPath*(g: GrantSet; path: string): bool =
  for r in g.readPaths:
    if pathIsUnder(path, r): return true
  false

func declaresWritePath*(g: GrantSet; path: string): bool =
  for w in g.writePaths:
    if pathIsUnder(path, w): return true
  false

# ---------------------------------------------------------------------------
# The pair
# ---------------------------------------------------------------------------

const
  SubsumingCapabilities* = {capProcess}
    ## The capabilities whose grant is NOT bounded by anything else in this
    ## module — see the header. A spawned program runs outside the sandbox with
    ## the user's full authority, so `process` confers, in effect, every other
    ## capability at once.
    ##
    ## IT IS A SET AND NOT A BOOL BECAUSE THE QUESTION RECURS. If a later
    ## milestone adds a grant with the same character — an embedded
    ## interpreter, a `dlopen`, a "run this WASM module with host imports" —
    ## the one edit that makes every rule below account for it is adding the
    ## member here, rather than a second `if` in each of them.

func effectiveCapabilities*(caps: set[Capability]): set[Capability] =
  ## What the plugin can ACTUALLY do, which is not always what it declared.
  ##
  ## THIS IS THE ONE FUNCTION THAT KNOWS ABOUT SUBSUMPTION, and every rule that
  ## asks "may this plugin do X" asks it here rather than of `caps` — one
  ## predicate, one function (Verification-Harness-Traps §14). A second place
  ## that tested `capProcess in caps` on its own would be a second thing that
  ## can be wrong while this one goes on agreeing with itself.
  result = caps
  if (caps * SubsumingCapabilities) != {}:
    result = {low(Capability) .. high(Capability)}

func subsumesEverything*(caps: set[Capability]): bool =
  ## Whether this grant set holds a capability that confers the others. Used by
  ## the disclosures, so a user is told WHY the wide sentence applies to them.
  (caps * SubsumingCapabilities) != {}

func needsTraceEgressGrant*(caps: set[Capability]): bool =
  ## The composition §8.1.2 names, asked of the EFFECTIVE set.
  ##
  ## `trace` + `socket:remote` is the pair the spec calls out. `process` alone
  ## satisfies it too, because `effectiveCapabilities` says so: a plugin that
  ## may spawn a program may read a recording through that program and open a
  ## socket through it, and neither of those needs a capability the plugin ever
  ## declared. That was measured rather than argued — see the header.
  let eff = effectiveCapabilities(caps)
  capTrace in eff and capSocketRemote in eff

func traceEgressPermitted*(g: GrantSet): bool =
  ## `true` only when the plugin does not hold the pair, or holds it WITH the
  ## explicit grant.
  ##
  ## THIS IS THE FUNCTION THE VERIFICATION GATE IS ABOUT. It reads
  ## `g.traceEgress` and the capability set, and there is no path through it on
  ## which a capability alone makes it `true` while the pair is held — which is
  ## the "not implied by any other grant" half, asserted over all sixty-four
  ## subsets in `plugin_capabilities_test`.
  if not needsTraceEgressGrant(g.capabilities): return true
  g.traceEgress.acknowledged and
    g.traceEgress.statement.strip().len >= MinTraceEgressStatement

const
  SubsumptionHeadline* =
    "'process' SUBSUMES every other capability here: a spawned program runs " &
    "OUTSIDE this sandbox, with your full user authority."
    ## THE ONE SENTENCE, IN ONE PLACE. It appears twice in what a user reads —
    ## on the `process` row of `describeGrants`, where somebody scanning one
    ## line per grant will see it, and inside the egress disclosure, which is
    ## also the load-time error text and must stand alone. Two renderings of
    ## one fact is exactly the §14 shape, so the fact is a constant and the
    ## long form is built from it rather than beside it.

func subsumptionDisclosure*(g: GrantSet): string =
  ## The full sentence a `process` grant owes its user, DERIVED from the
  ## declared executables rather than from a claim about them.
  ##
  ## It names the declared set and then says, in the same breath, that the set
  ## does not bound anything — because a user who reads `may spawn: env` and
  ## nothing else will reasonably conclude that `env` is the limit, and it is
  ## not. That conclusion is exactly what PLAT-8 shipped believing.
  SubsumptionHeadline &
    " It may read any file you can read — including recordings — and open " &
    "any network connection you can open. Declaring " &
    (if g.executables.len == 0: "no executables"
     else: g.executables.join(", ")) &
    " does not bound that, because a declared program may itself run another " &
    "one (env, xargs, find, sh, python3 and many others do), and the host " &
    "cannot tell which will."

func traceEgressDisclosure*(id: PluginId; g: GrantSet): string =
  ## What the grant PERMITS, said plainly, DERIVED from the grant rather than
  ## quoted from the author. §8.1.2 asks the grant to "say plainly what it
  ## permits"; an author's own sentence is what they were willing to write, and
  ## the two are not the same claim. This is the one a user is shown.
  ##
  ## IT DERIVES THE REACH FROM THE COMPOSITION THAT TRIGGERED IT, and there are
  ## two of those now. Until 2026-09-09 this sentence began "is being granted
  ## BOTH 'trace' and 'socket:remote'" unconditionally and ended by listing the
  ## declared hosts — so for the composition that actually exfiltrated a
  ## recording in the verification pass (`trace` + `fs:read` + `process`, no
  ## hosts at all) it would have named the wrong grant and then reported the
  ## reach as "no declared host, which makes the pair useless". Both halves
  ## false, in the one sentence whose job is to be true.
  var hosts: seq[string] = @[]
  for h in g.hosts:
    hosts.add(if h.port == AnyPort: h.host else: h.host & ":" & $h.port)
  let viaProcess = subsumesEverything(g.capabilities)
  let granted =
    if viaProcess and capSocketRemote in g.capabilities and
       capTrace in g.capabilities:
      "'process', 'trace' and 'socket:remote'"
    elif viaProcess and capTrace in g.capabilities:
      "'trace' and 'process'"
    elif viaProcess:
      "'process'"
    else:
      "BOTH 'trace' and 'socket:remote'"
  let reach =
    if viaProcess and hosts.len > 0:
      "the declared hosts " & hosts.join(", ") & ", AND to any host a " &
        "spawned program can reach, which is every host this machine can reach"
    elif viaProcess:
      "any host this machine can reach, through a spawned program"
    elif hosts.len == 0:
      "no declared host, which makes the pair useless"
    else:
      hosts.join(", ")
  result = "plugin '" & id & "' is being granted " & granted & ". " &
    "It may read recorded program data — whatever the recording held, " &
    "including credentials, keys and customer data — and it may send it to " &
    reach & ". "
  if viaProcess:
    result.add subsumptionDisclosure(g) & " "
  result.add "No capability on the list implies this grant; " &
    "acknowledging it in the manifest is the only thing that permits it."

# ---------------------------------------------------------------------------
# The decision
# ---------------------------------------------------------------------------

func permit(cap: Capability): Decision =
  Decision(permitted: true, capability: cap, capabilityNamed: true)

func refuse(id: PluginId; cap: Capability; what, target, why: string): Decision =
  ## THE CAPABILITY IS IN THE TEXT, not only in the field. `Decision.capability`
  ## is what a caller branches on, but the outcome records the SDK hands a
  ## plugin carry only the message — and a refusal that did not name the grant
  ## it was measured against leaves an author guessing which of six to ask for.
  Decision(permitted: false, capability: cap, capabilityNamed: true,
           reason: "plugin '" & id & "': " & what & " '" & target &
                   "' refused (needs '" & $cap & "') — " & why)

func refuseUnnamed(id: PluginId; what, target, why: string): Decision =
  Decision(permitted: false, capabilityNamed: false,
           reason: "plugin '" & id & "': " & what & " '" & target &
                   "' refused — " & why)

func decide*(g: GrantSet; id: PluginId; req: IoRequest): Decision =
  ## The whole policy, in one function both arms of the SDK call.
  ##
  ## Every arm is a refusal or a permit; there is no fall-through, and the
  ## `case` is over a closed enum so a new power cannot be added without a
  ## decision being written for it.
  case req.kind
  of irSpawnProcess:
    if capProcess notin g.capabilities:
      return refuse(id, capProcess, "spawning", req.target,
        "it was not granted 'process'")
    if not isBareExecutableName(req.target):
      return refuse(id, capProcess, "spawning", req.target,
        "an executable is named, not pathed: the host resolves the name " &
        "against the declared set and its own PATH policy")
    if not g.declaresExecutable(req.target):
      return refuse(id, capProcess, "spawning", req.target,
        "it is not in the declared executable set (" &
        (if g.executables.len == 0: "which is empty"
         else: g.executables.join(", ")) & ")")
    # THE EGRESS GATE BINDS `process`, and this is the second of the two arms
    # that hold it — `manifest.parseManifest` refuses the same composition at
    # LOAD, so a plugin reaching here without the acknowledgement got its
    # manifest past the parser some other way. Graded separately from the load
    # arm for the reason P12/P8 already are: neither may cover for the other.
    if not traceEgressPermitted(g):
      return refuse(id, capProcess, "spawning", req.target,
        "'process' subsumes every other capability, so it is an exfiltration " &
        "path on its own and requires the explicit trace-egress grant. " &
        traceEgressDisclosure(id, g))
    permit(capProcess)

  of irConnectTcp, irListenTcp:
    let what = if req.kind == irConnectTcp: "connecting to" else: "listening on"
    let target = req.target & ":" & $req.port
    case classifyHost(req.target)
    of acAmbiguous:
      return refuseUnnamed(id, what, target,
        "'localhost' is a name the machine resolves, not an address. A grant " &
        "for loopback must name loopback: write 127.0.0.1 or ::1")
    of acUnspecified:
      return refuseUnnamed(id, what, target,
        "'" & req.target & "' is the UNSPECIFIED address (0.0.0.0/8, ::, or " &
        "the bare integer spelling of them), which is not a destination. " &
        "Connecting to it reaches loopback, and binding it publishes on every " &
        "interface this machine has — so it is neither of the two things " &
        "§8.1.2 grants, and treating it as one of them would let the other " &
        "through. Write 127.0.0.1 or ::1 for loopback, or name the host you " &
        "mean")
    of acLoopback:
      if capSocketLocal notin g.capabilities:
        return refuse(id, capSocketLocal, what, target,
          "loopback TCP is 'socket:local', and it was not granted" &
          (if capSocketRemote in g.capabilities:
             " ('socket:remote' does not imply it: the grants are per-kind " &
             "and separate)"
           else: ""))
      permit(capSocketLocal)
    of acRemote:
      if capSocketRemote notin g.capabilities:
        return refuse(id, capSocketRemote, what, target,
          "it is beyond loopback, which is 'socket:remote', and it was not " &
          "granted" &
          (if capSocketLocal in g.capabilities:
             " ('socket:local' does not imply it)" else: ""))
      if req.kind == irListenTcp:
        return refuse(id, capSocketRemote, what, target,
          "a plugin may listen on loopback only. §8.1.2 grants " &
          "'socket:remote' for OUTBOUND connections; a listener beyond " &
          "loopback publishes a service from inside the debugger")
      if not g.declaresHost(req.target, req.port):
        return refuse(id, capSocketRemote, what, target,
          "it is not in the declared host set (" &
          (if g.hosts.len == 0: "which is empty"
           else: (block:
             var hs: seq[string] = @[]
             for h in g.hosts:
               hs.add(if h.port == AnyPort: h.host else: h.host & ":" & $h.port)
             hs.join(", "))) & ")")
      if not traceEgressPermitted(g):
        return refuse(id, capSocketRemote, what, target,
          "this plugin also holds 'trace', and that pair is an exfiltration " &
          "path. It requires the explicit trace-egress grant, which is not " &
          "implied by either capability. " & traceEgressDisclosure(id, g))
      permit(capSocketRemote)

  of irConnectUnix, irListenUnix:
    let what = if req.kind == irConnectUnix: "connecting to" else: "listening on"
    if capSocketLocal notin g.capabilities:
      return refuse(id, capSocketLocal, what, req.target,
        "a Unix domain socket is 'socket:local', and it was not granted")
    permit(capSocketLocal)

  of irReadPath:
    if capFsRead notin g.capabilities:
      return refuse(id, capFsRead, "reading", req.target,
        "it was not granted 'fs:read'")
    if not g.declaresReadPath(req.target):
      return refuse(id, capFsRead, "reading", req.target,
        "it is not under a declared readable path (" &
        (if g.readPaths.len == 0: "which is empty"
         else: g.readPaths.join(", ")) & ")")
    permit(capFsRead)

  of irWritePath:
    if capFsWrite notin g.capabilities:
      return refuse(id, capFsWrite, "writing", req.target,
        "it was not granted 'fs:write'")
    if not g.declaresWritePath(req.target):
      return refuse(id, capFsWrite, "writing", req.target,
        "it is not under a declared writable path (" &
        (if g.writePaths.len == 0: "which is empty"
         else: g.writePaths.join(", ")) & ")")
    permit(capFsWrite)

  of irReadTrace:
    if capTrace notin g.capabilities:
      return refuse(id, capTrace, "reading recorded data of", req.target,
        "it was not granted 'trace'")
    permit(capTrace)

func decideResolvedAddress*(g: GrantSet; id: PluginId; wrote: string;
                            resolved: string; port: int): Decision =
  ## THE SECOND PASS, and the one that makes the refusal a claim about the
  ## machine rather than about the string the plugin typed.
  ##
  ## A name classifies as `acRemote` before it is resolved, so a plugin without
  ## `socket:remote` is already refused by `decide`. The dangerous direction is
  ## the other one: a name or an address that LOOKED loopback but resolves
  ## somewhere else, and a plugin holding only `socket:local` following it out
  ## of the machine. This is called by `plugin_io.nim` after resolution and
  ## before the connect, with the address the kernel would actually be given.
  ##
  ## IT RE-CHECKS THE ADDRESS CLASS AND NOT THE DECLARED-HOST SET, and that
  ## distinction is load-bearing rather than an optimisation. `decide` matched
  ## the NAME the plugin wrote against `hosts`, which is what a user read in
  ## the manifest; re-running the whole of `decide` on the resolved literal
  ## would then demand that `93.184.216.34` also be declared, and every
  ## legitimate `symbols.example.com` connection would be refused. What the
  ## second pass is for is narrower and is the thing the first pass cannot
  ## know: whether the bytes are about to leave the machine.
  ##
  ## So the two passes ask different questions of the same policy — pass one
  ## "may this plugin reach this declared target", pass two "is this address
  ## loopback, and does the plugin hold the grant that covers it" — and pass
  ## two reaches them through `classifyHost`, the same function pass one uses.
  case classifyHost(resolved)
  of acLoopback:
    if capSocketLocal in g.capabilities:
      return permit(capSocketLocal)
    result = refuse(id, capSocketLocal, "connecting to", resolved,
      "it is loopback, which is 'socket:local', and it was not granted")
  of acAmbiguous:
    result = refuseUnnamed(id, "connecting to", resolved,
      "the resolver returned a name rather than an address")
  of acUnspecified:
    # FAIL CLOSED. A resolver that answers `0.0.0.0` has not named a
    # destination, and the kernel's own interpretation of a connect to it is
    # loopback — so permitting it under either socket grant would let the
    # wrong one through. The literal arm refuses this by name; this arm is
    # what catches a NAME that resolves to it.
    result = refuseUnnamed(id, "connecting to", resolved,
      "the resolver returned the unspecified address, which is not a " &
      "destination; a connect to it reaches loopback rather than the host " &
      "that was named")
  of acRemote:
    if capSocketRemote in g.capabilities:
      return permit(capSocketRemote)
    result = refuse(id, capSocketRemote, "connecting to", resolved,
      "it is beyond loopback, which is 'socket:remote', and it was not granted")
  if wrote != resolved:
    result.reason = result.reason & " (the plugin named '" & wrote &
      "', which resolved to '" & resolved & "')"

func describeGrants*(id: PluginId; g: GrantSet): string =
  ## What §8.4 calls "declared in a manifest the user can read before
  ## granting", rendered. Used by the host's report and by the trace-egress
  ## disclosure, so a user is never shown a capability without its declared
  ## set.
  var lines: seq[string] = @[]
  for c in Capability:
    if c notin g.capabilities: continue
    case c
    of capProcess:
      # THE SUBSUMPTION IS ON THE `process` ROW ITSELF, not only in the egress
      # disclosure below it. A user scanning the list reads one line per grant
      # and takes each line as the extent of that grant; before 2026-09-09 this
      # line read `process — may spawn: env` and stopped, which states the
      # declared set correctly and implies a bound that does not exist.
      lines.add "  process    — may spawn: " &
        (if g.executables.len == 0: "(nothing declared)"
         else: g.executables.join(", "))
      lines.add "             ! " & SubsumptionHeadline
      lines.add "               The declared set above is not a bound — see " &
                "the grant note below."
    of capSocketLocal:
      lines.add "  socket:local — Unix domain sockets and loopback TCP"
    of capSocketRemote:
      var hs: seq[string] = @[]
      for h in g.hosts:
        hs.add(if h.port == AnyPort: h.host else: h.host & ":" & $h.port)
      lines.add "  socket:remote — may connect to: " &
        (if hs.len == 0: "(nothing declared)" else: hs.join(", "))
    of capFsRead:
      lines.add "  fs:read    — may read under: " &
        (if g.readPaths.len == 0: "(nothing declared)"
         else: g.readPaths.join(", "))
    of capFsWrite:
      lines.add "  fs:write   — may write under: " &
        (if g.writePaths.len == 0: "(nothing declared)"
         else: g.writePaths.join(", "))
    of capTrace:
      lines.add "  trace      — may read recorded program data"
  if needsTraceEgressGrant(g.capabilities):
    lines.add "  " & traceEgressDisclosure(id, g)
  if lines.len == 0:
    return "plugin '" & id & "' was granted nothing"
  "plugin '" & id & "' was granted:\n" & lines.join("\n")
