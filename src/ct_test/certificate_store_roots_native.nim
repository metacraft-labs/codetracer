## The native host's answer to "where is the local certificate store":
## Transport.md §2.1 resolved for this process's environment, its
## compile-time platform family and its account.
##
## Kept apart from ``certificate_store_roots`` so that resolver stays pure (it
## compiles for the JS backend, where the Electron renderer and the container
## endpoint drive it with node's environment instead).
##
## The native process resolves through the reference library
## (test-certificates-tools, ``test_certificates/roots``) — the same pure
## function of (platform, environment, account) every conforming helper uses —
## and takes the ACCOUNT from it too: the uid on POSIX, and on Windows the SID
## of this process token's user (``GetTokenInformation`` /
## ``ConvertSidToStringSidW``), which is what makes
## ``%ProgramData%\test-certificates\<SID>`` resolvable on a native Windows
## host. ``certificate_store_roots_test.nim`` holds the JS-shared resolver to
## the library's answers over the §2.1 table, so the two cannot drift.

import std/os

from test_certificates/roots as tcroots import nil

import certificate_store_roots

export certificate_store_roots

proc libraryPlatform(platform: StoreRootPlatform): tcroots.RootPlatform =
  case platform
  of srpUnix: tcroots.rpUnix
  of srpMacos: tcroots.rpMacos
  of srpWindows: tcroots.rpWindows

proc libraryResolvedRoots*(platform: StoreRootPlatform;
                           env: StoreEnvironment;
                           account: string): CertificateStoreRoots =
  ## Both roots per §2.1, as the reference library resolves them, in this
  ## module's result type. Exposed so the suite can compare it with the pure
  ## resolver on inputs no host would give this process.
  let resolved = tcroots.resolveRoots(libraryPlatform(platform),
    proc(name: string): string = env(name), account)
  CertificateStoreRoots(available: true, user: resolved.user,
                        system: resolved.system, problems: resolved.problems)

proc nativeStoreAccount*(): string =
  ## The account §2.1 partitions the system root by: the numeric uid on POSIX
  ## systems, the account SID on Windows. ``""`` when it cannot be read, which
  ## leaves the system root unresolved (saying why) instead of guessed.
  let account = tcroots.currentAccount()
  if account.ok: account.account else: ""

proc nativeCertificateStoreRoots*(): CertificateStoreRoots =
  ## Both roots, as this process resolves them now. Reads the environment on
  ## every call, so a change to ``TEST_CERTIFICATES_DIR`` is seen by the next
  ## call rather than frozen at start-up.
  let account = tcroots.currentAccount()
  result = libraryResolvedRoots(storeRootPlatformFor(hostOS),
    proc(name: string): string = getEnv(name), account.account)
  if not account.ok:
    result.problems.add account.problem
