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
  ## The entries of the directory `prefix` names (its parent part, or the
  ## current directory) whose names start with the rest of `prefix`, sorted.
  ## Directories end with `/` and are always offered; a file is offered only
  ## when `fileTypes` is empty or holds its extension (with the dot).
  let dirPart = prefix.parentDir
  let basePart = prefix.extractFilename
  let searchDir = if dirPart.len == 0: getCurrentDir() else: dirPart
  if not dirExists(searchDir): return
  for kind, child in walkDir(searchDir, relative = (dirPart.len == 0)):
    let leaf = (if dirPart.len == 0: child else: child.extractFilename)
    if not leaf.startsWith(basePart): continue
    let full = (if dirPart.len == 0: leaf else: dirPart / leaf)
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
