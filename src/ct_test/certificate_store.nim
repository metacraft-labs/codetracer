## The local certificate store — **discovery only, and strictly read-only.**
##
## Implements ``test-certificates-spec/Transport.md`` §2.4 (reading the local
## certificate store) and §5 (discovery). It answers one question — *which
## certificate records exist for these content ids, and in what order did they
## land* — and it answers it without deciding anything about them. Reading a
## record, checking a signature and evaluating coverage all belong to
## ``certificate.nim`` and ``certificate_verification.nim``, which this module
## deliberately does not duplicate.
##
## Read-only, and that is a conformance property rather than a convention.
## Nothing here creates, writes, renames or removes a file, and nothing here
## can reach a signing primitive: the only route to a certificate signature in
## CodeTracer is ``certificate_issuance.runAndAttest`` (Standard.md §6.2), and
## the seam below (``CertificateStoreAccess``) offers no write operation for a
## caller to supply one through.
##
## What "the store" is
## -------------------
## The **local certificate store** (Transport.md §2), per user and addressed by
## content id: ``<root>/v1/<algorithm>/<digest>/*.toml`` in BOTH of the user's
## roots (§2.1, resolved by ``certificate_store_roots``). A lookup lists only
## the directories of the content ids the caller asks about (§2.4) — it never
## enumerates the store, which is shared by every repository the user works
## in. Every conforming producer writes it: `ct test`
## (``certificate_local_store``) and reprobuild alike, so a record reads
## identically whichever produced it.
##
## Nothing under the working tree is read any more:
##
## * ``.ct/certificates`` — `ct test` wrote one record per platform there
##   before the local store existed (CTC-2); since CTC-3e it writes nothing
##   under ``.ct/`` and nothing reads that directory, so records left there are
##   simply not seen (``AbandonedCtTestStoreDir``).
## * ``.repro/workspace/certificates`` — reprobuild's former workspace store,
##   pooled here until reprobuild published to the local store. It does now
##   (reprobuild-pm Test-Certificates TC-8c; reprobuild ``agents``
##   1e70a388c), so the directory is no longer read either
##   (``AbandonedReprobuildStoreDir``). Its ``registered-keys.toml`` went with
##   it: that file is reprobuild's own trust policy, in reprobuild's own schema
##   (``reprobuild.registered-keys.v1``), which this reader never parsed.
##
## **The git-notes carrier is not read here.** Notes are push transport,
## populated from the local store by the test-certificates helper tooling
## (Transport.md §3, Tooling.md); a consumer on the machine that ran the tests
## finds everything in the local store.
##
## Absence is not an error; an incomplete search is not absence
## --------------------------------------------------------------
## A store with nothing for this content — no `ct test`, no reprobuild, a
## project that does not use certificates — is an ordinary state and MUST NOT
## be reported as a failure (Transport.md §5). It is ``present = false`` here,
## and the indicator renders "no certificates".
##
## A root this host could not search is a different answer, kept apart for the
## same reason Verification.md §3.1 keeps an empty key store apart from an
## unreadable one: one says "there is nothing here", the other says "I could
## not look". Transport.md §2.1: a reader finds no certificates in an
## UNRESOLVED root and continues searching the other root, and it reports that
## the search could not cover that root rather than claiming it was searched
## and empty. A root that exists and could not be read is the same situation
## (§2.4). Both make the search ``incomplete``; the other root is always still
## searched, so a certificate found there still counts. Only a host with no
## local store at all (a browser tab) is ``unreadable``.

import std/[algorithm, strutils]

import certificate
import certificate_content_id
import certificate_store_roots

export certificate_store_roots

const
  AbandonedCtTestStoreDir* = ".ct/certificates"
    ## Where `ct test` published before CTC-3e (one ``<platform>.toml`` per
    ## platform). **Neither read nor written any more**: certificates are
    ## ephemeral and never live in the working tree (Transport.md §2). Named
    ## only so a test can prove nothing here reaches a reader, and so the
    ## records left behind in existing workspaces have a name in the docs.

  AbandonedReprobuildStoreDir* = ".repro/workspace/certificates"
    ## reprobuild's former workspace store. Pooled by this reader until
    ## reprobuild published every certificate to the local store; **no longer
    ## read**. Named only so a test can prove nothing here reaches a reader.

  LocalStoreLayout* = "v1"
    ## The layout version directory under each local-store root
    ## (Transport.md §2.2).

type
  StoreReadStatus* = enum
    ## Three-valued for the reason everything in this domain is: "there is
    ## nothing there" and "I could not look" are different answers, and only
    ## the second is a configuration fault (Verification.md §3.1, §7).
    srOk
    srAbsent
    srUnreadable

  StoreRead* = object
    status*: StoreReadStatus
    text*: string
    detail*: string
      ## Prose for a human. Never compared by anything.

  StoreListing* = object
    status*: StoreReadStatus
    names*: seq[string]
      ## Entry names only, never paths — the caller joins. A listing that
      ## carried absolute paths would leak the host's layout into a model a
      ## browser tab is also expected to build.
    detail*: string

  CertificateStoreAccess* = object
    ## How this module reaches a filesystem.
    ##
    ## Injected, and **synchronous**, so exactly one implementation of the
    ## discovery rules serves every front end: the native host fills these in
    ## with ``std/os``, the Electron renderer with the platform facade's
    ## filesystem operations, and a test with an in-memory tree. An
    ## asynchronous seam would have forced either a second, synchronous copy
    ## of the ordering rules for the tests or a promise-shaped ViewModel, and
    ## the operations here read at most a handful of small files.
    ##
    ## There is deliberately **no write, no create and no remove**. A
    ## read-only display cannot become an issuance path by way of a caller
    ## supplying a richer seam.
    ##
    ## Not ``{.gcsafe.}``, and that is not an oversight: the front end fills
    ## these in from ``FileSystemFacade``, whose operations are ordinary
    ## closures, so a ``gcsafe`` seam would exclude the one host this exists to
    ## serve.
    listFiles*: proc(dir: string): StoreListing {.closure.}
      ## Regular files directly inside ``dir``. ``srAbsent`` when the directory
      ## does not exist — which is the ordinary "no store" case and not a
      ## failure.
    readText*: proc(path: string): StoreRead {.closure.}
    modifiedMs*: proc(path: string): int64 {.closure.}
      ## Milliseconds since the Unix epoch, or ``0`` when unknown. Not a
      ## ``times.Time``: this crosses to a JS front end, and a strongly-typed
      ## instant would imply an agreement about clocks that the hosts cannot
      ## make.

  StoredCertificate* = object
    ## One record as found, with the name a report will use for it. The text
    ## is carried verbatim; nothing here interprets it beyond the local
    ## store's directory check (``lookupLocalStore``).
    name*: string
      ## The record's full path, e.g.
      ## ``/home/u/.local/state/test-certificates/v1/git-tree-sha1/<digest>/<hash>.toml``.
      ## Shown to a human and used as the deterministic final tiebreak in the
      ## ordering.
    text*: string
    receivedAtMs*: int64
      ## When this file last changed on the host that is displaying it.

  CertificateStore* = object
    ## What discovery found. Every field exists because Transport.md §5 asks
    ## discovery to be **explicit about what it searched** and **non-fatal when
    ## empty**.
    searched*: seq[string]
      ## Every content directory this pass looked in, whether or not it
      ## existed.
    present*: bool
      ## At least one record was found (or found and rejected, or a root could
      ## not be searched). ``false`` is the ordinary "nothing here for this
      ## content" state.
    unreadable*: bool
      ## This host has no local store at all (``roots.available = false``,
      ## a browser tab): it could not look anywhere. Distinct from
      ## ``present = false`` and from ``incomplete``.
    unreadableReason*: string
    incomplete*: bool
      ## At least one root could not be searched — unresolved (Transport.md
      ## §2.1) or existing and unreadable (§2.4) — while the other was. What
      ## was found in the searched root still counts; what was NOT found is
      ## not evidence that nothing exists, so "no certificates" must not be
      ## claimed (§5).
    incompleteReasons*: seq[string]
      ## Why, one sentence per root or directory that could not be covered.
    certificates*: seq[StoredCertificate]
      ## **Newest first** — see ``orderByArrival``.
    keyStorePath*: string
      ## The registered-key store (Verification.md §3.1) a host supplies as the
      ## deployment's trust policy. Empty when none was supplied, which is the
      ## case for every shipped host today: no reader here populates it (the
      ## workspace directory that used to carry one is no longer read, see the
      ## module header). A host or test that does supply one sets both fields.
    keyStore*: KeyStore
      ## Parsed. ``readable = false`` when a store file exists and could not be
      ## read, which is what makes the outcome unverifiable rather than
      ## not-covered (Verification.md §3.1). When ``keyStorePath`` is empty
      ## this is the zero value, whose ``readable`` is ``false``; callers MUST
      ## test ``keyStorePath.len > 0`` before treating it as an answer, which
      ## is what ``hasKeyStore`` below is for.
    rejected*: seq[string]
      ## Records that were found and NOT made candidates, each with the
      ## reason: a record whose own ``content`` does not match the directory it
      ## was found in (Transport.md §2.4: "reported and ignored").
    problems*: seq[string]
      ## Faults that did not stop the search, in words an operator can act
      ## on: every variable the root resolver ignored, and a content id that
      ## could not name a directory. A root that could not be searched is in
      ## ``incompleteReasons`` instead.

  LocalStoreQuery* = object
    ## What to look up in the local certificate store (Transport.md §2.4).
    roots*: CertificateStoreRoots
      ## Both roots, as the host resolved them (``certificate_store_roots``).
      ## ``available = false`` — a host with no per-user directory, such as a
      ## browser tab — makes the whole read ``unreadable``: it could not look,
      ## which is not the same as finding nothing.
    contentIds*: seq[string]
      ## The content ids whose directories are listed, e.g. the working
      ## tree's. A reader never enumerates the store: it is shared by every
      ## repository the user works in, and a record for some other content is
      ## not evidence about this one. Empty: the local store is not consulted
      ## (the state has no content id to look up).

  LocalStoreLookup* = object
    ## One content id looked up in both roots.
    searched*: seq[string]
      ## Every content directory listed, whether or not it existed.
    found*: seq[StoredCertificate]
      ## The candidates, with byte-identical copies across the two roots
      ## collapsed into one (§2.4: "a reader may skip a copy byte-identical to
      ## one it has evaluated"); every non-identical copy is kept.
    rejected*: seq[string]
    problems*: seq[string]
    unreadable*: bool
      ## The host has no local store at all (``roots.available = false``).
    unreadableReason*: string
    incomplete*: bool
      ## A root was unresolved, or it (or this content directory in it, or a
      ## record in that directory) could not be read. The other root was still
      ## searched.
    incompleteReasons*: seq[string]

proc hasKeyStore*(store: CertificateStore): bool =
  ## Whether a trust policy was supplied at all.
  ##
  ## The distinction this exists to keep: a deployment with **no**
  ## registered-key store has not said which keys it trusts, and a consumer
  ## that answered "fail-closed, nobody is trusted" would be inventing a
  ## deployment decision nobody made. Verification.md §3.1's fail-closed rule
  ## is about a consumer *that requires signatures*; whether to require them
  ## is the deployment's call, and the absence of a store file is the absence
  ## of that call rather than a negative answer to it.
  store.keyStorePath.len > 0

proc compareArrival(a, b: StoredCertificate): int =
  ## Newest first, with every tie broken deterministically.
  ##
  ## The primary key is **when the store received the file**, not the record's
  ## own ``issued_at``. ``issued_at`` is informational and explicitly not a
  ## trust input (Verification.md §4.3): clock skew is ordinary, a consumer
  ## MUST NOT reject a certificate for a future timestamp, and a producer on a
  ## misconfigured machine could otherwise pin itself permanently at the top of
  ## this list. What the store can observe honestly is the order things arrived
  ## in, and "the last produced certificate" is the last one that landed.
  ##
  ## It is still only a *selection* rule. Whichever record wins is then
  ## evaluated on its own merits by ``certificate_verification``, so a wrong
  ## guess here cannot turn an invalid certificate into a valid one — it can
  ## only show the user the wrong one of several, which is why the tiebreaks
  ## below are total rather than left to the filesystem's enumeration order.
  ##
  ## The name tiebreak is not decoration: ``modifiedMs`` answers ``0`` for
  ## "unknown", so on a host whose ``stat`` is unavailable EVERY pair ties on
  ## the primary key and the whole order falls through to it (pinned by
  ## ``certificate_store_test.nim``, "records that arrived together are
  ## ordered by name, the greater first").
  if a.receivedAtMs != b.receivedAtMs:
    return if a.receivedAtMs > b.receivedAtMs: -1 else: 1
  # `compareBytes` rather than `cmp`, so the ordering is the same unsigned
  # byte order the canonical payload sorts targets in and cannot drift into a
  # locale collation on some host.
  let byName = compareBytes(a.name, b.name)
  if byName != 0:
    return -byName
  0

proc orderByArrival*(certificates: var seq[StoredCertificate]) =
  ## Sort newest-first in place. Exposed so a test can pin the rule directly.
  certificates.sort(compareArrival)

proc lastProduced*(store: CertificateStore): StoredCertificate =
  ## The record the indicator speaks for when none binds. Callers MUST check
  ## ``store.certificates.len > 0`` first; this returns the zero value for an
  ## empty store rather than raising, because "the store is empty" is a state
  ## every caller already has to render and not an exceptional condition.
  if store.certificates.len == 0:
    return StoredCertificate()
  store.certificates[0]

proc join(dir, name: string): string =
  ## Store paths are always ``/``-separated, on every host. They are shown to a
  ## human and compared as strings; a backslash on Windows would make the same
  ## store sort differently there.
  if dir.len == 0: name
  elif dir.endsWith("/"): dir & name
  else: dir & "/" & name

proc localStoreContentDir*(contentId: string):
    tuple[ok: bool; relative: string; problem: string] =
  ## Transport §2.2 uses the two components validated by Content-Id §1.
  ## Unknown portable algorithms are relayed verbatim, never computed here.
  let parsed = parseContentId(contentId)
  if parsed.form == cifMalformed:
    return (false, "", "the content id is malformed: " & parsed.problem)
  (true, LocalStoreLayout & "/" & parsed.algorithmName & "/" & parsed.digest, "")

proc isLocalStoreRecordName*(name: string): bool =
  ## Which names in a content directory are certificates (Transport.md §2.4):
  ## ending in ``.toml`` and NOT beginning with ``.`` — the second rule is
  ## what keeps a writer's in-flight temporary file (§2.3) out of every
  ## reader, whatever it is named.
  name.endsWith(".toml") and not name.startsWith(".")

proc lookupLocalStore*(access: CertificateStoreAccess;
                       roots: CertificateStoreRoots;
                       contentId: string): LocalStoreLookup =
  ## Look one content id up in both roots (Transport.md §2.4).
  ##
  ## * A missing root, a missing directory or an empty one is **none found**,
  ##   never an error (§5).
  ## * A root that is UNRESOLVED (§2.1), or that exists and cannot be read —
  ##   or whose content directory, or a record in it, cannot be read — makes
  ##   the lookup ``incomplete``, with the reason, and the OTHER root is still
  ##   searched. The two roots are symmetric here: §2.1 resolves them
  ##   independently, and a certificate the other root holds still counts.
  ## * A host with no local store at all is ``unreadable``: it looked nowhere.
  ## * A record whose own ``content`` is not ``contentId`` is ``rejected``,
  ##   with the reason, and is not a candidate: the directory is a hint for
  ##   discovery, not evidence. A record that does not parse IS a candidate —
  ##   deciding that it is malformed is the verifier's finding, not this
  ##   reader's.
  ## * A copy byte-identical to one already found (the same file in both
  ##   roots) is evaluated once; every other copy is kept, so neither an
  ##   unsigned copy nor one whose signature fails hides one that would count.
  let dir = localStoreContentDir(contentId)
  if not dir.ok:
    result.problems.add "the content id `" & contentId &
      "` was not looked up in the local certificate store: " & dir.problem
    return
  if not roots.available:
    result.unreadable = true
    result.unreadableReason = "this host has no local certificate store" &
      (if roots.problems.len > 0: ": " & roots.problems.join("; ") else: "")
    return

  proc couldNotSearch(lookup: var LocalStoreLookup; message: string) =
    lookup.incomplete = true
    if message notin lookup.incompleteReasons:
      lookup.incompleteReasons.add message

  for (label, root) in [("user", roots.user), ("system", roots.system)]:
    if root.len == 0:
      # §2.1: an unresolved root is reported as not covered, never as
      # "searched and empty", and never guessed. The resolver's own reasons
      # say which variable to set.
      var reasons: seq[string] = @[]
      for problem in roots.problems:
        if label & " root" in problem:
          reasons.add problem
      result.couldNotSearch("the local certificate store's " & label &
        " root could not be resolved, so it was not searched" &
        (if reasons.len > 0: ": " & reasons.join("; ") else: ""))
      continue
    let full = join(root, dir.relative)
    result.searched.add full
    # The root itself first: a root that exists and cannot be read hides
    # every directory below it, and `listFiles` on a child of an unsearchable
    # directory cannot tell "absent" from "forbidden".
    let rootListing = access.listFiles(root)
    case rootListing.status
    of srAbsent:
      continue
    of srUnreadable:
      result.couldNotSearch("the local certificate store's " & label &
        " root '" & root & "' exists and could not be read: " &
        rootListing.detail)
      continue
    of srOk:
      discard

    let listing = access.listFiles(full)
    case listing.status
    of srAbsent:
      continue
    of srUnreadable:
      result.couldNotSearch("the local certificate store directory '" & full &
        "' could not be listed: " & listing.detail)
      continue
    of srOk:
      discard

    var names = listing.names
    names.sort(compareBytes)
    for name in names:
      if not isLocalStoreRecordName(name):
        continue
      let path = join(full, name)
      let read = access.readText(path)
      case read.status
      of srAbsent:
        # Listed and then gone: pruned, or replaced by a concurrent writer's
        # rename. The store is a cache (§2.5); a vanished file is not a fault.
        continue
      of srUnreadable:
        result.couldNotSearch("the certificate at '" & path &
          "' could not be read: " & read.detail)
        continue
      of srOk:
        discard
      let parsed = readCertificate(read.text)
      if parsed.status == crsOk and parsed.cert.vcs.content != contentId:
        result.rejected.add "the certificate at '" & path & "' names content `" &
          parsed.cert.vcs.content & "` but was found in the directory for `" &
          contentId & "`, so it is ignored (Transport.md §2.4)"
        continue
      var duplicate = false
      for earlier in result.found:
        if earlier.text == read.text:
          duplicate = true
          break
      if duplicate:
        continue
      result.found.add StoredCertificate(
        name: path, text: read.text, receivedAtMs: access.modifiedMs(path))

proc readCertificateStore*(access: CertificateStoreAccess;
                           local: LocalStoreQuery): CertificateStore =
  ## Discover every candidate record for ``local.contentIds`` in both roots of
  ## the local certificate store.
  ##
  ## Never raises, never writes, and never reports absence as a failure. The
  ## outcomes it distinguishes — nothing here, records, a search that could
  ## not cover a root, a host with no store at all — are exactly Transport.md
  ## §5's requirement that "no certificates found" be reported only when the
  ## search actually covered the store.
  result.searched = @[]
  result.problems.add local.roots.problems

  var seenIds: seq[string] = @[]
  for contentId in local.contentIds:
    if contentId in seenIds:
      continue
    seenIds.add contentId
    let lookup = lookupLocalStore(access, local.roots, contentId)
    for dir in lookup.searched:
      if dir notin result.searched:
        result.searched.add dir
    result.rejected.add lookup.rejected
    for problem in lookup.problems:
      if problem notin result.problems:
        result.problems.add problem
    if lookup.unreadable:
      result.present = true
      if not result.unreadable:
        result.unreadable = true
        result.unreadableReason = lookup.unreadableReason
    if lookup.incomplete:
      result.present = true
      result.incomplete = true
      for reason in lookup.incompleteReasons:
        if reason notin result.incompleteReasons:
          result.incompleteReasons.add reason
    if lookup.found.len > 0 or lookup.rejected.len > 0:
      result.present = true
    result.certificates.add lookup.found

  orderByArrival(result.certificates)

proc incompleteSummary*(store: CertificateStore): string =
  ## One sentence saying the search did not cover the whole store, and why —
  ## for the reports that must not read "no certificates" when it did not.
  "The certificate search was incomplete: " &
    store.incompleteReasons.join("; ") & "."

# ---------------------------------------------------------------------------
# The native host's access
# ---------------------------------------------------------------------------

when not defined(js):
  import std/[os, times]

  proc nativeStoreAccess*(): CertificateStoreAccess =
    ## Reach the real filesystem. Guarded by ``when not defined(js)`` because
    ## ``std/os``'s directory walk does not exist on the JS backend — the
    ## renderer supplies its own access built on the platform facade, and the
    ## *rules* above are shared by both rather than written twice.
    CertificateStoreAccess(
      listFiles: proc(dir: string): StoreListing {.closure.} =
        if not dirExists(dir):
          return StoreListing(status: srAbsent)
        try:
          var names: seq[string] = @[]
          # `checkDir = true`: without it `walkDir` yields NOTHING for a
          # directory it cannot open, so an unreadable root read as an empty
          # one — "none found" where the answer is "could not look"
          # (Transport.md §2.4). Found by CTC-3f's real-filesystem cases.
          for kind, path in walkDir(dir, checkDir = true):
            # `pcLinkToFile` counts: a store may legitimately symlink a
            # certificate produced elsewhere, and refusing to follow one would
            # report "no certificates" for a store that has some.
            if kind in {pcFile, pcLinkToFile}:
              names.add path.extractFilename
          StoreListing(status: srOk, names: names)
        except OSError as err:
          StoreListing(status: srUnreadable, detail: err.msg)
      ,
      readText: proc(path: string): StoreRead {.closure.} =
        if not fileExists(path):
          return StoreRead(status: srAbsent)
        try:
          StoreRead(status: srOk, text: readFile(path))
        except IOError as err:
          StoreRead(status: srUnreadable, detail: err.msg)
        except OSError as err:
          StoreRead(status: srUnreadable, detail: err.msg)
      ,
      modifiedMs: proc(path: string): int64 {.closure.} =
        try:
          int64(getLastModificationTime(path).toUnixFloat() * 1000.0)
        except OSError:
          0'i64
      )
