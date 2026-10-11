# force_import_isolation.nims — `include`d by the repo-root `config.nims` and by
# every DEEPER `config.nims` under `src/` that does not import
# `state_isolation` itself (today: `src/ct_test/config.nims`).
#
# It force-imports `state_isolation.nim` — which gives the program a private
# `CODETRACER_HOME` (src/common/ct_home.nim) before any of its own modules
# initialise — into every TEST-SHAPED program under `src/`.
#
# WHY THE LAST CONFIG HAS TO DO IT. Nim evaluates config files from the repo
# root down to the project directory, and an `--import` set by an earlier one
# applies to the NimScript evaluation of every later `config.nims` too. That
# later evaluation then runs `state_isolation`'s initialisation in the VM,
# where `std/exitprocs`' lock cannot exist:
#     locks.nim(38, 5) Error: cannot 'importc' variable at compile time; initSysLock
# So the root adds the switch only when no deeper `config.nims` follows
# (`ctDeeperConfigNims`), and a deeper one that does not already import the
# module includes this file and calls `ctForceImportStateIsolation` at its END.
#
# The caller must `import std/[os, strutils]`.

proc ctNormDir(d: string): string =
  ## `/` separators and, on Windows, case-folded: a drive letter can be spelt
  ## `M:` by one tool and `m:` by another.
  result = d.replace('\\', '/')
  when defined(windows):
    result = result.toLowerAscii

proc ctDeeperConfigNims(repoRoot: string): bool =
  ## Whether a `config.nims` between the project directory and `repoRoot`
  ## (exclusive) will be evaluated after the root one.
  let root = ctNormDir(repoRoot)
  var dir = projectDir()
  while ctNormDir(dir).startsWith(root & "/"):
    if fileExists(dir / "config.nims"):
      return true
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent

proc ctForceImportStateIsolation(repoRoot: string) =
  # `ct_test` is the SHIPPED `ct-test` binary (src/ct_test/ct_test.nim), not a
  # suite: it must never relocate a user's state, so it is excluded by name.
  const shippedTestShapedNames = ["ct_test"]
  let project = projectName()
  let dir = ctNormDir(projectDir())
  let srcDir = ctNormDir(repoRoot / "src")
  let underSrc = dir == srcDir or dir.startsWith(srcDir & "/")
  let underTestsDir = dir.endsWith("/tests") or "/tests/" in dir
  let testShaped = project notin shippedTestShapedNames and
    (project.endsWith("_test") or project.startsWith("test_") or
     "_test_" in project or underTestsDir)
  if underSrc and testShaped:
    switch("import", repoRoot / "src" / "frontend" / "test_support" /
                     "state_isolation.nim")
