## `ct-complete <subcommand> <partial>` lists a directory's entries in sorted
## order, whatever order the filesystem's readdir returns them in.
##
## Regression test for reprobuild-pm issue
## 2026-11-16-codetracer-cs-m10-golden-completion-case-depends-on-readdir-order:
## the CS-M10 golden `binary_help.txt` pinned `home/ tmp/ cthome/`, btrfs's
## readdir order (the order the test creates them in), and failed with TMPDIR
## on tmpfs, which lists newest first.  Thirty entries are created in an order
## that is sorted neither forwards nor backwards (`k * 7 mod 30`), so readdir
## lists them out of byte order on every filesystem `ct` runs on (hash order
## on ext4, creation order on btrfs, creation order reversed on tmpfs), and a
## listing that passes readdir's order through fails here on any of them.
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

suite "ct-complete: path candidates are sorted, not in readdir order":

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
  # (`<root>/` would not: `parentDir` drops a trailing slash's last
  # component, so the partial `dir/` lists `dir`'s parent -- reprobuild-pm
  # issues/2026-11-18-ct-complete-partial-ending-in-slash-lists-the-parent-directory.md.)
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

  removeDir(root)
