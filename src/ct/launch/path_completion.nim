## The file-system half of `ct-complete <subcommand> <partial>`: the entries
## of the directory a partial path names, filtered by the subcommand's
## declared file types.  `help_delegate.completionsForSubcommand` calls it
## for every subcommand codetracer-desktop handles itself.
##
## The candidates are sorted, byte by byte.  `walkDir` yields the order the
## filesystem's readdir chooses -- hash order on ext4, creation order on
## btrfs, newest first on tmpfs -- so without the sort the same directory
## completes differently on another filesystem, and the CS-M10 golden
## `binary_help.txt`, which runs `ct-complete record ""` in a scratch
## directory under TMPDIR, held on btrfs and failed on /dev/shm (reprobuild-pm
## issue
## 2026-11-16-codetracer-cs-m10-golden-completion-case-depends-on-readdir-order).
##
## Standard library only, so its test (`path_completion_test.nim`) compiles
## without the rest of `ct`.

import std/[algorithm, os, strutils]

proc pathCompletions*(prefix: string; fileTypes: openArray[string]): seq[string] =
  ## The entries of the directory `prefix` names -- the part up to and
  ## including its last path separator, or the current directory when it has
  ## none -- whose names start with the rest of `prefix`, sorted.  A partial
  ## that ends in a separator (`src/`) therefore lists that directory itself.
  ## The directory part is kept as typed, so a candidate always extends the
  ## partial.  Directories end with `/` and are always offered; a file is
  ## offered only when `fileTypes` is empty or holds its extension (with the
  ## dot).
  ##
  ## The split is not `parentDir`/`extractFilename`: `parentDir("pd/sub/")`
  ## is `pd`, so the partial `pd/sub/` listed `sub`'s siblings (reprobuild-pm
  ## issue
  ## 2026-11-18-ct-complete-partial-ending-in-slash-lists-the-parent-directory).
  ## Joining with `/` also rewrote what the user typed (`pd` came back as
  ## `./pd/`, `pd//s` as `pd/sub/`), and a shell drops a candidate that does
  ## not start with the typed word.  The split is the one clispec's
  ## `cliCompleteFiles` makes; unlike clispec, this listing does not expand
  ## `~` or hide dot-files.
  var cut = -1
  for i in countdown(prefix.high, 0):
    if prefix[i] == '/' or (DirSep != '/' and prefix[i] == DirSep):
      cut = i
      break
  let dirPart = if cut >= 0: prefix[0 .. cut] else: ""
  let basePart = if cut >= 0: prefix[cut + 1 .. ^1] else: prefix
  let searchDir = if dirPart.len == 0: getCurrentDir() else: dirPart
  if not dirExists(searchDir): return
  for kind, leaf in walkDir(searchDir, relative = true):
    if not leaf.startsWith(basePart): continue
    let full = dirPart & leaf
    if kind == pcDir:
      result.add full & "/"
      continue
    if fileTypes.len == 0:
      result.add full
      continue
    let ext = splitFile(leaf).ext
    if ext in fileTypes:
      result.add full
  result.sort(system.cmp[string])
