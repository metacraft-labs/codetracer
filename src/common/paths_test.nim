import std / [unittest, os]

import paths

# SAMPLED AT MODULE-INIT TIME, and that is the whole point of the variable.
#
# Nim runs module initialisers in dependency order, so `paths`'s initialiser
# has finished by the time this line runs, and no `test` body has started.  The
# number captured here is therefore exactly "how many PATH searches happened
# before `main`" — which is the property PLAT-1 turns on and the thing that
# cannot be observed from inside a `test` block, because by then the earlier
# tests in this file have already resolved several tools themselves.
let toolSearchesBeforeMain = toolSearchCount()

suite "tool paths are resolved lazily (PLAT-1)":
  ## `codetracer-specs/CLI/ct/ui-selection.md` §3.1 gates the cost of reaching
  ## the TUI through `ct replay --ui=tui` at 10 ms over reaching it directly.
  ## What blew that gate was not the selector but `paths.nim`: 39 `findExe`
  ## calls in a module-level `let` block, run before `main` on EVERY `ct`
  ## invocation, costing one failed `newfstatat` per PATH entry per absent
  ## tool — 5,445 of them, 16.3 ms, on a 193-entry PATH.
  ##
  ## These two cases are what keeps that fix from silently rotting back.

  test "no tool is searched for before main":
    # Reverting any `lazyToolPath` to an eager `let` makes this fail, and both
    # ends of that were run rather than reasoned about: forcing ONE value eager
    # (`let _ = bashExe()` at module scope) makes the counter read 1, and
    # forcing all 38 eager makes it read 39 — 39 and not 38 because
    # `mcrRecorderExe` searches for `ct-mcr` and then for `ct_cli`.
    #
    # The assertion is `== 0` rather than `< n` on purpose: one eager value is
    # already the defect, because the whole cost is per-value and the next one
    # arrives by being copied from it.
    check toolSearchesBeforeMain == 0

  test "a tool path is resolved at first use and then memoised":
    # `chromedriverExe` is deliberate on two counts: it takes NO env-var
    # override (so nothing in the ambient environment can pre-empt the PATH
    # search and make this vacuous), and nothing else in this suite or in
    # `paths.nim`'s consumers reads it (so its cache is guaranteed cold here).
    let sandbox = getTempDir() / "ct_paths_lazy_test"
    removeDir(sandbox)
    createDir(sandbox)
    defer: removeDir(sandbox)

    let planted = sandbox / "chromedriver"
    writeFile(planted, "#!/bin/sh\nexit 0\n")
    when not defined(windows):
      setFilePermissions(planted, {fpUserRead, fpUserWrite, fpUserExec})

    let realPath = getEnv("PATH")
    defer: putEnv("PATH", realPath)

    # LAZINESS: the sandbox was not on PATH when this module initialised, so
    # an eagerly-resolved value could not possibly name the file in it.
    putEnv("PATH", sandbox)
    check chromedriverExe() == planted

    # MEMOISATION: with the sandbox gone from PATH *and* from disk, a value
    # that re-searched on every access would now come back empty. A lazy
    # conversion that forgot to cache would trade a startup cost for a worse
    # steady-state one, so this is not a lesser property than the first.
    putEnv("PATH", "")
    removeFile(planted)
    check chromedriverExe() == planted

    # And the search really did happen exactly once, not once per access.
    let before = toolSearchCount()
    discard chromedriverExe()
    discard chromedriverExe()
    check toolSearchCount() == before

suite "findTool":
  test "findTool resolves bash":
    let result = findTool("bash")
    check result.len > 0
    check fileExists(result)

  test "findTool returns empty for nonexistent tool":
    let result = findTool("this_tool_does_not_exist_xyz_12345")
    check result.len == 0

  test "findTool matches findExe exactly":
    # findTool is now a direct wrapper around findExe with no fallback
    check findTool("bash") == findExe("bash")
    check findTool("nonexistent_tool_xyz") == findExe("nonexistent_tool_xyz")

suite "requireTool":
  test "requireTool resolves bash":
    let result = requireTool("bash")
    check result.len > 0
    check fileExists(result)

suite "codetracerPrefix":
  test "codetracerPrefix is non-empty":
    check codetracerPrefix.len > 0

suite "external tool resolution":
  test "bashExe() resolves to a real path":
    check bashExe().len > 0
    check fileExists(bashExe())

  test "rubyExe() resolves consistently with findTool":
    # Verify that rubyExe() at runtime matches what findTool would return
    # (assuming CODETRACER_RUBY_EXE_PATH env var is not set, which is the
    # normal test case).
    let expected = findTool("ruby")
    if getEnv("CODETRACER_RUBY_EXE_PATH").len == 0:
      check rubyExe() == expected
    else:
      # env var override is in effect — rubyExe() should match the env var
      check rubyExe() == getEnv("CODETRACER_RUBY_EXE_PATH")

  test "electronExe() resolves consistently with findTool":
    # Verify that electronExe() matches what findTool("electron") returns.
    let expected = findTool("electron")
    check electronExe() == expected
