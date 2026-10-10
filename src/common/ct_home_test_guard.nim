## ct_home_test_guard — make a test helper that WRITES CodeTracer state fail
## closed when it is not isolated.
##
## The suites that spawn a helper (`trace_index_test`, `trace_index_migration_
## test`, `cross_machine_replay_test`, `recording_folder_layout_test`) give it a
## scratch `CODETRACER_HOME`, and pin that its trace index resolves inside it.
## A pin only REPORTS: the scenarios after it still ran, and a helper whose
## resolver had stopped honouring `CODETRACER_HOME` wrote — and migrated — the
## developer's real trace index (seen 2026-10-10, under a deliberate mutation of
## `ct_home.ctHomeArea`). So each helper calls `requireIsolatedCodetracerHome`
## before any scenario that writes: no `CODETRACER_HOME`, or any location
## resolving outside it, and the helper exits non-zero before touching a file.

import std/[os, strutils]
import ct_home

proc normForCompare(p: string): string =
  result = normalizedPath(absolutePath(p)).replace('\\', '/')
  when defined(windows):
    result = result.toLowerAscii

proc requireIsolatedCodetracerHome*(locations: openArray[(string, string)]) =
  ## Exit(2) unless `CODETRACER_HOME` is set and every `(name, path)` in
  ## `locations` lies inside it.
  let home = codetracerHome()
  if home.len == 0:
    stderr.writeLine "REFUSING: CODETRACER_HOME is not set; this helper " &
      "writes CodeTracer state and runs only under a scratch one."
    quit(2)
  let root = normForCompare(home).strip(leading = false, chars = {'/'})
  for (name, path) in locations:
    let p = normForCompare(path)
    if not (p == root or p.startsWith(root & "/")):
      stderr.writeLine "REFUSING: " & name & " resolves to " & path &
        ", outside CODETRACER_HOME " & home & " — a resolver ignored it " &
        "(src/common/ct_home.nim). Nothing was written."
      quit(2)
