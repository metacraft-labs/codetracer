## `ct-complete <subcommand> <partial>` lists the directory a partial names,
## in sorted order, and every candidate extends the partial as typed.
##
## Two properties, each a regression test for a reprobuild-pm issue:
##
## - Sorted, whatever order the filesystem's readdir returns
##   (2026-11-16-codetracer-cs-m10-golden-completion-case-depends-on-readdir-order).
##   The CS-M10 golden `binary_help.txt` pinned `home/ tmp/ cthome/`, btrfs's
##   readdir order (the order the test creates them in), and failed with TMPDIR
##   on tmpfs, which lists newest first.  Thirty entries are created in an order
##   that is sorted neither forwards nor backwards (`k * 7 mod 30`), so readdir
##   lists them out of byte order on every filesystem `ct` runs on (hash order
##   on ext4, creation order on btrfs, creation order reversed on tmpfs), and a
##   listing that passes readdir's order through fails here on any of them.
## - A partial ending in a separator lists that directory, not its parent
##   (2026-11-18-ct-complete-partial-ending-in-slash-lists-the-parent-directory):
##   `parentDir("pd/sub/")` is `pd`, so `ct-complete record src/` offered
##   `src`'s siblings.  The typed directory part is kept as typed, so a
##   one-word partial gets no `./` in front.
##
## It runs the production `pathCompletions` (`path_completion.nim`), the
## function `help_delegate.completionsForSubcommand` returns for every
## subcommand codetracer-desktop handles itself, on a real directory.
## Nothing is mocked.  Discovered by the `ct-cli-units` lane's glob.
##
## Build/run:
##   nim c -r --hints:off src/ct/launch/path_completion_test.nim

import std/[algorithm, os, sequtils, strutils, unittest]

import ./path_completion

suite "ct-complete: path candidates name the typed directory, sorted":

  let root = getTempDir() / "ct_path_completion_" & $getCurrentProcessId()
  removeDir(root)
  createDir(root)
  var dirs, pyFiles, txtFiles: seq[string]
  for k in 0 ..< 30:
    let i = k * 7 mod 30
    let name = "e" & align($i, 2, '0')
    case i mod 3
    of 0:
      createDir(root / name)
      dirs.add name & "/"
    of 1:
      writeFile(root / (name & ".py"), "")
      pyFiles.add name & ".py"
    else:
      writeFile(root / (name & ".txt"), "")
      txtFiles.add name & ".txt"
  let everything = sorted(dirs & pyFiles & txtFiles, system.cmp[string])
  let dirsAndPy = sorted(dirs & pyFiles, system.cmp[string])

  # Every entry's name starts with `e`, so `<root>/e` names all of them.
  test "a partial in a directory: every entry, sorted":
    check pathCompletions(root & "/e", []) ==
      everything.mapIt(root & "/" & it)

  test "the subcommand's file types filter files, never directories":
    check pathCompletions(root & "/e", [".py"]) ==
      dirsAndPy.mapIt(root & "/" & it)

  test "a partial name narrows the listing and keeps it sorted":
    check pathCompletions(root & "/e1", []) ==
      everything.filterIt(it.startsWith("e1")).mapIt(root & "/" & it)

  test "an empty partial lists the current directory, relative and sorted":
    # The CS-M10 golden's case: `ct-complete record ""` in its scratch
    # directory.
    let before = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(before)
    check pathCompletions("", []) == everything

  # A partial ending in a separator names that directory: `ct-complete
  # record src/` offers `src`'s entries.  Nim's `parentDir("pd/sub/")` is
  # `pd`, so a split by `parentDir` listed `sub`'s siblings instead
  # (reprobuild-pm issue
  # 2026-11-18-ct-complete-partial-ending-in-slash-lists-the-parent-directory).
  # `e00/` holds `inner.py` and `deeper/`; its siblings must not appear.
  writeFile(root / "e00" / "inner.py", "")
  createDir(root / "e00" / "deeper")

  test "a partial ending in a separator lists that directory, not its parent":
    check pathCompletions(root & "/e00/", []) ==
      @[root & "/e00/deeper/", root & "/e00/inner.py"]

  test "a partial ending in a separator, relative to the current directory":
    let before = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(before)
    check pathCompletions("e00/", [".py"]) == @["e00/deeper/", "e00/inner.py"]
    check pathCompletions("e00/i", []) == @["e00/inner.py"]

  test "a one-word relative partial: candidates extend it as typed":
    let before = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(before)
    check pathCompletions("e0", []) ==
      everything.filterIt(it.startsWith("e0"))

  test "the filesystem root lists its entries, each written once from `/`":
    let top = pathCompletions("/", [])
    check top.len > 0
    check top.allIt(it.startsWith("/") and not it.startsWith("//"))
    # The entries are those of `/` itself, not of the current directory with
    # a `/` in front: every candidate names something that exists at `/`.
    check top.allIt(fileExists(it) or dirExists(it) or symlinkExists(it))
    var direct: seq[string]
    for kind, leaf in walkDir("/", relative = true):
      direct.add "/" & leaf & (if kind == pcDir: "/" else: "")
    direct.sort(system.cmp[string])
    check top == direct

  removeDir(root)
