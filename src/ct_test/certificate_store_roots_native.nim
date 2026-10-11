## The native host's answer to "where is the local certificate store":
## ``certificate_store_roots`` driven by this process's environment, its
## compile-time platform family and its account.
##
## Kept apart from the resolver so the resolver stays pure (it compiles for
## the JS backend, where the Electron renderer and the container endpoint
## drive it with node's environment instead).

import std/os

when not defined(windows):
  import std/posix

import certificate_store_roots

export certificate_store_roots

proc nativeStoreAccount*(): string =
  ## The account §2.1 partitions the system root by: the numeric uid on POSIX
  ## systems. On Windows it is the account SID, which this process has no
  ## binding to read yet, so the answer there is ``""`` and the resolver
  ## leaves the system root unresolved (saying why) instead of guessing.
  when defined(windows):
    ""
  else:
    $getuid()

proc nativeCertificateStoreRoots*(): CertificateStoreRoots =
  ## Both roots, as this process resolves them now. Reads the environment on
  ## every call, so a change to ``TEST_CERTIFICATES_DIR`` is seen by the next
  ## call rather than frozen at start-up.
  resolveCertificateStoreRoots(
    storeRootPlatformFor(hostOS),
    proc(name: string): string = getEnv(name),
    nativeStoreAccount())
