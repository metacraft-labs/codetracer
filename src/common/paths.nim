import std / [os, options, strformat]
import env

when not defined(js):
  when defined(windows):
    # Avoid POSIX-only pwd/getpwuid on Windows toolchains.
    let username = env.get("USERNAME", "unknown")
  else:
    import std / posix

    # copied and adapted from https://stackoverflow.com/a/8953445/438099
    let pwd = getpwuid(geteuid())
    let username = pwd.pw_name

  var inUiTest = false
else:
  type
    NodePath* = ref object
      join*: proc: cstring {.varargs.}
      resolve*: proc(path: cstring): cstring
      dirname*: proc(path: cstring): cstring
      basename*: proc(path: cstring): cstring

  when not defined(ctRenderer):
    import std / jsffi

    let nodeOs = require("os")
    # copied and adapted from https://stackoverflow.com/a/40424568/438099
    let username = cast[cstring](nodeOs.userInfo().username)

  else:
    let codetracerExeDirDefault* = ""
    let username = ""

  var inUiTest = false
  when defined(ctRenderer):
    inUiTest = false
  else:
    inUiTest = env.get("CODETRACER_IN_UI_TEST", "") == "1"

when not defined(ctRenderer):
  import std / sequtils

## Compile-time fallback for the runtime-deps prefix. When the nix build
## passes -d:codetracerPrefixConst=<path>, this value is baked into the
## binary/JS so that paths resolve even when CODETRACER_PREFIX is not in
## the process environment (e.g. Electron renderer in the nix package).
const codetracerPrefixConst {.strdefine.} = ""

when not defined(js) and defined(ctEntrypoint):
  # echo "ct entrypoint"
  let codetracerExeDir* = getAppDir().parentDir
else:
  # In non-entrypoint contexts (e.g. Electron renderer), codetracerExeDir is
  # derived from CODETRACER_PREFIX when available, otherwise the compile-time
  # constant, otherwise "<unknown>".
  let codetracerExeDir* = env.get("CODETRACER_PREFIX",
    if codetracerPrefixConst.len > 0: codetracerPrefixConst
    else: "<unknown>")

when not defined(js) and defined(ctEntrypoint):
  let codetracerPrefix* = env.get("CODETRACER_PREFIX", getAppDir().parentDir)
else:
  let codetracerPrefix* = env.get("CODETRACER_PREFIX",
    if codetracerPrefixConst.len > 0: codetracerPrefixConst
    else: codetracerExeDir)

when not defined(js):
  proc ctAppFilename*(): string =
    ## The path this process should report as "the executable I am".
    ##
    ## `getAppFilename()` reads /proc/self/exe, which names the file the kernel
    ## exec'd. The AppImage starts its binaries as
    ##
    ##   <AppDir>/bin/ld-linux-x86-64.so.2 --library-path <AppDir>/lib <prog>
    ##
    ## so that they link against the glibc bundled in the AppImage rather than
    ## the host's -- without that, every distro whose glibc is older than the
    ## one we build against fails to start. /proc/self/exe then names the
    ## LOADER, and there is no way to change that from userspace (`--argv0`
    ## rewrites argv[0] only). So the generated wrapper passes the real path in
    ## CODETRACER_APP_FILENAME and we prefer it when present.
    ##
    ## Use this instead of `getAppFilename()` wherever the result is handed to
    ## another process or recorded as "where ct lives". `getAppDir()` needs no
    ## equivalent: the loader is bundled in bin/ alongside the programs, so the
    ## directory is right either way.
    result = env.get("CODETRACER_APP_FILENAME", "")
    if result.len == 0:
      result = getAppFilename()

  var toolSearches = 0

  proc toolSearchCount*(): int =
    ## How many `PATH` searches this process has performed so far.
    ##
    ## Exists so PLAT-1's invariant is ASSERTABLE rather than merely intended:
    ## `src/common/paths_test.nim` samples this at its own module-init time and
    ## requires it to be 0, which is a direct statement that no `<tool>Exe()`
    ## resolved itself before `main`.  Without it the property can only be
    ## checked by counting `newfstatat` under `strace`, which is a tool the
    ## suite cannot depend on being installed.
    ##
    ## `findTool` is the single choke point every lookup goes through, so one
    ## counter here covers all of them.
    toolSearches

  proc findTool*(name: string): string =
    ## Find an external tool on PATH.
    ## Returns the full path, or "" if not found.
    inc toolSearches
    result = findExe(name)

  proc requireTool*(name: string, installHint: string = ""): string =
    ## Find an external tool on PATH, or exit with a helpful error.
    result = findTool(name)
    if result.len == 0:
      var msg = "error: required tool '" & name & "' not found on PATH"
      if installHint.len > 0:
        msg &= "\n  install: " & installHint
      quit(msg, 1)

# ── Tool paths are resolved AT FIRST USE, not at module init (PLAT-1) ────────
#
# ## What this replaces, and what it cost
#
# Every `<tool>Exe*` below used to be a module-level `let` whose initialiser
# called `findTool` (i.e. `findExe`).  Nim runs module initialisers BEFORE
# `main`, so *every* `ct` invocation searched `PATH` for all 38 of them —
# `ct --version`, `ct --help`, a `--ui` handoff that only ever execs another
# binary, all of it — and then used at most one.  (38 accessors, 39 searches:
# `mcrRecorderExe` looks for `ct-mcr` and then `ct_cli`.)
#
# `findExe` stats `<entry>/<name>` for every entry of `PATH` until it hits, so a
# tool that is ABSENT costs one failed `newfstatat` per entry and the total
# scales with `len(PATH)`.  Measured on this tree at 193 `PATH` entries (a nix
# dev shell): 5,445 `newfstatat` calls before the handoff `execve`, 5,400 of
# them failing, and `ct replay --ui=tui --version` cost 16.3 ms more than
# spawning `codetracer-tui --version` directly — against PLAT-1's 10 ms gate
# (`codetracer-specs/CLI/ct/ui-selection.md` §3.1).  On a 2-entry `PATH` the
# same two binaries differed by 3.5 ms.  The gap was not the selector; it was
# this block.  After: 46 `newfstatat`, 34 failing, and 2.6 ms.
#
# ## The contract these templates keep
#
# 1. **The resolved value is unchanged for a FIXED environment.**  Same env
#    vars, same precedence, same `findTool` calls, same `""`-when-absent.  Only
#    the *moment* of the `PATH` search moves.
#
#    The exception, stated because it is a real behaviour change rather than a
#    theoretical one: a process that mutates its own **`PATH`** after this
#    module initialises now gets the new `PATH`, where before it got the old
#    one.  `ct` does exactly that — `loadEnvFiles` in `src/ct/launch/launch.nim`
#    `putEnv`s every key an `--env-file` / `--env0-file` carries, and on the
#    macOS `open` path that file is a dump of the user's whole shell
#    environment, `PATH` included.  So `ct` opened from Finder now resolves its
#    recorders against the user's `PATH` instead of launchd's, which is what
#    those flags exist to achieve.  It is an improvement, but it is not "no
#    change", and `paths_test.nim`'s laziness case is the thing that
#    demonstrates it: it plants a binary on a `PATH` set AFTER module init and
#    requires the accessor to find it.
#
# 2. **Env overrides are still captured at module init.**  `envOverride` is
#    called eagerly — it is a hash lookup in `environ`, not a syscall, so it is
#    free — and only the `PATH` search is deferred.  This is deliberate:
#    the same `loadEnvFiles` runs strictly AFTER this module has initialised and
#    therefore has never affected these values.  Reading the env lazily instead
#    would have let an env file start overriding `CODETRACER_RUBY_EXE_PATH` and
#    friends — a semantic change, smuggled in under a performance fix.
#    Capturing eagerly keeps that question exactly where it was.  (That the env
#    files land too late to be honoured here is arguably a bug in its own right;
#    it is NOT fixed here.)
#
# 3. **Failure behaviour is unchanged, because there was none.**  Every
#    initialiser below used `findTool`, which returns `""` for a missing tool.
#    None used `requireTool`, which is the one that `quit`s.  So no diagnostic
#    existed at startup that could move to first use: a missing tool produced
#    `""` then and produces `""` now, and the consumer that cares still reports
#    it (e.g. `db_backend_record.nim`'s `if mcrRecorderExe().len == 0`).
#
# 4. **Memoised, so a value read twice is searched once** — a lazy conversion
#    that re-searched per access would trade a startup cost for a worse
#    steady-state one.  The cache is `{.threadvar.}`: resolution is a pure
#    function of the environment and `PATH`, so a per-thread cache yields the
#    same answer as a shared one while being free of the write race a shared
#    global would have.
#
# The accessors are procs, so every call site spells the parentheses —
# `bashExe()`.  That is not cosmetic: a paren-less parameterless proc is NOT
# transparently a value in Nim (`echo bashExe` passes the *proc* to a
# `varargs[typed]`), so the explicit call is what keeps a missed conversion a
# compile error instead of a silent one.

type ToolOverride = Option[string]
  ## An `env`-var override for a tool path, captured at module init.
  ##
  ## `Option` rather than `string` because "set to the empty string" and "not
  ## set" are DIFFERENT for `os.getEnv(key, default)`, which returns the
  ## default only when the key is absent.  Collapsing them would silently
  ## change what `CODETRACER_RUBY_EXE_PATH=""` means.

proc envOverride(key: string): ToolOverride =
  ## Capture `key` with exactly the presence semantics `env.get` has on this
  ## target: `os.getEnv` treats an empty-but-present var as a value, while the
  ## JS `env.get` treats it as absent.  Preserving the difference per target is
  ## what makes these accessors byte-for-byte compatible with the `let`s they
  ## replace.
  when not defined(js):
    if existsEnv(key): some(getEnv(key)) else: none(string)
  else:
    let raw = env.get(key, "")
    if raw.len > 0: some(raw) else: none(string)

proc orElse(first, second: ToolOverride): ToolOverride =
  ## Left-biased choice, for the values that accept a second, legacy env var
  ## (`CODETRACER_BEAM_RECORDER_BIN` before `CODETRACER_ELIXIR_RECORDER_BIN`,
  ## `CODETRACER_CT_MCR_CMD` before `CODETRACER_CT_MCR_PATH`).  It reproduces
  ## the nesting the `env.get(a, env.get(b, ...))` initialisers had.
  if first.isSome: first else: second

template lazyToolPath(name: untyped, override: ToolOverride,
                      search: untyped) =
  ## Declare `name*(): string` — an env override captured now, a `PATH` search
  ## deferred to the first call, and the answer memoised for every call after.
  let capturedOverride = override   # EAGER, at module init; see point 2 above.
  var cache {.threadvar.}: string
  var resolved {.threadvar.}: bool
  proc name*(): string =
    if not resolved:
      cache = if capturedOverride.isSome: capturedOverride.get else: search
      resolved = true
    cache

template lazyToolPath(name: untyped, search: untyped) =
  ## The no-override form, for tools that are only ever found on `PATH`.
  lazyToolPath(name, none(string), search)

let bundledCtagsPath = codetracerPrefix / "bin" / "ctags"
let bundledNargoPath = codetracerPrefix / "bin" / "nargo"
when not defined(js):
  let bundledNargoPathWithExeExt = bundledNargoPath & ExeExt

when defined(js) and not defined(ctRenderer):
  # On Windows (no Nix), use full paths so child_process.spawn works without
  # relying on PATH.  On Linux/macOS the Nix wrapper sets PATH to include
  # the codetracer derivation's bin/, but downstream consumers (Playwright
  # GUI test harness, dev shells without the wrapper, direct `ct host`
  # invocations from a Justfile recipe, etc.) drop the wrapper's PATH
  # additions when they spawn ct host as a subprocess — and then any
  # nested `spawn("ct", ...)` for `trace-metadata` fails with ENOENT, the
  # server's startup throws, and the renderer's socket.io transport
  # closes before any CODETRACER:: events get delivered.
  #
  # Resolve to the absolute path when ``codetracerExeDir`` is known and
  # the binary actually exists on disk; fall back to the bare name only
  # when we have no better information.  This keeps the
  # Nix-wrapper-PATH-only happy path working and removes the PATH
  # assumption for everyone else.
  proc resolveCodetracerExe(): cstring =
    when defined(windows):
      cstring(codetracerExeDir / "bin" / "ct")
    else:
      if codetracerExeDir.len > 0 and codetracerExeDir != "<unknown>":
        let candidate = codetracerExeDir / "bin" / "ct"
        # ``existsFile`` is unavailable on the JS target; ask Node directly.
        proc nodeFsExistsSync(p: cstring): bool {.importjs: "require('fs').existsSync(#)".}
        if nodeFsExistsSync(cstring(candidate)):
          return cstring(candidate)
      cstring("ct")
  proc resolveDbBackendRecordExe(): cstring =
    when defined(windows):
      cstring(codetracerExeDir / "bin" / "db-backend-record")
    else:
      if codetracerExeDir.len > 0 and codetracerExeDir != "<unknown>":
        let candidate = codetracerExeDir / "bin" / "db-backend-record"
        proc nodeFsExistsSync(p: cstring): bool {.importjs: "require('fs').existsSync(#)".}
        if nodeFsExistsSync(cstring(candidate)):
          return cstring(candidate)
      cstring("db-backend-record")
  let
    codetracerExe* = $resolveCodetracerExe()
    dbBackendRecordExe* = $resolveDbBackendRecordExe()
elif not defined(pythonPackage):
  let
    codetracerExe* = codetracerExeDir / "bin" / "ct"
    dbBackendRecordExe* = codetracerExeDir / "bin" / "db-backend-record"
else:
  let
    codetracerExe* = "ct"
    dbBackendRecordExe* = "db-backend-record"

let
  cTraceSourcePath* = codetracerPrefix / "src" / "trace.c"
  consoleExe* = codetracerPrefix / "bin" / "console"
  # Deprecated: ct-remote is now built into the ct binary natively.
  # Kept for the "ct remote" escape hatch during migration.
  ctRemoteExe* {.deprecated: "ct-remote is now built into ct".} = codetracerExeDir / "bin" / "ct-remote"
  taskProcessExe* = codetracerPrefix / "bin" / "task_process"
  phpRecorderExtension* = env.get("CODETRACER_PHP_RECORDER_EXTENSION",
    codetracerPrefix / "lib" / "codetracer.so")

  dbBackendExe* = codetracerPrefix / "bin" / "replay-server"
  backendManagerExe* = codetracerPrefix / "bin" / "session-manager"
  virtualizationLayersExe* = codetracerPrefix / "bin" / "virtualization-layers"

  electronIndexPath* = codetracerExeDir / "src" / "index.js"
  userInterfacePath* = codetracerExeDir / "ui.js"

# External tools — resolved on PATH at first use.  See the block comment above
# `lazyToolPath` for why these are accessors rather than `let`s.
lazyToolPath(bashExe):
  when not defined(js): findTool("bash") else: codetracerPrefix / "bin" / "bash"

lazyToolPath(python3Path, envOverride("CODETRACER_PYTHON_EXE_PATH")):
  when not defined(js): findTool("python3") else: codetracerPrefix / "bin" / "python3"

lazyToolPath(rubyExe, envOverride("CODETRACER_RUBY_EXE_PATH")):
  when not defined(js): findTool("ruby") else: codetracerPrefix / "bin" / "ruby"

lazyToolPath(rubyRecorderPath, envOverride("CODETRACER_RUBY_RECORDER_PATH")):
  when not defined(js): findTool("codetracer-ruby-recorder")
  else: codetracerPrefix / "bin" / "codetracer-ruby-recorder"

lazyToolPath(noirExe, envOverride("CODETRACER_NOIR_EXE_PATH")):
  when defined(js): bundledNargoPath else: findTool("nargo")

lazyToolPath(wazeroExe, envOverride("CODETRACER_WASM_VM_PATH")):
  when not defined(js): findTool("wazero") else: codetracerPrefix / "bin" / "wazero"

# Blockchain/VM recorder binaries — looked up from env vars with fallback to PATH
lazyToolPath(cairoRecorderExe, envOverride("CODETRACER_CAIRO_RECORDER_PATH")):
  when not defined(js): findTool("codetracer-cairo-recorder")
  else: codetracerPrefix / "bin" / "codetracer-cairo-recorder"

lazyToolPath(midenRecorderExe, envOverride("CODETRACER_MIDEN_RECORDER_PATH")):
  when not defined(js): findTool("codetracer-miden-recorder")
  else: codetracerPrefix / "bin" / "codetracer-miden-recorder"

lazyToolPath(moveRecorderExe, envOverride("CODETRACER_MOVE_RECORDER_PATH")):
  when not defined(js): findTool("codetracer-move-recorder")
  else: codetracerPrefix / "bin" / "codetracer-move-recorder"

lazyToolPath(solanaRecorderExe, envOverride("CODETRACER_SOLANA_RECORDER_PATH")):
  when not defined(js): findTool("codetracer-solana-recorder")
  else: codetracerPrefix / "bin" / "codetracer-solana-recorder"

lazyToolPath(fuelRecorderExe, envOverride("CODETRACER_FUEL_RECORDER_PATH")):
  when not defined(js): findTool("codetracer-fuel-recorder")
  else: codetracerPrefix / "bin" / "codetracer-fuel-recorder"

lazyToolPath(circomRecorderExe, envOverride("CODETRACER_CIRCOM_RECORDER_PATH")):
  when not defined(js): findTool("codetracer-circom-recorder")
  else: codetracerPrefix / "bin" / "codetracer-circom-recorder"

lazyToolPath(leoRecorderExe, envOverride("CODETRACER_LEO_RECORDER_PATH")):
  when not defined(js): findTool("codetracer-leo-recorder")
  else: codetracerPrefix / "bin" / "codetracer-leo-recorder"

lazyToolPath(polkavmRecorderExe, envOverride("CODETRACER_POLKAVM_RECORDER_PATH")):
  when not defined(js): findTool("codetracer-polkavm-recorder")
  else: codetracerPrefix / "bin" / "codetracer-polkavm-recorder"

lazyToolPath(tonRecorderExe, envOverride("CODETRACER_TON_RECORDER_PATH")):
  when not defined(js): findTool("codetracer-ton-recorder")
  else: codetracerPrefix / "bin" / "codetracer-ton-recorder"

lazyToolPath(cardanoRecorderExe, envOverride("CODETRACER_CARDANO_RECORDER_PATH")):
  when not defined(js): findTool("codetracer-cardano-recorder")
  else: codetracerPrefix / "bin" / "codetracer-cardano-recorder"

lazyToolPath(flowRecorderExe, envOverride("CODETRACER_FLOW_RECORDER_PATH")):
  when not defined(js): findTool("codetracer-flow-recorder")
  else: codetracerPrefix / "bin" / "codetracer-flow-recorder"

lazyToolPath(evmRecorderExe, envOverride("CODETRACER_EVM_RECORDER_PATH")):
  when not defined(js): findTool("codetracer-evm-recorder")
  else: codetracerPrefix / "bin" / "codetracer-evm-recorder"

# Python recorder — pip-installed console script from the venv.
lazyToolPath(pythonRecorderExe):
  when not defined(js): findTool("codetracer-python-recorder")
  else: codetracerPrefix / "bin" / "codetracer-python-recorder"

# Shell recorders — the launcher scripts are the entry points.
# In the nix package they are installed as codetracer-bash-recorder / codetracer-zsh-recorder.
lazyToolPath(bashRecorderExe):
  when not defined(js): findTool("codetracer-bash-recorder")
  else: codetracerPrefix / "bin" / "codetracer-bash-recorder"

lazyToolPath(zshRecorderExe):
  when not defined(js): findTool("codetracer-zsh-recorder")
  else: codetracerPrefix / "bin" / "codetracer-zsh-recorder"

# JavaScript/TypeScript recorder — Node.js CLI installed via npm.
lazyToolPath(jsRecorderExe):
  when not defined(js): findTool("codetracer-js-recorder")
  else: codetracerPrefix / "bin" / "codetracer-js-recorder"

# PHP recorder — a Zend extension, NOT an executable.  codetracer-php-recorder
# ships no wrapper binary: `ct` runs `php -d extension=<so>` itself (the same
# thing that repo's scripts/run_with_tracing.sh does), so the two things it
# needs are the php binary and the path of the built `codetracer.so`.  There
# is nothing for findTool to find for the latter, hence the explicit env var
# (exported for a sibling checkout by scripts/detect-siblings.sh) with the
# installed-package location as the fallback — see `phpRecorderExtension`
# above, which stays an eager `let` because it never searches PATH.
lazyToolPath(phpExe, envOverride("CODETRACER_PHP_EXE_PATH")):
  when not defined(js): findTool("php") else: codetracerPrefix / "bin" / "php"

# BEAM recorder (Elixir + Erlang) — one Rust CLI that wraps the command that
# starts the BEAM program, so `ct` also needs the language runtime that
# command runs.  CODETRACER_BEAM_RECORDER_BIN is what detect-siblings.sh
# exports; CODETRACER_ELIXIR_RECORDER_BIN is its legacy alias, kept because
# that script still exports both.
lazyToolPath(beamRecorderExe,
             envOverride("CODETRACER_BEAM_RECORDER_BIN").orElse(
               envOverride("CODETRACER_ELIXIR_RECORDER_BIN"))):
  when not defined(js): findTool("codetracer-beam-recorder")
  else: codetracerPrefix / "bin" / "codetracer-beam-recorder"

lazyToolPath(elixirExe, envOverride("CODETRACER_ELIXIR_EXE_PATH")):
  when not defined(js): findTool("elixir") else: codetracerPrefix / "bin" / "elixir"

lazyToolPath(escriptExe, envOverride("CODETRACER_ESCRIPT_EXE_PATH")):
  when not defined(js): findTool("escript") else: codetracerPrefix / "bin" / "escript"

# Native SERVER recorder — codetracer-native-recorder's `ct_server_record`
# binary, which supervises a long-running server recording (time-sliced
# containers, `requests`/`discover` span extraction) rather than recording
# one program run the way `ct-mcr record` does.  This is what
# `ct record --server` uses for native programs.
lazyToolPath(nativeServerRecorderExe,
             envOverride("CODETRACER_NATIVE_SERVER_RECORDER_PATH")):
  when not defined(js): findTool("codetracer-native-recorder")
  else: codetracerPrefix / "bin" / "codetracer-native-recorder"

# Nim native recorder — for ``.nim`` (compiled) programs, ``ct record`` first
# compiles the source to a native binary via ``nimCompilerExe()`` and then
# records that binary with the MCR ``ct-mcr`` (``ct_cli``) tool from the
# ``codetracer-native-recorder`` repo.  ``CODETRACER_CT_MCR_PATH`` overrides
# the lookup; ``CODETRACER_NIM_EXE_PATH`` overrides the compiler used for
# both ``nim c`` and ``nim e`` (``.nims`` scripts).
# Resolution order is the one documented in scripts/detect-siblings.sh (and
# implemented by the Rust `find_ct_mcr` in codetracer-native-backend):
#   1. $CODETRACER_CT_MCR_CMD — what the dev shell exports for a sibling
#      checkout, pointing at codetracer-native-recorder/ct_cli/ct_cli;
#   2. $CODETRACER_CT_MCR_PATH — the older ct-side spelling, still honored;
#   3. `ct-mcr` on PATH — the installed-package name;
#   4. `ct_cli` on PATH — the in-tree build's name.
# Only checking (2) and (3) is why `ct record example.nim` could not find
# the recorder inside the dev shell at all: the shell exports (1) and puts
# a binary named `ct_cli` on PATH, so both lookups missed and the exe was
# the empty string.
lazyToolPath(mcrRecorderExe,
             envOverride("CODETRACER_CT_MCR_CMD").orElse(
               envOverride("CODETRACER_CT_MCR_PATH"))):
  when not defined(js):
    # ONE search per name.  The `let` this replaced called `findTool("ct-mcr")`
    # twice — once to test and once to use — which on a long PATH is the whole
    # scan done twice for the common case where ct-mcr is absent.
    let ctMcr = findTool("ct-mcr")
    if ctMcr.len > 0: ctMcr else: findTool("ct_cli")
  else:
    codetracerPrefix / "bin" / "ct-mcr"

lazyToolPath(nimCompilerExe, envOverride("CODETRACER_NIM_EXE_PATH")):
  when not defined(js): findTool("nim") else: codetracerPrefix / "bin" / "nim"

lazyToolPath(cargoExe):
  when not defined(js): findTool("cargo") else: codetracerPrefix / "bin" / "cargo"

lazyToolPath(electronExe):
  when not defined(js): findTool("electron") else: codetracerPrefix / "bin" / "electron"

lazyToolPath(chromedriverExe):
  when not defined(js): findTool("chromedriver")
  else: codetracerPrefix / "bin" / "chromedriver"

lazyToolPath(ctagsExe, envOverride("CODETRACER_CTAGS_EXE_PATH")):
  when defined(js): bundledCtagsPath else: findTool("ctags")

let cTraceObjectFilePath* = env.get(
  "CODETRACER_C_TRACE_OBJECT_FILE_PATH",
  codetracerPrefix / "lib" / "trace.o")

when defined(ctmacos):
  let codetracerTmpPath* = env.get("HOME") / "Library/Caches/com.codetracer.CodeTracer/"
  let codetracerCache* = env.get("HOME") / "Library/Caches/com.codetracer.CodeTracer/cache"
else:
  let tmpFolder = env.get("TMPDIR",
                            env.get("TEMPDIR",
                                    env.get("TEMP",
                                            env.get("TMP",
                                                    "/tmp"
                                            )
                                    )
                            )
  )
  let
    codetracerCache* = tmpFolder / "codetracer/cache"
    codetracerTmpPath* = tmpFolder / "codetracer"

let
  localShellPreloadInstallPath* = codetracerTmpPath / fmt"shell_preload_{username}.so"

var
  # overrideable in local functions !:
  shellPreloadPath* = codetracerPrefix / "lib" / "shell_preload.so"


# other path/exe consts:
#  either universal, or usually development environment-specific
let
  codetracerInstallDir* = when defined(builtWithNix):
    codetracerExeDir # e.g. result/ (from result/)
  else:
    codetracerExeDir.parentDir.parentDir # <top-level>/ (from <top-level>/src/build-debug/)

  nodeModulesPath* = codetracerPrefix / "node_modules"

  codetracerTestDir* = codetracerInstallDir / "src" / "tests"
  codetracerNixResultExe* = codetracerInstallDir / "result" / "bin" / "ct"
  codetracerTestBuildDir* = codetracerExeDir / "tests"
  programDir* = codetracerTestDir / "programs"
  recordDir* = codetracerTestDir / "records"
  testProgramBinariesDir* = codetracerTestDir / "binaries"
  runDir* = codetracerTestBuildDir / "run"
  reportFilesDir* = codetracerTestDir / "report-files"

  # we should load our dependencies from our own codebase if possible
  # e.g. having a python/ruby submodule
  #   eventually we might support various python/ruby paths ..
  #   for now this is easier
  #   note: python/ruby/lua are not currently real submodules
  #   TODO: support them normally

  rubyPath* = codetracerInstallDir / "libs" / "ruby" / "ruby"
  luaPath* = codetracerInstallDir / "libs" / "lua"

  nimcacheDir* = codetracerTmpPath / "codetracer_projects/"

lazyToolPath(scriptExe):
  when not defined(js): findTool("script") else: codetracerPrefix / "bin" / "script"

lazyToolPath(zipExe):
  when not defined(js): findTool("zip") else: codetracerPrefix / "bin" / "zip"

lazyToolPath(unzipExe):
  when not defined(js): findTool("unzip") else: codetracerPrefix / "bin" / "unzip"

lazyToolPath(curlExe):
  when not defined(js): findTool("curl") else: codetracerPrefix / "bin" / "curl"

lazyToolPath(nodeExe, envOverride("CODETRACER_NODE_EXE_PATH")):
  when defined(js): codetracerPrefix / "bin" / "node" else: findTool("node")

# echo "codetracer exe dir ", codetracerExeDir

when not defined(ctRenderer):
  when not defined(js):
    let home* = getHomeDir()
  else:
    # TODO implement `/`
    let home* = $(cast[cstring](nodeOs.homedir()) & cstring"/")

  let codetracerTraceDir* = home / ".local" / "share" / "codetracer"

  proc recordingFolder*(baseDir: string, recordingId: string): string =
    ## Resolve the on-disk recording folder for ``recordingId`` under
    ## ``baseDir``.  M-REC-7: the folder name is now the bare UUIDv7
    ## (lowercase 36-char hyphenated form) rather than the pre-M-REC-7
    ## ``trace-<int_id>`` / ``trace-<uuid>`` prefix.  See
    ## ``codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.md``
    ## §4 ("On-Disk Recording Folder Layout") for the rationale: the
    ## bare UUIDv7 is portable across machines, lex-sorts by creation
    ## time, and lets the SQLite row remain the single source of truth
    ## for human-friendly metadata (program name, date, args).
    ##
    ## Empty / sentinel recording ids are rejected here rather than
    ## silently producing a degenerate ``baseDir/`` path that would
    ## collide with siblings.  Callers must mint a fresh id (via
    ## ``trace_index.newID`` / ``newRecordingId``) before invoking this
    ## helper.
    doAssert recordingId.len > 0,
      "recordingFolder: recording_id must be non-empty (caller must " &
      "mint a UUIDv7 via trace_index.newID / newRecordingId first)"
    baseDir / recordingId

  proc reviewDatasetFolder*(baseDir: string, artifactId: string): string =
    ## Where a downloaded review dataset lands, under ``baseDir``.
    ##
    ## AS-2: the sibling of ``recordingFolder`` for the second artifact kind.
    ## It sits under its own ``review-datasets/`` subdirectory rather than
    ## beside the recordings, because ``codetracer_trace_dir`` is enumerated as
    ## "one directory per recording" in several places and a dataset dropped
    ## among them would be read as a recording with no container.  The leaf is
    ## the bare artifact id, for the same reasons M-REC-7 gives for recordings:
    ## portable across machines, and lex-sorting by creation time.
    doAssert artifactId.len > 0,
      "reviewDatasetFolder: artifact id must be non-empty"
    baseDir / "review-datasets" / artifactId

  let DB_FOLDERS* = @[codetracerTraceDir, codetracerTestDir]
  when not defined(serverCI):
    let DB_PATHS* = DB_FOLDERS.mapIt(it / "trace_index.db")
  else:
    let DB_PATHS* = DB_FOLDERS.mapIt(it / "index.db")
