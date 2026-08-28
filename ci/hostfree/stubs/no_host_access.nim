## The host-free build's poison list: every host entry point, declared so that
## calling it from front-end code is a compile error.
##
## ## How this is used
##
## `ci/test/hostfree-build.sh` compiles each module of the host-free surface
## through a two-line probe:
##
## ```nim
## import stubs/no_host_access
## include viewmodels/state_vm
## ```
##
## `include` splices the module's source into the probe's scope, so every
## declaration below is visible **to that module's body and to nothing else**.
## Its dependencies still compile in their own scopes against the real stdlib,
## which is what makes the rule enforceable at all: NS1's rule is about
## front-end code, and a mechanism that also policed `nim-everywhere`'s
## internals would fail 91 of 119 modules on one legitimate line inside
## somebody else's filesystem seam. (That is measured, not hypothetical — it is
## what `--import:` and `patchFile` each did before this design replaced them;
## see ci/hostfree/config.nims.)
##
## ## Why the error reads "ambiguous call"
##
## Each declaration matches the real one's signature exactly. A call site
## therefore sees two equally good candidates and the compiler refuses to
## choose, naming both — including this file, which explains itself. That is a
## harder failure than an `{.error.}` pragma alone would give: the pragma only
## fires when our overload *wins*, whereas ambiguity fires whenever the real one
## is reachable. The pragmas are still here for the cases where ours wins
## outright, because then the message is the one a developer needs.
##
## ## What this deliberately does not poison
##
## * **Path arithmetic** — `parentDir`, `joinPath`, `/`, `splitFile`. They are
##   string functions. Banning them would push callers into hand-rolled string
##   surgery, which is worse than the problem.
## * **`std/times`** — the wall clock is the *time* facade's concern
##   (Front-Ends/IsoNim/nim-everywhere-Time-Facade.md), not this one.
## * **`echo` and `stdout`** — diagnostics are not a platform capability.
##
## ## The residual, stated plainly
##
## A caller who writes `os.fileExists(p)` — qualified — disambiguates the call
## and gets through. So does one who declares their own `{.importc.}` binding to
## a libc symbol. Neither is reachable by accident, both are visible in review,
## and `ci/test/hostfree-build.sh` scenario 6 covers the first with a source
## check that has its own mutation test. No mechanism in Nim closes the second,
## and claiming otherwise would be the kind of check that cannot fail.

{.push warning[UnusedImport]: off, hint[XDeclaredButNotUsed]: off.}

const advice =
  " is not available in the host-free build — route it through " &
  "src/frontend/viewmodel/platform (NS1, the platform facade)"

# ---------------------------------------------------------------------------
# `system` / `std/syncio` — reachable with no import at all
# ---------------------------------------------------------------------------

proc readFile*(filename: string): string {.error: "readFile" & advice.} = discard
proc writeFile*(filename, content: string) {.error: "writeFile" & advice.} = discard
proc writeFile*(filename: string; content: openArray[byte])
    {.error: "writeFile" & advice.} = discard
proc readLines*(filename: string; n: Natural): seq[string]
    {.error: "readLines" & advice.} = discard
proc readLines*(filename: string): seq[string]
    {.error: "readLines" & advice.} = discard
iterator lines*(filename: string): string {.error: "lines" & advice.} = discard
proc open*(f: var File; filename: string; mode: FileMode = fmRead;
           bufSize: int = -1): bool {.error: "open" & advice.} = discard
proc open*(filename: string; mode: FileMode = fmRead; bufSize: int = -1): File
    {.error: "open" & advice.} = discard
proc readAll*(file: File): string {.error: "readAll" & advice.} = discard

# ---------------------------------------------------------------------------
# `std/os` and its Nim 2 split-outs — filesystem interrogation and mutation
# ---------------------------------------------------------------------------

proc fileExists*(filename: string): bool {.error: "fileExists" & advice.} = discard
proc dirExists*(dir: string): bool {.error: "dirExists" & advice.} = discard
proc symlinkExists*(link: string): bool {.error: "symlinkExists" & advice.} = discard
proc removeFile*(file: string) {.error: "removeFile" & advice.} = discard
proc tryRemoveFile*(file: string): bool {.error: "tryRemoveFile" & advice.} = discard
proc removeDir*(dir: string; checkDir = false) {.error: "removeDir" & advice.} = discard
proc moveFile*(source, dest: string) {.error: "moveFile" & advice.} = discard
proc moveDir*(source, dest: string) {.error: "moveDir" & advice.} = discard
proc copyFile*(source, dest: string) {.error: "copyFile" & advice.} = discard
proc copyDir*(source, dest: string) {.error: "copyDir" & advice.} = discard
proc createDir*(dir: string) {.error: "createDir" & advice.} = discard
proc existsOrCreateDir*(dir: string): bool
    {.error: "existsOrCreateDir" & advice.} = discard
proc createSymlink*(src, dest: string) {.error: "createSymlink" & advice.} = discard
proc createHardlink*(src, dest: string) {.error: "createHardlink" & advice.} = discard
proc expandSymlink*(symlinkPath: string): string
    {.error: "expandSymlink" & advice.} = discard
proc getFileSize*(file: string): int64 {.error: "getFileSize" & advice.} = discard
proc getFileSize*(file: File): int64 {.error: "getFileSize" & advice.} = discard
proc sameFile*(path1, path2: string): bool {.error: "sameFile" & advice.} = discard
proc sameFileContent*(path1, path2: string): bool
    {.error: "sameFileContent" & advice.} = discard
proc isHidden*(path: string): bool {.error: "isHidden" & advice.} = discard
proc expandFilename*(filename: string): string
    {.error: "expandFilename" & advice.} = discard
proc absolutePath*(path: string; root: string): string
    {.error: "absolutePath" & advice.} = discard

iterator walkDir*(dir: string; relative = false; checkDir = false;
                  skipSpecial = false): tuple[kind: int, path: string]
    {.error: "walkDir" & advice.} = discard
iterator walkDirRec*(dir: string): string {.error: "walkDirRec" & advice.} = discard
iterator walkFiles*(pattern: string): string {.error: "walkFiles" & advice.} = discard
iterator walkDirs*(pattern: string): string {.error: "walkDirs" & advice.} = discard
iterator walkPattern*(pattern: string): string
    {.error: "walkPattern" & advice.} = discard

# ---------------------------------------------------------------------------
# `std/appdirs` and `std/tempfiles` — the host's own directories
# ---------------------------------------------------------------------------

proc getCurrentDir*(): string {.error: "getCurrentDir" & advice.} = discard
proc setCurrentDir*(newDir: string) {.error: "setCurrentDir" & advice.} = discard
proc getHomeDir*(): string {.error: "getHomeDir" & advice.} = discard
proc getConfigDir*(): string {.error: "getConfigDir" & advice.} = discard
proc getCacheDir*(): string {.error: "getCacheDir" & advice.} = discard
proc getDataDir*(): string {.error: "getDataDir" & advice.} = discard
proc getTempDir*(): string {.error: "getTempDir" & advice.} = discard
proc getAppDir*(): string {.error: "getAppDir" & advice.} = discard
proc getAppFilename*(): string {.error: "getAppFilename" & advice.} = discard
proc createTempDir*(prefix, suffix: string; dir = ""): string
    {.error: "createTempDir" & advice.} = discard
proc genTempPath*(prefix, suffix: string; dir = ""): string
    {.error: "genTempPath" & advice.} = discard

# ---------------------------------------------------------------------------
# `std/envvars` and `std/cmdline` — the host's environment and argv
# ---------------------------------------------------------------------------

proc getEnv*(key: string; default = ""): string {.error: "getEnv" & advice.} = discard
proc putEnv*(key, val: string) {.error: "putEnv" & advice.} = discard
proc existsEnv*(key: string): bool {.error: "existsEnv" & advice.} = discard
proc delEnv*(key: string) {.error: "delEnv" & advice.} = discard
iterator envPairs*(): tuple[key, value: string] {.error: "envPairs" & advice.} = discard
proc paramStr*(i: int): string {.error: "paramStr" & advice.} = discard
proc paramCount*(): int {.error: "paramCount" & advice.} = discard
proc commandLineParams*(): seq[string]
    {.error: "commandLineParams" & advice.} = discard
proc findExe*(exe: string; followSymlinks: bool = true;
              extensions: openArray[string] = @[]): string
    {.error: "findExe" & advice.} = discard

# ---------------------------------------------------------------------------
# `std/osproc` — process execution
# ---------------------------------------------------------------------------
#
# Only the entry points. `waitForExit`, `terminate` and `close` take a
# `Process`, and the only way to obtain one is a call that is already poisoned,
# so declaring them would buy nothing and would risk colliding with unrelated
# `close`/`kill` overloads in front-end code.

#
# Note the division of labour with `ci/hostfree/config.nims`: `std/osproc` is
# additionally **patched out entirely**, so `import std/osproc` is itself the
# error and every name in it is undeclared. The declarations here are the
# belt to that pair of braces — they fire for a caller who reaches a process
# primitive by some other route, and they keep the poison list readable as a
# complete statement of what the front end may not do.

proc startProcess*(command: string): int {.error: "startProcess" & advice.} = discard
proc execProcess*(command: string): string {.error: "execProcess" & advice.} = discard
proc execCmd*(command: string): int {.error: "execCmd" & advice.} = discard
proc execCmdEx*(command: string): tuple[output: string, exitCode: int]
    {.error: "execCmdEx" & advice.} = discard
proc execShellCmd*(command: string): int {.error: "execShellCmd" & advice.} = discard
proc countProcessors*(): int {.error: "countProcessors" & advice.} = discard
proc quoteShell*(s: string): string {.error: "quoteShell" & advice.} = discard
proc quoteShellCommand*(args: openArray[string]): string
    {.error: "quoteShellCommand" & advice.} = discard
proc sleep*(milsecs: int) {.error: "sleep" & advice.} = discard

# ---------------------------------------------------------------------------
# Raw POSIX — the back door left open because `std/times` needs `std/posix`
# ---------------------------------------------------------------------------

proc fork*(): cint {.error: "fork" & advice.} = discard
proc execv*(a1: cstring; a2: cstringArray): cint {.error: "execv" & advice.} = discard
proc execvp*(a1: cstring; a2: cstringArray): cint {.error: "execvp" & advice.} = discard
proc execve*(a1: cstring; a2, a3: cstringArray): cint
    {.error: "execve" & advice.} = discard
proc popen*(a1, a2: cstring): File {.error: "popen" & advice.} = discard
proc chdir*(a1: cstring): cint {.error: "chdir" & advice.} = discard
proc unlink*(a1: cstring): cint {.error: "unlink" & advice.} = discard
proc rmdir*(a1: cstring): cint {.error: "rmdir" & advice.} = discard
proc getenv*(a1: cstring): cstring {.error: "getenv" & advice.} = discard
proc putenv*(a1: cstring): cint {.error: "putenv" & advice.} = discard
proc setenv*(a1, a2: cstring; a3: cint): cint {.error: "setenv" & advice.} = discard

{.pop.}
