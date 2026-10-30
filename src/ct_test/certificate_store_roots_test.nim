## The two resolvers of the local certificate store's roots agree.
##
## The native process resolves Transport.md §2.1 through the reference
## library (test-certificates-tools ``test_certificates/roots``, via
## ``certificate_store_roots_native``); the Electron renderer and the container
## endpoint use ``certificate_store_roots``' pure resolver, which has to
## compile for the JS backend and so cannot link the library. Two answers to
## "where is the store" would be two stores, so this suite holds the pure
## resolver to the library's answer for every row of §2.1 and for the inputs
## that are easy to get wrong (relative values, drive-relative Windows paths,
## a trailing separator, an invalid account id).
##
## NO MOCKS: both resolvers are pure functions of (platform, environment,
## account); the environment is a table.

import std/[os, strutils, tables, unittest]

when not defined(windows):
  import std/posix

import certificate_store_roots_native

proc envOf(pairs: openArray[(string, string)]): StoreEnvironment =
  let table = pairs.toTable
  result = proc(name: string): string = table.getOrDefault(name, "")

suite "the local certificate store's roots (Transport.md §2.1)":

  test "the JS-shared resolver agrees with the reference library on every row":
    let cases: seq[(StoreRootPlatform, seq[(string, string)], string)] = @[
      (srpUnix, @[("HOME", "/home/u")], "1000"),
      (srpUnix, @[("HOME", "/home/u"), ("XDG_STATE_HOME", "/xdg")], "1000"),
      (srpUnix, @[("HOME", "/home/u"), ("XDG_STATE_HOME", "relative")], "1000"),
      (srpUnix, @[("TEST_CERTIFICATES_DIR", "/explicit/"),
                  ("TEST_CERTIFICATES_SYSTEM_DIR", "/sys")], "1000"),
      (srpUnix, @[("TEST_CERTIFICATES_DIR", "relative"), ("HOME", "rel")], "0"),
      (srpUnix, @[("HOME", "/home/u")], ""),
      (srpUnix, @[("HOME", "/home/u")], "../1000"),
      (srpUnix, @[("HOME", "/home/u")], "S-1-5-21-1"),
      (srpMacos, @[("HOME", "/Users/u")], "501"),
      (srpMacos, @[("TEST_CERTIFICATES_SYSTEM_DIR", "relative")], "501"),
      (srpWindows, @[("LOCALAPPDATA", "C:\\Users\\u\\AppData\\Local"),
                     ("ProgramData", "C:\\ProgramData")],
                   "S-1-5-21-1004336348-1177238915-682003330-512"),
      (srpWindows, @[("LOCALAPPDATA", "C:state"),
                     ("ProgramData", "\\\\server\\share")], "S-1-5-18"),
      (srpWindows, @[("LOCALAPPDATA", "C:/Users/u/"),
                     ("ProgramData", "C:\\ProgramData")], "1000"),
      (srpWindows, @[("ProgramData", "C:\\ProgramData")], "S-1-"),
      (srpWindows, @[("ProgramData", "C:\\ProgramData")], ""),
    ]
    for (platform, pairs, account) in cases:
      let env = envOf(pairs)
      let pure = resolveCertificateStoreRoots(platform, env, account)
      let library = libraryResolvedRoots(platform, env, account)
      checkpoint $platform & " " & $pairs & " account=" & account
      check pure.user == library.user
      check pure.system == library.system
      # A root left unresolved is explained, by both.
      if pure.user.len == 0 or pure.system.len == 0:
        check pure.problems.len > 0
        check library.problems.len > 0

  test "an account id that could name another path leaves the system root unresolved":
    ## A uid that is not decimal, or a SID that is not `S-1-…`, could escape
    ## the system root (`../`), so neither resolver accepts one.
    for (platform, account) in [(srpUnix, "../0"), (srpUnix, "10a"),
                                (srpWindows, "S-1-5-..\\x"),
                                (srpWindows, "1000")]:
      let roots = resolveCertificateStoreRoots(platform,
        envOf([("HOME", "/h"), ("LOCALAPPDATA", "C:\\l"),
               ("ProgramData", "C:\\p")]), account)
      checkpoint account
      check roots.system == ""
      check roots.problems.len > 0
    # Control: a valid one resolves.
    check resolveCertificateStoreRoots(srpUnix, envOf([("HOME", "/h")]),
                                       "1000").system ==
      "/var/lib/test-certificates/1000"

  test "the native process knows its account":
    ## On POSIX the uid; on Windows the token user's SID through the
    ## library's GetTokenInformation binding — which is what makes the
    ## Windows system root resolvable on a native host (SB-2a).
    let account = nativeStoreAccount()
    check account.len > 0
    when defined(windows):
      check account.len > 4 and account[0 .. 3] == "S-1-"
    else:
      check account == $getuid()
    let roots = nativeCertificateStoreRoots()
    check roots.available
    check roots.system.len > 0
    check roots.system.endsWith(account)
