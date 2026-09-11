## launch/grant_store.nim — PLAT-10. Where the per-plugin capability grant
## lives on disk, and the two operations that move it.
##
## ## IT LIVES UNDER THE LAUNCHER'S OWN USER ROOT
##
## `codetracer-launcher` resolves its user root as `$CODETRACER_USER_ROOT`, or
## `$HOME/.codetracer` when that is unset (`install.nim`'s `resolveUserRoot` /
## `envOrHome`). Everything it owns hangs off that one directory:
##
##     <user root>/components/v1/<name>@<version>/   installs
##     <user root>/active/<name>                     the active symlink
##     <user root>/registry/v1/registry.txt          the registry
##     <user root>/grants/v1/grants.tsv              THIS FILE
##
## The last row is the only one this repository writes, and it is beside the
## others on purpose: a user who moves `CODETRACER_USER_ROOT` to a second
## profile gets that profile's installs AND that profile's grants, which is
## what "the same machine, a different user" has to mean. Reaching for
## `$XDG_STATE_HOME` instead would have split the two so that uninstalling a
## plugin in one root left its grant in another.
##
## **It is state, not a package index.** Nothing here enumerates, downloads,
## versions or removes a component; `ct install` and `ct uninstall` do that and
## this file never learns that they ran except through
## `plugin_components.discoverPlugins` reading the directories afterwards.
##
## ## THE WRITE IS ATOMIC AGAINST A CRASH *AND* AGAINST A SECOND WRITER
##
## Those are two different claims and the first one used to be the only one
## made. It is worth stating what each buys, because the failure this file has
## to avoid runs in one direction only.
##
## **Against a crash.** A grant file half-written by a crash would be read back
## as "these capabilities were never granted", which is fail-closed and
## therefore survivable — but it would also make the next acceptance step
## re-grant everything the truncated tail had recorded, including something the
## user had revoked. So the write goes to a sibling staging file and is
## `moveFile`d into place; `rename(2)` within a directory is atomic, so a reader
## sees the old file or the new one and never a prefix of either.
##
## **Against a second writer.** `moveFile` being atomic says nothing about WHO
## wrote the file being renamed. The staging path was `path & ".tmp"` — a FIXED
## name — so two processes saving at once interleave as
## `writeFile(tmp)` / `writeFile(tmp)` / `moveFile(tmp, path)` /
## `moveFile(tmp, path)` and one of them renames the OTHER's partially written
## file into place. `parseLedger` is total by design, so a truncation at a line
## boundary loads silently as FEWER GRANTS — and a lost `revoke` line restores a
## capability the user took back at the next start-up. Fail-closed is the safe
## direction for a missing grant and the WRONG direction for a missing
## revocation, and this record has both kinds of line in it.
##
## Two changes, because they close different halves and neither is sufficient:
##
##   1. **the staging path carries the writer's pid**, so two writers never
##      share a staging inode and the torn-file case cannot be constructed at
##      all — this holds on every platform, with or without a lock;
##   2. **an exclusive advisory lock spans the whole read-modify-write**, so
##      "load, add an entry, save" is serialised rather than merely each half of
##      it being atomic. Two concurrent `revoke`s that each read the same
##      starting ledger would otherwise both save, and the loser's entry would
##      be absent from a file that was never torn.
##
## `updateGrantLedger` is the primitive that owns (2) — a caller that does its
## own `loadGrantLedger` / edit / `saveGrantLedger` gets (1) and the per-call
## lock, but the two halves of its read-modify-write are two lock acquisitions
## and another writer may land between them.
##
## **The lock is POSIX-only, and it is named rather than papered over.** It is
## `flock(2)` on a lock file beside the ledger, under `when defined(posix)`; on
## any other platform `withGrantLedgerLock` runs the body unlocked and the
## guarantee is (1) alone. Nothing in this repository compiles this module for
## Windows today — it is reached only from `plugin_components_test.nim` and from
## the view-model's grant-lifecycle suite — so the gap is recorded here rather
## than closed with a `LockFileEx` arm no test in this tree can run.
##
## And the read is total: it reports unusable lines rather than raising.

import std/[os, strutils]

when defined(posix):
  import std/posix

  # `flock(2)` is not in `std/posix` — that module carries `struct flock`, which
  # is `fcntl`'s record-locking type and a different mechanism with the
  # descriptor-close misfeature described on `withGrantLedgerLock`. Two
  # declarations rather than one `flock(fd, op)` with magic numbers, because
  # `LOCK_EX` and `LOCK_UN` are imported from the header rather than written as
  # 2 and 8: the values agree on Linux and the BSDs today and that is a fact
  # about those headers, not a guarantee this file should re-state.
  proc rawFlock(fd: cint; operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}
  var LOCK_EX {.importc, header: "<sys/file.h>".}: cint
  var LOCK_UN {.importc, header: "<sys/file.h>".}: cint

  proc flockEx(fd: cint): cint = rawFlock(fd, LOCK_EX)
  proc flockUn(fd: cint): cint = rawFlock(fd, LOCK_UN)

import ../../common/plugin_model/grant_ledger
import ../../common/plugin_model/diagnostics

export grant_ledger

const
  userRootEnvVar* = "CODETRACER_USER_ROOT"
    ## The launcher's own spelling. Named here rather than written twice.

  grantStoreSubdir* = "grants"
  grantStoreVersion* = "v1"
  grantStoreFileName* = "grants.tsv"

proc launcherUserRoot*(): string =
  ## `$CODETRACER_USER_ROOT`, else `$HOME/.codetracer`, else "". The empty
  ## answer is the one a caller must handle: `envOrHome` returns false when
  ## `HOME` is unset and the launcher then refuses the command, so a store
  ## with nowhere to live says so rather than inventing a path.
  let override = getEnv(userRootEnvVar, "")
  if override.len > 0: return override.strip(leading = false, chars = {'/'})
  let home = getEnv("HOME", "")
  if home.len == 0: return ""
  home.strip(leading = false, chars = {'/'}) / ".codetracer"

proc grantLedgerPath*(root = ""): string =
  ## The ledger's absolute path, or "" when there is no user root.
  let r = if root.len > 0: root else: launcherUserRoot()
  if r.len == 0: return ""
  r / grantStoreSubdir / grantStoreVersion / grantStoreFileName

# ---------------------------------------------------------------------------
# Serialising the writers
# ---------------------------------------------------------------------------

proc grantLedgerStagingPath*(path: string): string =
  ## The file a save writes before it renames.
  ##
  ## THE PID IS THE WHOLE POINT. With a fixed `path & ".tmp"`, two writers share
  ## one staging inode and each can rename the other's half-written bytes over
  ## the real ledger — see the header. Per-writer names make that unconstructible
  ## rather than unlikely, and they do it without depending on the advisory lock
  ## below, which is what makes this the half that holds on every platform.
  if path.len == 0: "" else: path & ".tmp." & $getCurrentProcessId()

proc grantLedgerLockPath*(path: string): string =
  ## The lock's own file, beside the ledger.
  ##
  ## IT IS A SEPARATE INODE FROM THE LEDGER, deliberately. The ledger is
  ## REPLACED by `moveFile`, and an advisory lock is held on the inode rather
  ## than on the name — so a lock taken on the ledger itself would be a lock on
  ## a file the next successful save unlinks, and the writer after that would
  ## lock a fresh inode and serialise against nobody. That is the same mistake
  ## as deleting a lock file to "clean up" (Verification-Harness-Traps §14d).
  ##
  ## It is therefore NOT a temporary: it outlives the write on purpose, and the
  ## suite that asserts no staging file is left behind asserts this one IS.
  if path.len == 0: "" else: path & ".lock"

template withGrantLedgerLock*(path: string; body: untyped) =
  ## Run `body` holding an exclusive advisory lock for this ledger.
  ##
  ## `flock(2)` rather than `fcntl(F_SETLKW)`, and the difference matters here:
  ## an `fcntl` record lock is dropped when the process closes ANY descriptor on
  ## the file, so an unrelated `loadGrantLedgerFrom` in the same process would
  ## silently release a lock a save was holding. `flock` is held on the open
  ## file description, so only the descriptor that took it can drop it.
  ##
  ## It is ADVISORY: it serialises writers that take it and does nothing about a
  ## process that writes the file without asking. Every writer in this
  ## repository goes through `saveGrantLedgerTo`, which takes it.
  ##
  ## `body` runs exactly once whether or not the lock could be taken. A save
  ## that refused because it could not open a lock file would fail CLOSED on a
  ## read-only or full filesystem — turning a contention guard into an outage —
  ## and the pid-unique staging path already makes the un-serialised case
  ## lossy-but-not-corrupting rather than corrupting.
  block:
    let lockPath = grantLedgerLockPath(path)
    when defined(posix):
      var lockFd = cint(-1)
      if lockPath.len > 0:
        try:
          createDir(lockPath.parentDir)
          lockFd = posix.open(lockPath.cstring,
                              posix.O_RDWR or posix.O_CREAT, 0o600.Mode)
        except CatchableError:
          lockFd = cint(-1)
        if lockFd >= 0:
          discard flockEx(lockFd)
      try:
        body
      finally:
        if lockFd >= 0:
          discard flockUn(lockFd)
          discard posix.close(lockFd)
    else:
      # No advisory lock on this platform; the pid-unique staging path above is
      # the guarantee that still holds. Named in the header rather than implied.
      discard lockPath
      body

proc loadGrantLedgerFrom*(path: string): LedgerParse =
  ## An absent file is an EMPTY ledger with no problems — a machine where
  ## nobody has granted anything yet is the ordinary first run, not a fault.
  ## An unreadable file IS a problem, because "no grants" and "I could not
  ## read the grants" have to be distinguishable: the first is a fresh
  ## install and the second is a permissions mistake that would otherwise
  ## present as every plugin losing its capabilities at once.
  if path.len == 0:
    result.problems.add "no user root: neither " & userRootEnvVar &
      " nor HOME is set, so there is nowhere to read a capability grant from"
    return
  if not fileExists(path):
    return
  var text: string
  try:
    text = readFile(path)
  except CatchableError as e:
    result.problems.add "could not read the grant ledger at '" & path &
      "': " & e.msg
    return
  result = parseLedger(text)
  for i in 0 ..< result.problems.len:
    result.problems[i] = path & ": " & result.problems[i]

proc loadGrantLedger*(root = ""): LedgerParse =
  loadGrantLedgerFrom(grantLedgerPath(root))

proc writeLedgerLocked(ledger: GrantLedger; path: string): string =
  ## The write itself. **THE CALLER HOLDS THE LOCK** — this proc does not take
  ## it, and that is not an oversight to be tidied away.
  ##
  ## `flock` on a second descriptor of the same file, from the same process,
  ## BLOCKS: the lock belongs to the open file description, so a `saveGrantLedger`
  ## that took its own lock while `updateGrantLedger` held one would deadlock
  ## against itself. One lock-taking layer, one locked-body layer, and the two
  ## public entry points each take it exactly once.
  try:
    createDir(path.parentDir)
    let staging = grantLedgerStagingPath(path)
    writeFile(staging, ledger.render())
    moveFile(staging, path)
  except CatchableError as e:
    return "could not write the grant ledger at '" & path & "': " & e.msg
  ""

proc saveGrantLedgerTo*(ledger: GrantLedger; path: string): string =
  ## Returns "" on success, or the problem. Not an exception, because the one
  ## caller is a user action ("revoke this") whose failure has to be reported
  ## to that user rather than unwound through a UI.
  ##
  ## This serialises the WRITE. It cannot serialise a read-modify-write it did
  ## not see the read of — for that, see `updateGrantLedger`.
  if path.len == 0:
    return "no user root: neither " & userRootEnvVar & " nor HOME is set, " &
      "so there is nowhere to record a capability grant"
  withGrantLedgerLock(path):
    result = writeLedgerLocked(ledger, path)

proc saveGrantLedger*(ledger: GrantLedger; root = ""): string =
  saveGrantLedgerTo(ledger, grantLedgerPath(root))

proc updateGrantLedgerAt*(path: string;
                          edit: proc(l: var GrantLedger)): string =
  ## THE READ-MODIFY-WRITE, UNDER ONE LOCK. Load the ledger, hand it to `edit`,
  ## save it — with no window in which another writer can land between the load
  ## and the save.
  ##
  ## This is the operation a revocation actually is, and it is the one an
  ## atomic write does not make safe on its own: two processes that each load
  ## the same starting ledger, each append their own entry and each save will
  ## both succeed, and the file will carry whichever entry was written last. No
  ## file is ever torn; one decision is simply gone. If the lost one is a
  ## `revoke`, the capability is back at the next start-up — the one direction
  ## this record must never fail in.
  ##
  ## `edit` receives the ledger AS IT IS ON DISK RIGHT NOW, not as the caller
  ## last saw it, which is also why this takes a callback rather than a value.
  ##
  ## Returns "" on success, or the problem. A ledger whose file carried unusable
  ## lines is still edited and still saved: `parseLedger` keeps what parsed, and
  ## refusing to record a revocation because an unrelated line was malformed
  ## would be the store failing open.
  if path.len == 0:
    return "no user root: neither " & userRootEnvVar & " nor HOME is set, " &
      "so there is nowhere to record a capability grant"
  withGrantLedgerLock(path):
    var current = loadGrantLedgerFrom(path).ledger
    edit(current)
    result = writeLedgerLocked(current, path)

proc updateGrantLedger*(root = ""; edit: proc(l: var GrantLedger)): string =
  updateGrantLedgerAt(grantLedgerPath(root), edit)

proc ledgerProblemErrors*(parse: LedgerParse): seq[PluginError] =
  ## The store's problems, rendered as the one error type the rest of the
  ## plugin substrate uses, so a front-end has one column to print.
  ##
  ## THE PLUGIN FIELD IS THE STORE ITSELF and not an empty string, because
  ## `diagnostics.namesPlugin` is swept over every error the suites build and
  ## an anonymous error would fail that sweep — correctly. A ledger problem is
  ## not attributable to one plugin, so it names the subject it IS about.
  for p in parse.problems:
    result.add pluginError("<capability grant ledger>", pecMalformedManifest, p)
