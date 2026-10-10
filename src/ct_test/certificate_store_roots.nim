## Where a user's local certificate store is: its two roots.
##
## Implements ``test-certificates-spec/Transport.md`` §2.1 ("Location"). A
## store has a USER root, owned and written by the user, and a SYSTEM root,
## the user's partition of a machine-wide directory that privileged producers
## write. Both hold the same layout (§2.2); a reader consults both.
##
## The rules, in order, for each root:
##
## * user root — ``$TEST_CERTIFICATES_DIR`` when it is a non-empty absolute
##   path; otherwise the platform's per-user state directory
##   (``$XDG_STATE_HOME/test-certificates`` when ``XDG_STATE_HOME`` is
##   absolute, else ``$HOME/.local/state/test-certificates`` on Linux and other
##   Unix-likes; ``$HOME/Library/Application Support/test-certificates`` on
##   macOS; ``%LOCALAPPDATA%\test-certificates`` on Windows);
## * system root — ``$TEST_CERTIFICATES_SYSTEM_DIR/<user>`` when the variable
##   is a non-empty absolute path; otherwise
##   ``/var/lib/test-certificates/<uid>``,
##   ``/Library/Application Support/test-certificates/<uid>`` or
##   ``%ProgramData%\test-certificates\<SID>``. ``<user>`` is the numeric uid
##   on POSIX systems and the account SID on Windows.
##
## A RELATIVE value of any of the three variables is ignored, as the XDG Base
## Directory specification requires for ``XDG_STATE_HOME``
## (https://specifications.freedesktop.org/basedir-spec/latest/): a store whose
## location depended on the current directory would be a different store for
## each process.
##
## This module is pure. It reads no environment and no filesystem itself; the
## host hands it a lookup and the facts only the host knows (which platform
## family it runs on, the account's uid or SID), so the native process, the
## Electron renderer and the container endpoint resolve the roots with the same
## code. It compiles on the C and JS backends.

type
  StoreRootPlatform* = enum
    ## The platform families §2.1's tables distinguish.
    srpUnix
      ## Linux and every other Unix-like that is not macOS.
    srpMacos
    srpWindows

  StoreEnvironment* = proc(name: string): string {.closure.}
    ## The value of an environment variable, or ``""`` when it is unset. An
    ## empty value and an unset one are the same thing to §2.1.

  CertificateStoreRoots* = object
    ## The two roots, as one host resolved them.
    available*: bool
      ## ``false`` when the host has no local store at all (a browser tab:
      ## there is no per-user directory to have one in). Both roots are then
      ## empty and ``problems`` says why.
    user*: string
      ## The user root, or ``""`` when it cannot be resolved here.
    system*: string
      ## This user's system root, or ``""`` when it cannot be resolved here.
    problems*: seq[string]
      ## Every reason a root is empty, and every variable that was set but
      ## ignored, in words an operator can act on. Empty when both roots
      ## resolved from the first rule that applied.

const
  StoreDirName* = "test-certificates"
    ## The directory name every default location ends in.

proc separator(platform: StoreRootPlatform): char =
  if platform == srpWindows: '\\' else: '/'

proc isAbsoluteOn*(platform: StoreRootPlatform; path: string): bool =
  ## Whether ``path`` is absolute in the platform's own terms. On Windows that
  ## is a drive letter followed by a separator, or a UNC path; ``C:foo`` is
  ## relative to the drive's current directory and does not count.
  case platform
  of srpUnix, srpMacos:
    path.len > 0 and path[0] == '/'
  of srpWindows:
    if path.len >= 3 and path[1] == ':' and path[2] in {'\\', '/'} and
       path[0] in {'a'..'z', 'A'..'Z'}:
      true
    else:
      path.len >= 2 and path[0] in {'\\', '/'} and path[1] in {'\\', '/'}

proc joinOn(platform: StoreRootPlatform; parts: varargs[string]): string =
  ## Join with the platform's separator, never doubling one that a variable's
  ## value already ends with.
  let sep = separator(platform)
  for part in parts:
    if result.len == 0:
      result = part
    elif result[^1] in {'/', '\\'}:
      result.add part
    else:
      result.add sep
      result.add part

proc absoluteVariable(platform: StoreRootPlatform; env: StoreEnvironment;
                      name: string; problems: var seq[string]): string =
  ## The value of ``name`` when §2.1 lets it apply, else ``""``. A set but
  ## relative value is recorded as ignored rather than silently dropped, so a
  ## user who set it can see why it had no effect.
  let value = env(name)
  if value.len == 0:
    return ""
  if not isAbsoluteOn(platform, value):
    problems.add "$" & name & " is set to the relative path '" & value &
      "', which is ignored (Transport §2.1: a relative value would make the " &
      "store depend on the current directory)"
    return ""
  value

proc resolveCertificateStoreRoots*(platform: StoreRootPlatform;
                                   env: StoreEnvironment;
                                   account: string): CertificateStoreRoots =
  ## Resolve both roots per Transport §2.1.
  ##
  ## ``account`` is the numeric uid on POSIX systems and the account SID on
  ## Windows, as the host knows it; ``""`` when the host cannot say, in which
  ## case the system root is left unresolved (and the reason recorded) rather
  ## than guessed — a wrong partition would be another user's certificates.
  result.available = true

  # -- the user root ------------------------------------------------------
  let explicitUser = absoluteVariable(platform, env, "TEST_CERTIFICATES_DIR",
                                      result.problems)
  if explicitUser.len > 0:
    result.user = explicitUser
  else:
    case platform
    of srpUnix:
      let stateHome = absoluteVariable(platform, env, "XDG_STATE_HOME",
                                       result.problems)
      if stateHome.len > 0:
        result.user = joinOn(platform, stateHome, StoreDirName)
      else:
        let home = absoluteVariable(platform, env, "HOME", result.problems)
        if home.len > 0:
          result.user = joinOn(platform, home, ".local", "state", StoreDirName)
        else:
          result.problems.add "the user root cannot be resolved: neither " &
            "$TEST_CERTIFICATES_DIR, $XDG_STATE_HOME nor $HOME is an " &
            "absolute path"
    of srpMacos:
      let home = absoluteVariable(platform, env, "HOME", result.problems)
      if home.len > 0:
        result.user = joinOn(platform, home, "Library", "Application Support",
                             StoreDirName)
      else:
        result.problems.add "the user root cannot be resolved: neither " &
          "$TEST_CERTIFICATES_DIR nor $HOME is an absolute path"
    of srpWindows:
      let localAppData = absoluteVariable(platform, env, "LOCALAPPDATA",
                                          result.problems)
      if localAppData.len > 0:
        result.user = joinOn(platform, localAppData, StoreDirName)
      else:
        result.problems.add "the user root cannot be resolved: neither " &
          "%TEST_CERTIFICATES_DIR% nor %LOCALAPPDATA% is an absolute path"

  # -- the system root ----------------------------------------------------
  let explicitSystem = absoluteVariable(platform, env,
                                        "TEST_CERTIFICATES_SYSTEM_DIR",
                                        result.problems)
  if account.len == 0:
    result.problems.add "the system root cannot be resolved: this host " &
      "does not know the account's " &
      (if platform == srpWindows: "SID" else: "uid")
    return
  if explicitSystem.len > 0:
    result.system = joinOn(platform, explicitSystem, account)
  else:
    case platform
    of srpUnix:
      result.system = joinOn(platform, "/var/lib", StoreDirName, account)
    of srpMacos:
      result.system = joinOn(platform, "/Library/Application Support",
                             StoreDirName, account)
    of srpWindows:
      let programData = absoluteVariable(platform, env, "ProgramData",
                                         result.problems)
      if programData.len > 0:
        result.system = joinOn(platform, programData, StoreDirName, account)
      else:
        result.problems.add "the system root cannot be resolved: " &
          "%ProgramData% is not an absolute path"

proc noLocalStore*(reason: string): CertificateStoreRoots =
  ## The answer of a host that has no local store at all.
  CertificateStoreRoots(available: false, problems: @[reason])

proc storeRootPlatformFor*(osName: string): StoreRootPlatform =
  ## Map a host's own name for its operating system (Nim's ``hostOS`` or
  ## node's ``process.platform``) onto §2.1's families. Everything that is
  ## neither macOS nor Windows is a Unix-like, which is §2.1's own grouping.
  case osName
  of "macosx", "darwin", "macos": srpMacos
  of "windows", "win32": srpWindows
  else: srpUnix
