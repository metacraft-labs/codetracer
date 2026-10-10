## ct_home.nim — THE one place CodeTracer decides where a user's own state
## lives on disk.
##
## ## `CODETRACER_HOME`
##
## When `CODETRACER_HOME` is set, EVERY per-user location below derives from it,
## on every OS, and no other variable (`HOME`, `USERPROFILE`, `XDG_*_HOME`,
## `APPDATA`, `LOCALAPPDATA`, `TMPDIR`/`TEMP`) is consulted for them:
##
##     $CODETRACER_HOME/
##       data/      trace index (trace_index.db), recordings (<uuid>/), saves/,
##                  review-datasets/, contract-debug-wasm/, shell launchers,
##                  ct-native-replay's licensing counter (state.db)
##       config/    .config.yaml and layouts, remote.config, endpoint settings,
##                  origin-patterns.toml, license.dat, daemon.conf
##       state/     native layout state (tui/gpui), ct-test run store,
##                  `ct ci` run state (ci/), daemon.log
##       cache/     observability trace cache (traces/), mapping catalog,
##                  the per-run cache dirs (run-<pid>/)
##       tmp/       what used to be %TEMP%\codetracer / $TMPDIR/codetracer:
##                  run-<pid>/, session-manager/, upload scratch, sockets
##       launcher/  the launcher's user root (components/, grants/, registry/)
##                  when CODETRACER_USER_ROOT is not set
##
## When it is UNSET, every location resolves exactly as it did before this
## module existed — the fallbacks below are the old expressions, moved here
## verbatim, including their inconsistencies (the trace index ignores
## `XDG_DATA_HOME` while the recordings honour it).
##
## A MORE SPECIFIC override still wins over `CODETRACER_HOME`, because it names
## one location rather than all of them: `CODETRACER_TUI_LAYOUT_DIR`,
## `CODETRACER_TEST_RUN_STORE`, `CODETRACER_STATE_DIR`,
## `CODETRACER_REMOTE_CONFIG_DIR`, `CODETRACER_USER_ROOT`,
## `CODETRACER_COMPONENTS_ROOT`, `CODETRACER_LICENSE_FILE`,
## `CODETRACER_TRACE_CACHE_DIR`, `CT_CATALOG_PATH`, `CODETRACER_RUNTIME_DIR`.
##
## ## Why it exists
##
## Test isolation. On 2026-09-23 the trace_index suites wrote test recordings
## into a developer's real `trace_index.db` on Windows: they redirected `HOME`,
## and Nim's `getHomeDir` reads `USERPROFILE` there. Redirecting the home
## directory is an OS-specific guessing game (HOME, USERPROFILE, APPDATA,
## LOCALAPPDATA, XDG_*, TMPDIR, TEMP, …). One variable that every resolver in
## every language honours is not. Every test entry point sets it to a fresh
## temporary directory (`src/frontend/test_support/state_isolation.nim`,
## force-imported into every test program; `ci/lib/run-nim-test-lane.sh`;
## `ci/lib/codetracer-home.sh`; `libs/ct-home`'s `isolate_for_tests`), and
## `src/common/ct_home_isolation_test.nim` fails if one stops.
##
## The Rust twin is `libs/ct-home` (crate `ct-home`). The two MUST agree on
## the layout: `src/common/ct_home_isolation_test.nim` pins this side, and the
## crate's own tests read `CtHomeArea`'s spellings from this file.
##
## Children inherit `CODETRACER_HOME` through the ordinary environment, so
## nothing has to forward it: a spawned `db-backend`, `replay-server` or
## `ct-native-replay` resolves the same directories. A child whose env is
## built from scratch must copy it — `CodetracerHomeEnvVar` is the name.

import std / [os, strutils]
import env

when defined(js) and not defined(ctRenderer):
  import std / jsffi
  let ctHomeNodeOs = require("os")
  let ctHomeNodePath = require("path")

const
  CodetracerHomeEnvVar* = "CODETRACER_HOME"
    ## The one variable that relocates every per-user location.

type
  CtHomeArea* = enum
    ## The fixed subdirectories of `$CODETRACER_HOME`. The string values ARE
    ## the directory names, and the Rust twin uses the same spellings.
    chaData = "data"
    chaConfig = "config"
    chaState = "state"
    chaCache = "cache"
    chaTmp = "tmp"
    chaLauncher = "launcher"

proc codetracerHome*(): string =
  ## The absolute value of `$CODETRACER_HOME`, or "" when it is unset or
  ## empty. A relative value is resolved against this process's current
  ## directory, so a child started elsewhere still agrees with its parent only
  ## if the value was absolute — every harness in this repository sets an
  ## absolute one.
  let raw = env.get(CodetracerHomeEnvVar, "").strip()
  if raw.len == 0:
    return ""
  when defined(js):
    when defined(ctRenderer):
      raw
    else:
      $ctHomeNodePath.resolve(raw.cstring).to(cstring)
  else:
    absolutePath(raw)

proc codetracerHomeIsSet*(): bool =
  codetracerHome().len > 0

proc ctHomeArea*(area: CtHomeArea): string =
  ## `$CODETRACER_HOME/<area>`, or "" when `CODETRACER_HOME` is unset.
  let root = codetracerHome()
  if root.len == 0: "" else: root / $area

proc ctHomeAreaOr*(area: CtHomeArea; legacy: string): string =
  ## `$CODETRACER_HOME/<area>` when it is set, else `legacy` — for a site whose
  ## historical location does not match the shared fallback of its area (it
  ## ignored an XDG variable, say), so the unset case stays byte-identical.
  let h = ctHomeArea(area)
  if h.len > 0: h else: legacy

proc userHomeDir*(): string =
  ## The OS user's home directory: the fallback root when `CODETRACER_HOME` is
  ## unset. Nim's `getHomeDir` (`HOME` on POSIX, `USERPROFILE` on Windows) on
  ## the C backend, node's `os.homedir()` on the JS one, "" in the renderer
  ## (which has no filesystem of its own and is told paths by the main
  ## process).
  when defined(js):
    when defined(ctRenderer):
      ""
    else:
      $ctHomeNodeOs.homedir().to(cstring)
  else:
    getHomeDir()

proc xdgOrHome(xdgVar: string; homeRelative: openArray[string]): string =
  let xdg = env.get(xdgVar, "")
  if xdg.len > 0:
    return xdg
  result = userHomeDir()
  for part in homeRelative:
    result = result / part

proc ctDataDir*(): string =
  ## Recordings, `saves/`, review datasets.
  ## `$CODETRACER_HOME/data`, else `$XDG_DATA_HOME/codetracer`, else
  ## `~/.local/share/codetracer`.
  let h = ctHomeArea(chaData)
  if h.len > 0: h
  else: xdgOrHome("XDG_DATA_HOME", [".local", "share"]) / "codetracer"

proc ctDataDirIgnoringXdg*(): string =
  ## The trace index (`trace_index.db`) and the other things that have always
  ## been written to `~/.local/share/codetracer` WITHOUT consulting
  ## `XDG_DATA_HOME` (stylus contract wasm, `ct install`'s shell launchers).
  ## `$CODETRACER_HOME/data` — the SAME directory as `ctDataDir` — else
  ## `~/.local/share/codetracer`. Unifying the unset case with `ctDataDir`
  ## would move an existing user's trace index whenever they have
  ## `XDG_DATA_HOME` set, which is a behaviour change this module does not
  ## make.
  let h = ctHomeArea(chaData)
  if h.len > 0: h
  else: userHomeDir() / ".local" / "share" / "codetracer"

proc ctConfigDir*(): string =
  ## `.config.yaml`, layouts, `remote.config`, endpoint settings.
  ## `$CODETRACER_HOME/config`, else `$XDG_CONFIG_HOME/codetracer`, else
  ## `~/.config/codetracer`.
  let h = ctHomeArea(chaConfig)
  if h.len > 0: h
  else: xdgOrHome("XDG_CONFIG_HOME", [".config"]) / "codetracer"

proc ctStateDir*(): string =
  ## State a program writes for itself (layouts, run store).
  ## `$CODETRACER_HOME/state`, else `$XDG_STATE_HOME/codetracer`, else
  ## `~/.local/state/codetracer`.
  let h = ctHomeArea(chaState)
  if h.len > 0: h
  else: xdgOrHome("XDG_STATE_HOME", [".local", "state"]) / "codetracer"

proc ctCacheDir*(): string =
  ## Re-fetchable data. `$CODETRACER_HOME/cache`, else
  ## `$XDG_CACHE_HOME/codetracer`, else `~/.cache/codetracer`.
  let h = ctHomeArea(chaCache)
  if h.len > 0: h
  else: xdgOrHome("XDG_CACHE_HOME", [".cache"]) / "codetracer"

proc legacyTmpFolder(): string =
  env.get("TMPDIR",
    env.get("TEMPDIR",
      env.get("TEMP",
        env.get("TMP", "/tmp"))))

proc ctTmpDir*(): string =
  ## What `paths.codetracerTmpPath` has always been: per-run scratch,
  ## `session-manager/` port files, upload scratch, the sockets whose names
  ## `common_types/debugger_features/debugger` derives.
  ## `$CODETRACER_HOME/tmp`, else (macOS)
  ## `$HOME/Library/Caches/com.codetracer.CodeTracer/`, else
  ## `$TMPDIR|$TEMPDIR|$TEMP|$TMP|/tmp` + `/codetracer`.
  let h = ctHomeArea(chaTmp)
  if h.len > 0:
    return h
  when defined(ctmacos):
    env.get("HOME") / "Library/Caches/com.codetracer.CodeTracer/"
  else:
    legacyTmpFolder() / "codetracer"

proc ctTmpCacheDir*(): string =
  ## What `paths.codetracerCache` has always been (per-run `run-<pid>/`
  ## caches, Electron's cache dir). `$CODETRACER_HOME/cache`, else (macOS)
  ## `$HOME/Library/Caches/com.codetracer.CodeTracer/cache`, else
  ## `<tmp>/codetracer/cache`.
  let h = ctHomeArea(chaCache)
  if h.len > 0:
    return h
  when defined(ctmacos):
    env.get("HOME") / "Library/Caches/com.codetracer.CodeTracer/cache"
  else:
    legacyTmpFolder() / "codetracer/cache"

proc ctLauncherUserRootDefault*(): string =
  ## The launcher's user root when `CODETRACER_USER_ROOT` is unset:
  ## `$CODETRACER_HOME/launcher`, else `$HOME/.codetracer`, else "" (the
  ## launcher refuses rather than inventing a path). Only `HOME`, never
  ## `USERPROFILE`: this is `codetracer-launcher`'s own rule
  ## (`install.nim`'s `envOrHome`), and the two must agree.
  let h = ctHomeArea(chaLauncher)
  if h.len > 0:
    return h
  let home = env.get("HOME", "")
  if home.len == 0: "" else: home.strip(leading = false, chars = {'/'}) / ".codetracer"
