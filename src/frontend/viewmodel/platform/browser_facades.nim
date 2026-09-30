## The three facades a BROWSER TAB answers — clipboard, downloads and the
## shell — built over a bridge and over nothing else.
##
## ## Why these three are a module of their own
##
## `Architecture/UI-Bundle-And-Endpoints.md` §6.6: "a facade operation whose
## subject is the BROWSER TAB is answered by the client, not sent". Sixteen of
## the facade's operations have that subject — all three `clipboard.*`, all
## five `download.*` and all eight `shell.*` — and a process in a container has
## no clipboard and no window, so a deployment that sends them asks a server to
## do something it has no means to do.
##
## Two deployments are a tab: the web build and the container build. Before
## this module the implementations lived inside `web_platform.nim`, which is
## also the project store, the OPFS volume, the wasm registry and the
## `installedRegistry` global. Reaching them from `host/container_platform.nim`
## would have dragged all of that into a bundle that has a container filesystem
## instead — so the alternative on offer was a second copy of the three
## builders, which is precisely the drift §6.6 argues against one level up
## ("it reuses them rather than growing a second copy — which is the same
## argument §5.1 makes about the facade contract").
##
## So the builders moved down here, `web_platform.newWebPlatform` calls the
## same ones it always did, and there is exactly one implementation of each.
##
## ## Why the bridge SPLIT rather than moved whole
##
## `BrowserBridge` was the obvious thing to move with them, and it is not what
## happened. It carries seven fields the three facades never touch — the store
## volume, the two persistence answers, the owner id, the clock, the share
## origin and the `WasmHost` — and it is `{.requiresInit.}`, deliberately, so
## that a field added to it fails the build at every construction site rather
## than defaulting to `nil` in a user's tab.
##
## Moving it whole would have made a container caller name all seven. There is
## no project store in a container deployment and no wasm host in it either:
## the filesystem is the container's and the processes are the container's. The
## caller would have had to invent a `StoreVolume` to satisfy a pragma, which
## is a fake value standing where a true one is impossible — and `requiresInit`
## exists to stop exactly that.
##
## `BrowserTabBridge` below is therefore the *tab operations*, which is what
## both deployments genuinely share, and `web_platform.BrowserBridge` keeps the
## seven web-only facts plus a `tab` field. The pragma still bites in both
## places, one field-set each, and neither deployment declares anything it does
## not have.

import ./outcome
import ./capabilities
import ./clipboard
import ./download
import ./shell

export clipboard, download, shell

type
  BrowserTabBridge* {.requiresInit.} = ref object
    ## Everything a browser TAB supplies that the three facades below need,
    ## and nothing else.
    ##
    ## `{.requiresInit.}` for the reason the seven facade types carry it: an
    ## operation added here must fail the build at `host/web_browser.nim`, at
    ## whatever wires the container deployment's tab, and at every test that
    ## builds one — rather than defaulting to `nil` and crashing in a user's
    ## tab.
    writeClipboardText*: proc(text: string
                             ): PlatformFuture[PlatformOutcome[Nothing]]
    writeClipboardHtml*: proc(html, plainText: string
                             ): PlatformFuture[PlatformOutcome[Nothing]]
    offerDownload*: proc(suggestedName: string; content: seq[byte];
                         mimeType: string
                        ): PlatformFuture[PlatformOutcome[Nothing]]
    pickFiles*: proc(options: OpenDialogOptions
                    ): PlatformFuture[PlatformOutcome[seq[string]]]
      ## The File System Access API's `showOpenFilePicker`. On the web build
      ## the returned strings are store paths of the *imported copies*, not
      ## host paths — Noir-Studio.md §4.2's "opening work from elsewhere goes
      ## through the import path (upload or a shared link) rather than a path
      ## box". A container deployment's tab answers with whatever its own
      ## import path produces; the facade does not care which, and that is the
      ## point of the seam.
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

  TabVerb* = object
    ## One row of the table below: a facade operation whose subject is the tab,
    ## the capabilities it would serve, and whether the facades this module
    ## builds actually answer it.
    verb*: string
    serves*: CapabilitySet
    answered*: bool

const browserTabVerbs*: seq[TabVerb] = @[
  # The sixteen, and what each of them is evidence for.
  #
  # This is the client-side twin of `index/facade_endpoint.nim`'s
  # `facadeVerbs`, and the capability attributions are deliberately the SAME
  # ones — `clipboard.readText` is `capClipboardRead` on both sides, and
  # `shell.windowState` is evidence for nothing on both sides. The two tables
  # are read by `servedCapabilities` and `browserTabCapabilities`, which are
  # the same computation; if they disagreed about what a verb serves, the
  # union in `host/container_platform.nim` would be a union of two different
  # vocabularies.
  #
  # **`answered` is not a second source of truth — it is checked against the
  # facades.** `test_container_tab_facades.nim` drives every row through the
  # facade this module builds and requires an `answered: false` row to refuse
  # with `pkNotSupported` and an `answered: true` row not to. A table that
  # drifted from the builders below fails there rather than quietly widening
  # the profile.
  TabVerb(verb: "clipboard.writeText", serves: {capClipboardWrite},
          answered: true),
  TabVerb(verb: "clipboard.readText", serves: {capClipboardRead},
          answered: false),
    # Reading needs a permission the product does not ask for — the same
    # refusal the web instantiation has always made, and `webProfile`'s
    # degradation sentence says paste is handled by the browser's own paste
    # event.
  TabVerb(verb: "clipboard.writeHtml", serves: {capClipboardWrite},
          answered: true),

  TabVerb(verb: "download.offerFile", serves: {capDownloadFile},
          answered: true),
  TabVerb(verb: "download.offerText", serves: {capDownloadFile},
          answered: true),
  TabVerb(verb: "download.openFileDialog", serves: {capOpenFileDialog},
          answered: true),
  TabVerb(verb: "download.saveFileDialog", serves: {capSaveFileDialog},
          answered: true),
  TabVerb(verb: "download.pickDirectory", serves: {capDirectoryPicker},
          answered: true),
    # "Answered" means the FACADE hands the question to the tab, not that
    # every bridge says yes: `host/web_browser.nim`'s picker refuses by name
    # today because import is a store operation NS6 owns. That refusal is a
    # property of one bridge; this table is about which side of the wire the
    # question goes to, which is what §6.6 is about and what the profile has
    # to follow.

  TabVerb(verb: "shell.openExternalUrl", serves: {capOpenExternalUrl},
          answered: true),
  TabVerb(verb: "shell.revealInFileManager", serves: {capRevealInFileManager},
          answered: false),
  TabVerb(verb: "shell.windowState", serves: {}, answered: true),
    # Evidence for nothing, exactly as the server's table has it: a tab can
    # always say whether it is focused, and that is not a capability anyone
    # gates a button on.
  TabVerb(verb: "shell.minimizeWindow", serves: {capWindowControls},
          answered: false),
  TabVerb(verb: "shell.toggleMaximizeWindow", serves: {capWindowControls},
          answered: false),
  TabVerb(verb: "shell.closeWindow", serves: {capWindowControls},
          answered: false),
  TabVerb(verb: "shell.setFullscreen", serves: {capWindowFullscreen},
          answered: true),
  TabVerb(verb: "shell.openSessionWindow", serves: {capMultiWindow},
          answered: false)]

proc browserTabCapabilities*(table: seq[TabVerb] = browserTabVerbs
                            ): CapabilitySet =
  ## What the tab genuinely supplies: evidenced by an answered verb, and owed
  ## by no refused one.
  ##
  ## The subtraction is the half that matters, and it is the same argument
  ## `index/facade_endpoint.servedCapabilities` makes: "at least one answered
  ## verb" alone would advertise `capWindowControls` off `shell.windowState`
  ## while three of the four window verbs refused — a capability that answers
  ## "may I" with yes and the call with `pkNotSupported`, which is precisely
  ## the disagreement `capabilities.nim` exists to prevent.
  ##
  ## **The table is a PARAMETER for the reason the server's is.** With the
  ## shipping table the subtraction is not inert — `capWindowControls` is owed
  ## three times and evidenced never — but a suite can still hand in a table
  ## with the overlap the other way and watch a capability go, which is the
  ## only way to assert the second half rather than assume it.
  var evidenced: CapabilitySet = {}
  var owed: CapabilitySet = {}
  for entry in table:
    if entry.answered: evidenced = evidenced + entry.serves
    else: owed = owed + entry.serves
  evidenced - owed

proc withBrowserTab*(served: PlatformProfile;
                     tabCapabilities: CapabilitySet = browserTabCapabilities()
                    ): PlatformProfile =
  ## §6.3 as §6.6 refines it: the platform's profile is the UNION of what the
  ## server serves and what the tab supplies.
  ##
  ## "`welcome.profile` is what the SERVER serves, and it is not the whole
  ## platform: the capabilities the tab supplies are not the server's to
  ## declare and not its to withhold." A client that took `welcome.profile` as
  ## the final answer would present a platform with no clipboard while sitting
  ## in a browser that has one.
  ##
  ## **The degradations have to move with it, and only in one direction.** A
  ## union only ADDS capabilities, so nothing can become newly unexplained —
  ## but a rule the server wrote for something it withdrew ("copying is your
  ## browser's own … there is no Copy item here") describes a platform that no
  ## longer exists the moment the tab supplies it. That is `staleDegradations`,
  ## and `capabilities.nim` says why it is checked at all: "a rule that
  ## survives the day its capability lands quietly misinforms". So every rule
  ## whose capability the union now has is dropped, and every other rule is
  ## kept verbatim — including the server's own reasons for the things neither
  ## side has.
  result = served
  result.capabilities = served.capabilities + tabCapabilities
  result.degradations = @[]
  for rule in served.degradations:
    if rule.capability notin result.capabilities:
      result.degradations.add rule

proc buildBrowserClipboard*(bridge: BrowserTabBridge;
                            profile: PlatformProfile): ClipboardFacade =
  ClipboardFacade(
    profile: profile,
    writeText: proc(text: string): PlatformFuture[PlatformOutcome[Nothing]] =
      bridge.writeClipboardText(text),
    readText: proc(): PlatformFuture[PlatformOutcome[string]] =
      # `capClipboardRead` is absent from every tab profile: reading needs a
      # permission the product does not ask for. The degradation sentence the
      # profile carries says paste is handled by the browser's own paste
      # event, which is why this is a refusal rather than a prompt.
      resolvedUnsupported[string]("reading the clipboard"),
    writeHtml: proc(html, plainText: string
                   ): PlatformFuture[PlatformOutcome[Nothing]] =
      bridge.writeClipboardHtml(html, plainText))

proc buildBrowserDownload*(bridge: BrowserTabBridge;
                           profile: PlatformProfile): DownloadFacade =
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

proc buildBrowserShell*(bridge: BrowserTabBridge;
                        profile: PlatformProfile): ShellFacade =
  ShellFacade(
    profile: profile,
    openExternalUrl: proc(url: string
                         ): PlatformFuture[PlatformOutcome[Nothing]] =
      # The allow-list belongs HERE and not only in the bridge, because the
      # bridge is pluggable: this is the `ShellFacade` handed to callers, and a
      # bridge that forgot the check would inherit nothing.  Measured —
      # `test_platform_web.nim`'s fake bridge accepted `javascript:` right
      # through a guard that was only in `host/web_browser.nim`.
      #
      # The container deployment is a THIRD bridge, wired by whoever opens the
      # endpoint, and it is the reason this guard had to travel with the
      # builder rather than stay in `web_platform.nim`: a per-deployment bridge
      # is exactly a place for the check to be forgotten again.
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
