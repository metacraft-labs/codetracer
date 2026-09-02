## The web instantiation of the platform facade — NS2's first deliverable,
## Noir-Studio.md §3.1's second column.
##
## ## Why this module is in the host-free surface, and why that matters more
## ## here than anywhere else
##
## The obvious place for a web instantiation is `viewmodel/host/`, beside
## `desktop_electron.nim`, which reaches `require('fs')` and is outside the
## gate by design. Putting the web one there would have been symmetric and
## wrong.
##
## NS1's own account of its gate records the blind spot: "**`when defined(js):`**
## — the probe is a `nim c` compile, so no JS branch in the surface is ever
## type-checked, and the JS backend is the one the renderer ships. **53 of the
## 121 surface modules contain such a block.**" A web instantiation written as
## one large `when defined(js)` would be the single most important module in
## the product to check and the one the gate cannot see at all.
##
## So the browser is not reached from here. Everything the tab supplies —
## OPFS, the clipboard, a download, `window.open`, `localStorage`,
## `navigator.storage` — arrives as `BrowserBridge`, a record of `proc`s that
## `host/web_browser.nim` fills in with the real ones and a test fills in with
## fakes. This module has **no `when defined(js)` block, no `importjs` and no
## `emit`**, so:
##
## - the host-free gate type-checks all of it, on the C backend, today;
## - `vm-unit-js` runs all of it, on the backend it ships on, against a bridge
##   whose behaviour the suite controls;
## - the browser-specific code that remains is `host/web_browser.nim` and
##   `host/opfs_volume.nim`, which are small, are the only things that need a
##   browser to exercise, and are structured so a fake OPFS global drives them
##   under node.
##
## That is a smaller residual than "53 modules the gate cannot see", and it is
## the shape NS2 recommends for the container instantiation too.
##
## ## What the web profile claims, and the one correction NS2 makes to it
##
## `capabilities.webProfile` was written in NS1 from the spec. Building against
## it found one claim the platform does not support: `capFilesystemArbitraryPaths`
## was already correctly absent, but `capFilesystemTemp` was present — and the
## web has no platform-reclaimed scratch directory. What it has is a staging
## area *inside the project store*, which `project_store.nim` empties on open.
## That is a different thing: it is not reclaimed by the platform, it is not
## outside the store, and a caller who asked for a temp directory to write a
## large intermediate into would be writing into the user's quota. The profile
## is corrected here rather than in `capabilities.nim` so the reference
## profiles stay the specification's and the instantiation's narrowing stays
## visible — which is what `withCapabilities` exists for.

import ./outcome
import ./capabilities
import ./fs
import ./process
import ./wasm_registry
import ./vcs
import ./settings
import ./clipboard
import ./download
import ./shell
import ./platform
import ./store_volume
import ./project_store
import ./archive
import ./paths

export platform, project_store, archive, wasm_registry

type
  BrowserBridge* {.requiresInit.} = ref object
    ## Everything the tab supplies that is not the project store.
    ##
    ## `{.requiresInit.}` for the same reason the facades carry it: a bridge
    ## operation added here must fail the build at `host/web_browser.nim` and
    ## at every test that builds one, rather than defaulting to `nil` and
    ## crashing in a user's tab.
    volume*: StoreVolume
    persistenceGranted*: bool
    persistenceAnswered*: bool
      ## Both from `navigator.storage.persisted()` / `.persist()`, and both
      ## needed: §4.2 asks that "whether it was **granted** is shown, never
      ## assumed", and a browser that does not answer is neither granted nor
      ## denied.
    ownerId*: string
      ## Identifies this tab for the one-writer lock. Minted per page load.
    nowMs*: proc(): int64
      ## The clock, through a proc, because `std/times` is the *time* facade's
      ## concern and a store that read the wall clock directly would be
      ## untestable for the same reason the time facade exists.

    writeClipboardText*: proc(text: string
                             ): PlatformFuture[PlatformOutcome[Nothing]]
    writeClipboardHtml*: proc(html, plainText: string
                             ): PlatformFuture[PlatformOutcome[Nothing]]
    offerDownload*: proc(suggestedName: string; content: seq[byte];
                         mimeType: string
                        ): PlatformFuture[PlatformOutcome[Nothing]]
    pickFiles*: proc(options: OpenDialogOptions
                    ): PlatformFuture[PlatformOutcome[seq[string]]]
      ## The File System Access API's `showOpenFilePicker`. The returned
      ## strings are store paths of the *imported copies*, not host paths —
      ## §4.2's "opening work from elsewhere goes through the import path
      ## (upload or a shared link) rather than a path box".
    pickDirectory*: proc(options: OpenDialogOptions
                        ): PlatformFuture[PlatformOutcome[string]]
    suggestSaveName*: proc(options: SaveDialogOptions
                          ): PlatformFuture[PlatformOutcome[string]]
    openExternalUrl*: proc(url: string
                          ): PlatformFuture[PlatformOutcome[Nothing]]
    setFullscreen*: proc(fullscreen: bool
                        ): PlatformFuture[PlatformOutcome[Nothing]]
    windowState*: proc(): PlatformFuture[PlatformOutcome[WindowState]]
    onWindowStateChanged*: proc(handler: proc(state: WindowState))
    shareLinkOrigin*: string
      ## Configuration, never a constant. Empty means sharing is not
      ## configured for this deployment, which is a legitimate build (a local
      ## dev server) and must not be a compiled-in host name.
    wasm*: WasmHost
      ## NS3: the tab's answer to §3.1's "wasm modules in the tab".
      ##
      ## One field rather than four procs, and the registry travels with the
      ## runner deliberately: a host that can run a module and a list of which
      ## modules exist are the same fact, and splitting them is how a profile
      ## comes to claim a capability whose modules were never loaded.
      ##
      ## `noWasmModules()` is a legitimate value — a deployment that ships no
      ## toolchain — and `newWebPlatform` narrows the profile accordingly
      ## rather than letting the platform claim `capProcessSpawn` and then
      ## refuse every command.

  WebPlatform* = ref object
    ## The instantiation, plus the store it was built over, because the
    ## product needs both: the facades for the panes, the store for the
    ## durability banner, the export action and the writer role.
    platform*: Platform
    store*: StoreSession
    bridge*: BrowserBridge
    activeProjectId*: string

const webInstantiationCapabilities*: CapabilitySet =
  webCapabilities - {capFilesystemTemp}
  ## See the header. The web has staging inside the store, not a platform temp
  ## directory, and claiming the latter would make `fs.makeTempDir` a promise.

proc webInstantiationProfile*(shareConfigured: bool): PlatformProfile =
  ## Narrowed from `webProfile` rather than rebuilt, so the degradation
  ## sentences the spec review wrote stay the ones the product shows.
  var capabilities = webInstantiationCapabilities
  if not shareConfigured:
    capabilities = capabilities - {capShareLink}
  var degradations = webProfile.degradations
  degradations.add DegradationRule(capability: capFilesystemTemp, behaviour:
    "the browser gives the page no scratch directory it will reclaim; " &
    "intermediate files are staged inside the project store and removed when " &
    "the project is next opened, so they count against your storage until then")
  if not shareConfigured:
    degradations.add DegradationRule(capability: capShareLink, behaviour:
      "this deployment has no sharing origin configured, so a project can be " &
      "exported as an archive but not published as a link")
  webProfile.withCapabilities(capabilities, degradations)

# ---------------------------------------------------------------------------
# The filesystem facade, over the project store
# ---------------------------------------------------------------------------
#
# Paths reaching the facade are project-relative. A caller that passes an
# absolute path is refused rather than silently reinterpreted, because the
# alternative — quietly treating `/etc/passwd` as `etc/passwd` inside the store
# — is how a desktop code path that was never migrated starts appearing to work
# on the web while doing something entirely different.

proc buildFileSystem(web: WebPlatform; profile: PlatformProfile
                    ): FileSystemFacade =
  let store = web.store

  proc guardPath[T](path: string): PlatformOutcome[T] =
    if isAbsolute(path):
      failed[T](pkInvalidArgument,
        "'" & path & "' is an absolute path, and the web build has no " &
        "filesystem outside the project store; paths are relative to the " &
        "project")
    else:
      PlatformOutcome[T](ok: true)

  proc project(): string = web.activeProjectId

  proc readText(path: string): PlatformFuture[PlatformOutcome[string]] =
    let guard = guardPath[string](path)
    if not guard.ok: return resolved(guard)
    store.readProjectText(project(), path)

  proc readBytes(path: string): PlatformFuture[PlatformOutcome[seq[byte]]] =
    let guard = guardPath[seq[byte]](path)
    if not guard.ok: return resolved(guard)
    store.readProjectFile(project(), path)

  proc writeText(path, content: string
                ): PlatformFuture[PlatformOutcome[Nothing]] =
    let guard = guardPath[Nothing](path)
    if not guard.ok: return resolved(guard)
    if not store.readyForEditing:
      return resolvedErr[Nothing](pkAccessDenied,
        "this session has not yet told you what will happen to your work; " &
        "nothing is written until it has")
    store.writeProjectText(project(), path, content)

  proc writeBytes(path: string; content: seq[byte]
                 ): PlatformFuture[PlatformOutcome[Nothing]] =
    let guard = guardPath[Nothing](path)
    if not guard.ok: return resolved(guard)
    if not store.readyForEditing:
      return resolvedErr[Nothing](pkAccessDenied,
        "this session has not yet told you what will happen to your work; " &
        "nothing is written until it has")
    store.writeProjectFile(project(), path, content)

  proc appendText(path, content: string
                 ): PlatformFuture[PlatformOutcome[Nothing]] =
    ## Read-modify-write through the same atomic replace. There is no append
    ## primitive in OPFS that is safe against a concurrent second tab, and
    ## since §4.3 guarantees there is no concurrent second tab, the whole-file
    ## replace is both correct and the only shape the store has.
    let guard = guardPath[Nothing](path)
    if not guard.ok: return resolved(guard)
    proc startEmpty(error: PlatformError
                   ): PlatformFuture[PlatformOutcome[string]] =
      if error.kind == pkNotFound: resolvedOk("")
      else: resolved(failed[string](error))
    thenOutcome(
      recoverOutcome(store.readProjectText(project(), path), startEmpty),
      proc(existing: string): PlatformFuture[PlatformOutcome[Nothing]] =
        store.writeProjectText(project(), path, existing & content))

  proc stat(path: string): PlatformFuture[PlatformOutcome[FsStat]] =
    let guard = guardPath[FsStat](path)
    if not guard.ok: return resolved(guard)
    let full = workingTreeRoot(project()) & "/" & volumePath(path)
    mapOutcome(store.volume.stat(full), proc(entry: VolumeEntry): FsStat =
      FsStat(
        kind: (case entry.kind
               of vekFile: fekFile
               of vekDirectory: fekDirectory
               of vekMissing: fekMissing),
        size: entry.size,
        modifiedMs: 0,
        readOnly: store.writerRole(web.activeProjectId) != wrOwner))

  proc listDir(path: string): PlatformFuture[PlatformOutcome[seq[FsDirEntry]]] =
    let guard = guardPath[seq[FsDirEntry]](path)
    if not guard.ok: return resolved(guard)
    mapOutcome(store.listProjectDir(project(), path),
      proc(entries: seq[VolumeEntry]): seq[FsDirEntry] =
        for entry in entries:
          result.add FsDirEntry(
            name: entry.name,
            kind: (case entry.kind
                   of vekFile: fekFile
                   of vekDirectory: fekDirectory
                   of vekMissing: fekMissing)))

  proc createDir(path: string): PlatformFuture[PlatformOutcome[Nothing]] =
    let guard = guardPath[Nothing](path)
    if not guard.ok: return resolved(guard)
    store.volume.createDir(workingTreeRoot(project()) & "/" & volumePath(path))

  proc remove(path: string;
              recursive: bool): PlatformFuture[PlatformOutcome[Nothing]] =
    let guard = guardPath[Nothing](path)
    if not guard.ok: return resolved(guard)
    store.removeProjectFile(project(), path)

  proc copy(source, destination: string
           ): PlatformFuture[PlatformOutcome[Nothing]] =
    thenOutcome(store.readProjectFile(project(), source),
      proc(content: seq[byte]): PlatformFuture[PlatformOutcome[Nothing]] =
        store.writeProjectFile(project(), destination, content))

  proc move(source, destination: string
           ): PlatformFuture[PlatformOutcome[Nothing]] =
    thenOutcome(copy(source, destination),
      proc(ignored: Nothing): PlatformFuture[PlatformOutcome[Nothing]] =
        store.removeProjectFile(project(), source))

  FileSystemFacade(
    profile: profile,
    readText: readText,
    readBytes: readBytes,
    writeText: writeText,
    writeBytes: writeBytes,
    appendText: appendText,
    stat: stat,
    listDir: listDir,
    createDir: createDir,
    remove: remove,
    copy: copy,
    move: move,
    realPath: proc(path: string): PlatformFuture[PlatformOutcome[string]] =
      # The store has no symlinks, so the real path IS the normalised path.
      # Answering rather than refusing is correct here: the question has a
      # true answer on this platform, and refusing would make every caller
      # that resolves a path before using it take a degraded branch for
      # nothing.
      resolvedOk(volumePath(path)),
    makeTempDir: proc(prefix: string
                     ): PlatformFuture[PlatformOutcome[string]] =
      resolvedUnsupported[string]("a platform-reclaimed temporary directory"),
    watch: proc(path: string; recursive: bool;
                onEvent: proc(event: FsWatchEvent)
               ): PlatformFuture[PlatformOutcome[FsWatchHandle]] =
      # §6.2a: "File watching has no browser equivalent and needs none — on
      # desktop it exists because *other programs* change the tree, and in the
      # tab we own every write." Refused rather than faked, so the VCS panel's
      # NS5 change-event path is a real change rather than a silent no-op that
      # looked like it worked.
      resolvedUnsupported[FsWatchHandle]("watching the filesystem"),
    unwatch: proc(handle: FsWatchHandle
                 ): PlatformFuture[PlatformOutcome[Nothing]] =
      resolvedUnsupported[Nothing]("watching the filesystem"))

# ---------------------------------------------------------------------------
# Settings, over the store rather than over `localStorage`
# ---------------------------------------------------------------------------

proc settingsPath(scope: SettingsScope; key: string): string =
  let prefix =
    case scope
    of ssUser: "settings/user/"
    of ssWorkspace: "settings/workspace/"
    of ssSession: "settings/session/"
  prefix & volumePath(key)

proc buildSettings(web: WebPlatform; profile: PlatformProfile): SettingsFacade =
  ## Deliberately the store's volume and not `localStorage`.
  ##
  ## `localStorage` is synchronous, 5 MB, and — the reason that decides it —
  ## evicted on a different schedule from OPFS. Splitting a session's state
  ## across two storage systems with two eviction policies means a project
  ## that survives with settings that do not, or the reverse, and §4.1's tier
  ## table would then be describing only half the state.
  let volume = web.store.volume

  proc get(scope: SettingsScope;
           key: string): PlatformFuture[PlatformOutcome[string]] =
    mapOutcome(volume.readBytes(settingsPath(scope, key)),
      proc(bytes: seq[byte]): string =
        result = newString(bytes.len)
        for i in 0 ..< bytes.len: result[i] = bytes[i].char)

  proc set(scope: SettingsScope; key,
           value: string): PlatformFuture[PlatformOutcome[Nothing]] =
    var bytes = newSeq[byte](value.len)
    for i in 0 ..< value.len: bytes[i] = value[i].byte
    thenOutcome(volume.createDir(volumeParent(settingsPath(scope, key))),
      proc(ignored: Nothing): PlatformFuture[PlatformOutcome[Nothing]] =
        volume.writeBytes(settingsPath(scope, key), bytes))

  proc delete(scope: SettingsScope;
              key: string): PlatformFuture[PlatformOutcome[Nothing]] =
    proc alreadyGone(error: PlatformError
                    ): PlatformFuture[PlatformOutcome[Nothing]] =
      if error.kind == pkNotFound: resolvedOk()
      else: resolved(failed[Nothing](error))
    recoverOutcome(volume.remove(settingsPath(scope, key), false), alreadyGone)

  proc keys(scope: SettingsScope;
            prefix: string): PlatformFuture[PlatformOutcome[seq[string]]] =
    let root = volumeParent(settingsPath(scope, "x"))
    proc empty(error: PlatformError
              ): PlatformFuture[PlatformOutcome[seq[VolumeEntry]]] =
      if error.kind == pkNotFound: resolvedOk(newSeq[VolumeEntry](0))
      else: resolved(failed[seq[VolumeEntry]](error))
    mapOutcome(recoverOutcome(volume.list(root), empty),
      proc(entries: seq[VolumeEntry]): seq[string] =
        for entry in entries:
          if entry.kind == vekFile and
             (prefix.len == 0 or
              (entry.name.len >= prefix.len and
               entry.name[0 ..< prefix.len] == prefix)):
            result.add entry.name)

  SettingsFacade(
    profile: profile,
    get: get,
    set: set,
    delete: delete,
    keys: keys,
    environment: proc(name: string): PlatformFuture[PlatformOutcome[string]] =
      # A tab has no environment. Answering "" would let a caller that reads
      # `CT_DEBUG` believe it read an unset variable rather than that it asked
      # a question with no meaning here.
      resolvedUnsupported[string]("environment variables"),
    getSecret: proc(account, key: string
                   ): PlatformFuture[PlatformOutcome[string]] =
      resolvedUnsupported[string]("a secret store"),
    setSecret: proc(account, key, value: string
                   ): PlatformFuture[PlatformOutcome[Nothing]] =
      # §8, and the reason `capSecretStore` is absent rather than degraded to a
      # weaker store: "no secret is ever stored". A browser-storage
      # implementation here would be the promise the platform cannot keep.
      resolvedUnsupported[Nothing]("a secret store"),
    deleteSecret: proc(account, key: string
                      ): PlatformFuture[PlatformOutcome[Nothing]] =
      resolvedUnsupported[Nothing]("a secret store"))

# ---------------------------------------------------------------------------
# Process, VCS, clipboard, download, shell
# ---------------------------------------------------------------------------

proc buildProcess(web: WebPlatform; profile: PlatformProfile): ProcessFacade =
  ## NS3: §3.1's web column for process execution — "wasm modules in the tab".
  ##
  ## The whole of the decision is `registry.resolve`, and none of it reaches a
  ## browser: whether a command can run here is a question about a list, and
  ## keeping it that way is what lets `vm-unit-js` assert the *product's*
  ## answers rather than a fixture's. Only a resolved run reaches `web.wasm`.
  ##
  ## The invariant worth stating, because it is the one a refactor breaks
  ## silently: **nothing below dispatches a command it did not resolve.** A
  ## `run` that passed the spec straight to the host and let the host answer
  ## would type-check, would pass a happy-path test, and would turn "nargo fmt
  ## has no wasm build" back into the mid-run surprise §3.1 asks us to remove.
  let host = web.bridge.wasm

  proc refuse[T](command: string; args: seq[string]): PlatformOutcome[T] =
    ## The empty outcome for an unresolvable command. Returns the resolution's
    ## own error, so the four cases stay four cases all the way to the caller.
    failed[T](host.registry.resolve(command, args).refusal)

  proc resolvedModule(spec: ProcessSpec): WasmResolution =
    host.registry.resolve(spec.command, spec.args)

  ProcessFacade(
    profile: profile,

    run: proc(spec: ProcessSpec
             ): PlatformFuture[PlatformOutcome[ProcessRunResult]] =
      let resolution = resolvedModule(spec)
      if resolution.kind != wrResolved:
        return resolved(refuse[ProcessRunResult](spec.command, spec.args))
      host.run(resolution.module.moduleId, spec),

    start: proc(spec: ProcessSpec;
                onOutput: proc(chunk: ProcessOutputChunk);
                onExit: proc(exit: ProcessExit)
               ): PlatformFuture[PlatformOutcome[ProcessHandle]] =
      let resolution = resolvedModule(spec)
      if resolution.kind != wrResolved:
        return resolved(refuse[ProcessHandle](spec.command, spec.args))
      host.start(resolution.module.moduleId, spec, onOutput, onExit),

    signal: proc(handle: ProcessHandle;
                 signal: ProcessSignal): PlatformFuture[PlatformOutcome[Nothing]] =
      # `capProcessGracefulSignal` is absent, and this is what that means:
      # `worker.terminate()` is immediate and uninterceptable, so there is no
      # honest implementation of "ask it to stop". Answering `sigInterrupt` by
      # terminating would be worse than refusing — the caller would believe a
      # cooperative shutdown had been requested and would attribute whatever
      # half-written state it found to the program rather than to the kill.
      case signal
      of sigInterrupt:
        resolvedUnsupported[Nothing](
          "interrupting a run cooperatively; a worker can only be stopped " &
          "outright, which is what Stop does")
      of sigTerminate, sigKill:
        host.terminate(handle),

    writeStdin: proc(handle: ProcessHandle;
                     text: string): PlatformFuture[PlatformOutcome[Nothing]] =
      resolvedUnsupported[Nothing]("interactive input"),
    closeStdin: proc(handle: ProcessHandle
                    ): PlatformFuture[PlatformOutcome[Nothing]] =
      resolvedUnsupported[Nothing]("interactive input"),

    isRunning: proc(handle: ProcessHandle
                   ): PlatformFuture[PlatformOutcome[bool]] =
      host.isRunning(handle),

    which: proc(program: string): PlatformFuture[PlatformOutcome[string]] =
      # `process.nim`'s own note: this is "what makes 'this project script has
      # no wasm build' a nameable outcome rather than a mid-run surprise". The
      # answer is the module id, and the refusal carries the same four-case
      # error `run` would have produced, so asking first and running anyway
      # cannot disagree.
      let resolution = host.registry.resolve(program)
      if resolution.kind != wrResolved:
        return resolved(failed[string](resolution.refusal))
      resolvedOk($resolution.module.moduleId))

proc buildVcs(web: WebPlatform; profile: PlatformProfile): VcsFacade =
  ## Also every operation refusing, and this one is a **finding rather than a
  ## deliverable**, so it is written down here where it cannot be missed.
  ##
  ## `webProfile` claims `capVcsRead` and `capVcsWrite`. NS2 cannot honour
  ## either: the engine that would implement them is NS5, sequenced after
  ## launch, and §4.1's middle durability tier is explicitly unavailable until
  ## it lands. A profile that claims a capability the instantiation refuses is
  ## exactly the disagreement between "may I" and "did it work" that
  ## `capabilities.nim` exists to remove — NS1 corrected the same shape in the
  ## default platform and called it out by name.
  ##
  ## So `newWebPlatform` **removes** both from the profile it installs, and
  ## `webVcsPending` below is the degradation sentence. When NS5 lands, this
  ## proc grows an engine and the two capabilities go back; nothing else
  ## changes, which is the test that the absence was modelled rather than
  ## papered over.
  unavailableVcs(profile)

const webNoModulesLoaded* =
  "this deployment ships no wasm toolchain modules, so nothing can be run in " &
  "the tab: compiling and running tests need the Noir modules, which a " &
  "deployment loads with the application bundle"
  ## NS3. Not "the feature is missing" but "this build has no modules", which
  ## is a different and more useful thing to read: the same code with a
  ## populated registry runs, and the sentence tells a deployer which half is
  ## theirs.

const webVcsPending* =
  "version control is sequenced after launch (NS5): a browser tab has no git " &
  "binary and the in-tab engine is not built yet, so there is no history " &
  "pane, no commit and no diff — your work leaves with you as an archive export"

proc buildClipboard(web: WebPlatform;
                    profile: PlatformProfile): ClipboardFacade =
  let bridge = web.bridge
  ClipboardFacade(
    profile: profile,
    writeText: proc(text: string): PlatformFuture[PlatformOutcome[Nothing]] =
      bridge.writeClipboardText(text),
    readText: proc(): PlatformFuture[PlatformOutcome[string]] =
      # `capClipboardRead` is absent from the web profile: reading needs a
      # permission the product does not ask for. The degradation sentence
      # `webProfile` carries says paste is handled by the browser's own paste
      # event, which is why this is a refusal rather than a prompt.
      resolvedUnsupported[string]("reading the clipboard"),
    writeHtml: proc(html, plainText: string
                   ): PlatformFuture[PlatformOutcome[Nothing]] =
      bridge.writeClipboardHtml(html, plainText))

proc buildDownload(web: WebPlatform; profile: PlatformProfile): DownloadFacade =
  let bridge = web.bridge
  DownloadFacade(
    profile: profile,
    offerFile: proc(suggestedName: string; content: seq[byte];
                    mimeType: string): PlatformFuture[PlatformOutcome[Nothing]] =
      bridge.offerDownload(suggestedName, content, mimeType),
    offerText: proc(suggestedName, content,
                    mimeType: string): PlatformFuture[PlatformOutcome[Nothing]] =
      var bytes = newSeq[byte](content.len)
      for i in 0 ..< content.len: bytes[i] = content[i].byte
      bridge.offerDownload(suggestedName, bytes, mimeType),
    openFileDialog: proc(options: OpenDialogOptions
                        ): PlatformFuture[PlatformOutcome[seq[string]]] =
      bridge.pickFiles(options),
    saveFileDialog: proc(options: SaveDialogOptions
                        ): PlatformFuture[PlatformOutcome[string]] =
      bridge.suggestSaveName(options),
    pickDirectory: proc(options: OpenDialogOptions
                       ): PlatformFuture[PlatformOutcome[string]] =
      bridge.pickDirectory(options))

proc buildShell(web: WebPlatform; profile: PlatformProfile): ShellFacade =
  let bridge = web.bridge
  ShellFacade(
    profile: profile,
    openExternalUrl: proc(url: string
                         ): PlatformFuture[PlatformOutcome[Nothing]] =
      # The allow-list belongs HERE and not only in `host/web_browser.nim`,
      # because the bridge is pluggable: this is the `ShellFacade` the web
      # instantiation hands to callers, and a bridge that forgot the check
      # would inherit nothing.  Measured — `test_platform_web.nim`'s fake
      # bridge accepted `javascript:` right through a guard that was only in
      # the real one.
      if not allowedExternalUrlScheme(url):
        refuseExternalUrl(url)
      else:
        bridge.openExternalUrl(url),
    revealInFileManager: proc(path: string
                             ): PlatformFuture[PlatformOutcome[Nothing]] =
      resolvedUnsupported[Nothing]("revealing a file in a file manager"),
    windowState: proc(): PlatformFuture[PlatformOutcome[WindowState]] =
      bridge.windowState(),
    minimizeWindow: proc(): PlatformFuture[PlatformOutcome[Nothing]] =
      resolvedUnsupported[Nothing]("minimising the window"),
    toggleMaximizeWindow: proc(): PlatformFuture[PlatformOutcome[Nothing]] =
      resolvedUnsupported[Nothing]("maximising the window"),
    closeWindow: proc(): PlatformFuture[PlatformOutcome[Nothing]] =
      resolvedUnsupported[Nothing]("closing the window"),
    setFullscreen: proc(fullscreen: bool
                       ): PlatformFuture[PlatformOutcome[Nothing]] =
      bridge.setFullscreen(fullscreen),
    onWindowStateChanged: bridge.onWindowStateChanged,
    openSessionWindow: proc(sessionId: string
                           ): PlatformFuture[PlatformOutcome[Nothing]] =
      resolvedUnsupported[Nothing]("opening a second application window"))

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

var installedRegistry: WasmRegistry
  ## The registry the LIVE platform was built over.
  ##
  ## `Platform` deliberately carries no registry — it is a capability facade,
  ## and "which wasm modules exist" is not a capability. But the edit-mode
  ## toolbar needs exactly that: on the browser tier `platformVerdict` resolves
  ## a command *at subcommand granularity*, so `nargo compile` is enabled and
  ## `nargo fmt` is refused BY NAME from the same profile. Handing it an empty
  ## registry would disable Build and Run on a deployment that ships a working
  ## compiler — a dead button with a true-sounding reason, which is worse than
  ## no button.
  ##
  ## Module-level rather than threaded through `Platform` because the
  ## alternative is a field on a type in the host-free surface that only one
  ## instantiation can populate, and `capabilities.nim`'s own argument against
  ## `kind`-branching applies: the facade should stay about what you *can do*.

proc currentWasmRegistry*(): WasmRegistry =
  ## What the installed web platform can run. An empty registry is the honest
  ## answer on every other instantiation and before `newWebPlatform` runs, and
  ## it is also the answer that makes the toolbar refuse *with the profile's
  ## own sentence* rather than claim a compiler it does not have.
  installedRegistry

proc newWebPlatform*(bridge: BrowserBridge; store: StoreSession): WebPlatform =
  ## Assemble the seven facades over a store that is already open.
  ##
  ## Open first, then instantiate — not the reverse — because §4.5's refusal is
  ## a state in which there must be no platform to write through. A
  ## constructor that opened the store itself would have to return either a
  ## platform or a refusal, and every caller would then hold something that
  ## might be neither.
  var profile = webInstantiationProfile(bridge.shareLinkOrigin.len > 0)
  var capabilities = profile.capabilities - {capVcsRead, capVcsWrite}
  var degradations = profile.degradations
  degradations.add DegradationRule(
    capability: capVcsRead, behaviour: webVcsPending)
  degradations.add DegradationRule(
    capability: capVcsWrite, behaviour: webVcsPending)

  # NS3: **the profile follows the registry.** A deployment whose `WasmHost`
  # carries no modules can run nothing, and a profile claiming otherwise is
  # exactly the "may I" / "did it work" disagreement `capabilities.nim` exists
  # to remove — the same correction NS2 made for `capVcsRead` above.
  #
  # Written as a narrowing of the reference profile rather than as a build of
  # its own, so the day the registry is populated this branch simply stops
  # being taken and the spec's own sentences are what the product shows.
  if bridge.wasm.registry.modules.len == 0:
    capabilities = capabilities - {capProcessSpawn, capProcessSignal}
    degradations.add DegradationRule(
      capability: capProcessSpawn, behaviour: webNoModulesLoaded)
    degradations.add DegradationRule(
      capability: capProcessSignal, behaviour: webNoModulesLoaded)

  profile = profile.withCapabilities(capabilities, degradations)

  # Recorded here, beside the branch that reads the same field to decide
  # `capProcessSpawn`, so the registry the toolbar resolves against and the
  # registry the profile was derived from cannot be two different values.
  installedRegistry = bridge.wasm.registry

  result = WebPlatform(
    platform: newPlatform(profile),
    store: store,
    bridge: bridge,
    activeProjectId: "")
  result.platform.fs = buildFileSystem(result, profile)
  result.platform.process = buildProcess(result, profile)
  result.platform.vcs = buildVcs(result, profile)
  result.platform.settings = buildSettings(result, profile)
  result.platform.clipboard = buildClipboard(result, profile)
  result.platform.download = buildDownload(result, profile)
  result.platform.shell = buildShell(result, profile)

proc openWebStore*(bridge: BrowserBridge
                  ): PlatformFuture[PlatformOutcome[StoreSession]] =
  openStore(bridge.volume, bridge.ownerId, bridge.persistenceGranted,
            bridge.persistenceAnswered, bridge.nowMs())

proc activateProject*(web: WebPlatform; projectId: string
                     ): PlatformFuture[PlatformOutcome[ProjectOpen]] =
  ## Take the writer role if it is free, discard anything §4.4 classifies as
  ## discardable, and make the project the one the filesystem facade addresses.
  thenOutcome(web.store.openProject(projectId, web.bridge.nowMs()),
    proc(opened: ProjectOpen): PlatformFuture[PlatformOutcome[ProjectOpen]] =
      web.activeProjectId = projectId
      if opened.role != wrOwner:
        # A read-only tab must not delete the writer's staging area or build
        # outputs. §4.4's "discarded on doubt" is the owner's decision.
        return resolvedOk(opened)
      mapOutcome(web.store.discardStaleWork(projectId),
        proc(ignored: Nothing): ProjectOpen = opened))

proc exportProjectArchive*(web: WebPlatform; projectId, suggestedName: string
                          ): PlatformFuture[PlatformOutcome[Nothing]] =
  ## §6.2's launch form of "your work leaves with you", end to end: walk the
  ## working tree, build the archive, hand it to the browser, and record that
  ## the project has now been exported so `exportWarning` stops escalating.
  let store = web.store
  let bridge = web.bridge
  thenOutcome(store.collectTree(projectId),
    proc(files: seq[TreeFile]): PlatformFuture[PlatformOutcome[Nothing]] =
      var entries: seq[ArchiveEntry] = @[]
      for file in files:
        entries.add ArchiveEntry(
          path: suggestedName & "/" & file.path,
          content: file.content,
          modifiedMs: bridge.nowMs())
      let built = buildArchive(entries)
      if not built.ok:
        return resolvedErr[Nothing](pkInvalidArgument, built.reason)
      mapOutcome(
        bridge.offerDownload(suggestedName & ".tar", built.bytes,
                             "application/x-tar"),
        proc(ignored: Nothing): Nothing =
          store.markExported(projectId)
          nothing))

proc install*(web: WebPlatform) =
  installPlatform(web.platform)
