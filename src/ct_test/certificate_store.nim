## The workspace certificate store — **discovery only, and strictly read-only.**
##
## Implements ``test-certificates-spec/Transport.md`` §3 (a file carrier) and
## §4 (discovery) for the directory carrier a workspace keeps beside its build
## state. It answers one question — *which certificate records exist here, and
## which one landed last* — and it answers it without deciding anything about
## them. Reading a record, checking a signature and evaluating coverage all
## belong to ``certificate.nim`` and ``certificate_verification.nim``, which
## this module deliberately does not duplicate.
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
## Two directories are searched, because the standard's whole point is that a
## certificate is producer-agnostic and carriers are interchangeable
## (Transport.md §1):
##
## * ``.repro/workspace/certificates`` — reprobuild's location, matching where
##   it already keeps ``registered-keys.toml``
##   (``reprobuild-specs/Test-Certificates.md``);
## * ``.ct/certificates`` — the same layout for a workspace that uses `ct test`
##   and no reprobuild at all, which is the case CTC-2 is about.
##
## A record found in either reads identically; there is no field anywhere below
## recording which directory it came from, precisely so a hook-written
## certificate cannot render differently from an agent-written one.
##
## **The git-notes carrier is not read here.** Transport.md §2 recommends
## ``refs/notes/<vendor>/certificates``, and reprobuild uses it for records that
## travel with a push. Reading it needs a git plumbing call this module has no
## seam for, so it is a stated gap rather than a silent one: a workspace whose
## certificates live *only* in notes reads as "no certificates", which is the
## outcome Transport.md §2 itself predicts for a notes ref that was never
## fetched.
##
## Absence is not an error
## -----------------------
## A workspace with no store at all — no reprobuild, no `ct test`, a project
## that does not use certificates — is an ordinary state and MUST NOT be
## reported as a failure (Transport.md §4). It is ``present = false`` here, and
## the indicator renders "no certificates".
##
## A store that *exists* and cannot be listed or read is a different answer,
## and the two are kept apart for the same reason Verification.md §3.1 keeps an
## empty key store apart from an unreadable one: one says "there is nothing
## here", the other says "I could not look", and only the second means
## something is misconfigured.

import std/[algorithm, strutils]

import certificate

const
  ReprobuildStoreDir* = ".repro/workspace/certificates"
    ## reprobuild's workspace store (``reprobuild-specs/Test-Certificates.md``).

  CtTestStoreDir* = ".ct/certificates"
    ## The same layout for a workspace that uses `ct test` alone.

  CertificateStoreDirs* = [ReprobuildStoreDir, CtTestStoreDir]
    ## Searched in this order. The order decides only which *key store* is
    ## consulted when both directories carry one (see ``readCertificateStore``);
    ## certificates from both are pooled and ordered by when they landed.

  RegisteredKeysFile* = "registered-keys.toml"
    ## The registered-key store's name inside a store directory
    ## (Verification.md §3.1).

  SigningKeyFile* = "signing-key"
    ## reprobuild's current implementation keeps a workspace-local **private
    ## signing key** at this path, inside the same directory as the
    ## certificates (``reprobuild-specs/Test-Certificates.md``). A discovery
    ## pass that slurped every file in the directory would read it, which is
    ## the last thing a read-only display should do.
    ##
    ## Named here so the hazard is visible, but **the ``.toml`` allow-list in
    ## ``isCertificateFile`` is what actually excludes it** — an explicit
    ## `name == SigningKeyFile` branch was there too and was dead code, since a
    ## file with no extension never reaches it. Mutation testing found that:
    ## removing the branch changed nothing, which meant the guard the branch
    ## appeared to be was somewhere else. Removing the allow-list DOES fail
    ## ``certificate_store_test.nim``, which is the guard that exists.

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
    ## serve. Nothing here is called from a second thread — the indicator is
    ## read on the renderer's own turn — so the annotation would buy a promise
    ## nobody needs at the cost of the instantiation that matters.
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
    ## is carried verbatim; nothing here parses it.
    name*: string
      ## Store-relative, e.g. ``.ct/certificates/linux-amd64.toml``. Shown to a
      ## human and used as the deterministic final tiebreak in the ordering.
    text*: string
    receivedAtMs*: int64
      ## When this file last changed on the host that is displaying it.

  CertificateStore* = object
    ## What discovery found. Every field exists because Transport.md §4 asks
    ## discovery to be **explicit about what it searched** and **non-fatal when
    ## empty**.
    searched*: seq[string]
      ## Every directory this pass looked in, whether or not it existed.
    present*: bool
      ## At least one store directory exists. ``false`` is the ordinary
      ## "this project does not use certificates" state.
    unreadable*: bool
      ## A store directory exists and could not be listed, or a file inside it
      ## could not be read. Distinct from ``present = false``, and the
      ## distinction is the whole of Transport.md §4's first bullet.
    unreadableReason*: string
    certificates*: seq[StoredCertificate]
      ## **Newest first** — see ``orderByArrival``.
    keyStorePath*: string
      ## Empty when no store directory carries one.
    keyStore*: KeyStore
      ## Parsed. ``readable = false`` when a store file exists and could not be
      ## read, which is what makes the outcome unverifiable rather than
      ## not-covered (Verification.md §3.1). When ``keyStorePath`` is empty
      ## this is the zero value, whose ``readable`` is ``false``; callers MUST
      ## test ``keyStorePath.len > 0`` before treating it as an answer, which
      ## is what ``hasKeyStore`` below is for.

proc hasKeyStore*(store: CertificateStore): bool =
  ## Whether the workspace declared a trust policy at all.
  ##
  ## The distinction this exists to keep: a workspace with **no** registered-key
  ## store has not said which keys it trusts, and a consumer that answered
  ## "fail-closed, nobody is trusted" would be inventing a deployment decision
  ## nobody made. Verification.md §3.1's fail-closed rule is about a consumer
  ## *that requires signatures*; whether to require them is the deployment's
  ## call, and the absence of a store file is the absence of that call rather
  ## than a negative answer to it.
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
  ## The record the indicator speaks for. Callers MUST check
  ## ``store.certificates.len > 0`` first; this returns the zero value for an
  ## empty store rather than raising, because "the store is empty" is a state
  ## every caller already has to render and not an exceptional condition.
  if store.certificates.len == 0:
    return StoredCertificate()
  store.certificates[0]

proc isCertificateFile(name: string): bool =
  ## Which entries in a store directory are candidate records.
  ##
  ## AN ALLOW-LIST RATHER THAN A DENY-LIST, and that is the whole guard: the
  ## directory also holds a registered-key store and, in reprobuild's current
  ## implementation, a **private signing key** (``SigningKeyFile``). A pass
  ## that read everything and sorted it out afterwards would have read the key
  ## before deciding it did not want it. Anything not ending in ``.toml`` is
  ## never opened.
  if not name.endsWith(".toml"):
    return false
  if name == RegisteredKeysFile:
    return false
  true

proc join(dir, name: string): string =
  ## Store paths are always ``/``-separated, on every host. They are shown to a
  ## human and compared as strings; a backslash on Windows would make the same
  ## store sort differently there.
  if dir.len == 0: name
  elif dir.endsWith("/"): dir & name
  else: dir & "/" & name

proc readCertificateStore*(access: CertificateStoreAccess;
                           workspaceRoot: string): CertificateStore =
  ## Discover every certificate record under ``workspaceRoot``.
  ##
  ## Never raises, never writes, and never reports absence as a failure. The
  ## three outcomes it distinguishes — no store, a store, a store it could not
  ## read — are exactly Transport.md §4's requirement that "no certificates
  ## found" and a discovery that broke down be reported differently.
  result.searched = @[]
  for dir in CertificateStoreDirs:
    let full = join(workspaceRoot, dir)
    result.searched.add dir

    let listing = access.listFiles(full)
    case listing.status
    of srAbsent:
      continue
    of srUnreadable:
      # The directory is there and could not be listed. That is a fault to
      # report, not an emptiness to render.
      result.present = true
      if not result.unreadable:
        result.unreadable = true
        result.unreadableReason =
          "the certificate store at '" & dir & "' could not be listed: " &
          listing.detail
      continue
    of srOk:
      result.present = true

    var names = listing.names
    # Sorted before reading so the *reads* happen in a stable order too; the
    # final ordering is `orderByArrival`, but a deterministic read order keeps
    # the first-unreadable-file report from depending on the filesystem.
    names.sort(compareBytes)

    for name in names:
      if name == RegisteredKeysFile:
        # First store directory that carries one wins, so a workspace using
        # both carriers has exactly one trust policy rather than a union
        # nobody wrote down.
        if result.keyStorePath.len == 0:
          let read = access.readText(join(full, name))
          result.keyStorePath = join(dir, name)
          case read.status
          of srOk:
            result.keyStore = readKeyStore(read.text)
          of srAbsent:
            # Listed and then gone: a race, not an answer.
            result.keyStore = KeyStore(readable: false,
              unreadableReason: "the registered-key store at '" &
                join(dir, name) & "' disappeared between listing and reading")
          of srUnreadable:
            result.keyStore = KeyStore(readable: false,
              unreadableReason: "the registered-key store at '" &
                join(dir, name) & "' could not be read: " & read.detail)
        continue

      if not isCertificateFile(name):
        continue

      let path = join(full, name)
      let read = access.readText(path)
      case read.status
      of srOk:
        result.certificates.add StoredCertificate(
          name: join(dir, name),
          text: read.text,
          receivedAtMs: access.modifiedMs(path))
      of srAbsent:
        continue
      of srUnreadable:
        if not result.unreadable:
          result.unreadable = true
          result.unreadableReason =
            "the certificate at '" & join(dir, name) & "' could not be read: " &
            read.detail

  orderByArrival(result.certificates)

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
          for kind, path in walkDir(dir):
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
