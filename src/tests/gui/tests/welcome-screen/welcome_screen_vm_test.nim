## welcome_screen_vm_test.nim
##
## Headless ViewModel tests for ``WelcomeScreenVM`` — the headless
## counterpart to the three GUI specs in ``welcome-screen/`` (Cluster
## B from ``.agents/gui-vm-test-pairing-audit.txt``):
##
##   - ``welcome_screen.spec.ts``  (7 tests) — recent-traces /
##     recent-folders / start-options / hover tooltip.
##   - ``edit_mode.spec.ts``       (4 tests) — edit-mode swap, no
##     welcome surface, layout panel becomes available.
##   - ``launch_config.spec.ts``  (10 tests) — Debug submenu /
##     Launch Configurations entries / clickable items / Python:
##     Fibonacci + Ruby: Fibonacci entries.
##
## Each suite below maps onto the corresponding spec at the file
## level (``WelcomeScreenVM — welcome_screen`` /
## ``WelcomeScreenVM — edit_mode`` / ``WelcomeScreenVM —
## launch_config``).  Within each suite the individual tests track
## the shape of the spec's assertions: they drive the same VM
## actions the GUI clicks would (``hoverTrace`` / ``setMode`` /
## ``selectLaunchConfig`` etc.) and assert on the resulting reactive
## signal flow.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/welcome-screen/welcome_screen_vm_test.nim
##
## (For both backends the test is picked up by ``just test-vm-native``
## and ``just test-vm-js`` automatically — the harness globs every
## ``*_test.nim`` under ``src/tests/gui/tests`` outside the
## explicitly-excluded ``integration/real_backend_test.nim`` /
## ``integration/language_smoke_test.nim`` paths.)
##
## That claim used to be false for the JS half, and this file was the proof:
## it imported ``src/common/trace_index`` for one suite about SQLite-backed
## recent *folders*, and that module's ``std/osproc`` import fails the JS
## compile outright with ``cannot export: quoteShell``. The whole file — 44
## cases that need nothing but ``MockBackendService`` — was therefore red on
## ``vm-js``. The suite that needed the database now lives in
## ``welcome_screen_recent_folders_test.nim``, which is native-only and says
## so; everything below runs on both backends again.

import std/[json, options, unittest]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/welcome_screen_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  ## Create a ``ReplayDataStore`` backed by ``MockBackendService``.
  ## ``autoRespond = true`` so dispatched commands resolve cleanly
  ## without polluting the call queue.
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

proc makeTrace(id: string; program: string;
               args: seq[string] = @[];
               date: string = "2026/05/02 12:00:00";
               duration: string = "0.5s";
               workdir: string = "/tmp"): RecentTraceRecord =
  ## Convenience constructor used across the suites.  M-REC-3:
  ## ``recordingId`` is a UUIDv7 string.  Tests that need a stable id
  ## pass a hand-crafted canonical-form UUIDv7 string.
  RecentTraceRecord(
    recordingId: id,
    program: program,
    args: args,
    workdir: workdir,
    date: date,
    duration: duration,
  )

proc makeFolder(id: int; name: string; path: string): RecentFolderRecord =
  RecentFolderRecord(id: id, name: name, path: path)

proc makeOption(name: string; inactive: bool = false):
    WelcomeStartOptionRecord =
  ## Build a start-option record using the same ``optionKey`` derivation
  ## the legacy view uses for its CSS class.  Keeps tests grep-able
  ## against ``frontend/ui/welcome_screen.nim``.
  WelcomeStartOptionRecord(
    key: optionKey(name),
    name: name,
    inactive: inactive,
  )

proc makeLaunchEntry(slug, label, language, program: string;
                    enabled: bool = true): LaunchConfigEntry =
  LaunchConfigEntry(
    slug: slug,
    label: label,
    language: language,
    program: program,
    enabled: enabled,
  )

type HostRecorder = ref object
  ## What the VM handed the HOST — which is where the welcome screen's four
  ## main-process flows go.
  ##
  ## These used to be asserted through ``MockBackendService``, because the VM
  ## dispatched ``ct/load-recent-trace`` / ``ct/load-recent-folder`` /
  ## ``ct/launch-config`` / ``ct/new-record`` as DAP commands. No engine in
  ## this repo implements any of the four (``backend/dap_dialect.md`` §7), and
  ## in production this VM's backend is a stub that resolves ``{}`` for
  ## everything — so those assertions were green while the flows reached
  ## nothing at all. Asserting on the seam asserts what actually arrives at
  ## the main process.
  recentTraces: seq[string]
  recentFolders: seq[string]
  launches: seq[LaunchConfigRequest]
  newRecords: seq[NewRecordRequest]

proc installRecorder(vm: WelcomeScreenVM): HostRecorder =
  ## Stand in for ``ui/welcome_screen.nim``'s ``installWelcomeVMCallbacks``.
  let rec = HostRecorder()
  vm.onLoadRecentTrace = proc(recordingId: string) =
    rec.recentTraces.add(recordingId)
  vm.onLoadRecentFolder = proc(folderPath: string) =
    rec.recentFolders.add(folderPath)
  vm.onLaunchConfig = proc(request: LaunchConfigRequest) =
    rec.launches.add(request)
  vm.onSubmitNewRecord = proc(request: NewRecordRequest) =
    rec.newRecords.add(request)
  rec

# ---------------------------------------------------------------------------
# WelcomeScreenVM defaults
# ---------------------------------------------------------------------------

suite "WelcomeScreenVM — defaults":

  test "every list signal starts empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      check vm.recentTraces.val.len == 0
      check vm.recentFolders.val.len == 0
      check vm.startOptions.val.len == 0
      dispose()

  test "hover signals start unset":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      check vm.hoveredRecording.val == NO_HOVERED_RECORDING
      check vm.hoveredOption.val == ""
      dispose()

  test "mode defaults to welcome and editMode false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      check vm.mode.val == wsmWelcome
      check vm.editMode.val == false
      dispose()

  test "loading overlay is hidden by default":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      check vm.loading.val == false
      check vm.loadingRecordingId.val == NO_LOADING_RECORDING
      dispose()

  test "launchConfig and newRecord start empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let lc = vm.launchConfig.val
      check lc.configs.len == 0
      check lc.selectedSlug == ""
      check lc.editFolderPath == ""
      let nr = vm.newRecord.val
      check nr.executable == ""
      check nr.args.len == 0
      check nr.defaultOutputFolder == true
      dispose()

  test "derived memos report empty state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      check vm.hasRecentTraces.val == false
      check vm.hasRecentFolders.val == false
      check vm.activeStartOptions.val.len == 0
      check vm.selectedLaunchConfig.val.isNone
      dispose()

# ---------------------------------------------------------------------------
# Spec 1: welcome-screen/welcome_screen.spec.ts
# ---------------------------------------------------------------------------

suite "WelcomeScreenVM — welcome_screen":

  test "recent traces section populates from setRecentTraces":
    # Spec: "recent traces section is visible" / "trace entries show
    # time ago format" — both rely on the recent-trace list signal
    # being populated and each entry exposing program / date.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let traces = @[
        makeTrace("01949fcc-7d92-7e9c-aaaa-000000000001","/usr/bin/python3", @["fib.py"]),
        makeTrace("01949fcc-7d92-7e9c-aaaa-000000000002","/usr/bin/ruby", @["app.rb"]),
      ]
      vm.setRecentTraces(traces)
      check vm.recentTraces.val.len == 2
      check vm.hasRecentTraces.val == true
      check vm.recentTraces.val[0].program == "/usr/bin/python3"
      check vm.recentTraces.val[0].date.len > 0
      dispose()

  test "addRecentTrace appends one entry":
    # Spec: a fresh recording shows up at the top of the list — the
    # bridge calls addRecentTrace per new trace announcement.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setRecentTraces(@[makeTrace("01949fcc-7d92-7e9c-aaaa-000000000001","/a")])
      vm.addRecentTrace(makeTrace("01949fcc-7d92-7e9c-aaaa-000000000002","/b"))
      check vm.recentTraces.val.len == 2
      check vm.recentTraces.val[1].recordingId == "01949fcc-7d92-7e9c-aaaa-000000000002"
      dispose()

  test "recent folders section populates from setRecentFolders":
    # Spec: "recent folders section is visible".
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setRecentFolders(@[
        makeFolder(1, "fib", "/home/u/fib"),
        makeFolder(2, "app", "/home/u/app"),
      ])
      check vm.recentFolders.val.len == 2
      check vm.hasRecentFolders.val == true
      dispose()

  test "start-options buttons populate from setStartOptions":
    # Spec: "welcome screen has start options buttons" — open folder /
    # record new trace / open local trace / open online trace.  The
    # spec only asserts on "folder" and "record" matches.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setStartOptions(@[
        makeOption("Open folder"),
        makeOption("Record new trace"),
        makeOption("Open local trace"),
        makeOption("Open online trace", inactive = true),
      ])
      check vm.startOptions.val.len == 4
      check vm.startOptions.val[0].key == "open-folder"
      check vm.startOptions.val[1].key == "record-new-trace"
      # The "Open online trace" option is inactive — activeStartOptions
      # filters it out so click handlers do not need to re-check the
      # flag.
      check vm.activeStartOptions.val.len == 3
      dispose()

  test "welcome start-option keys match legacy button actions":
    # These keys are the contract between the IsoNim welcome view and
    # ``WelcomeScreenComponent.triggerWelcomeStartOption``. A typo here makes
    # the visible button click but miss the legacy IPC/action path.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setStartOptions(@[
        makeOption("Record new trace"),
        makeOption("Open local trace"),
        makeOption("Open folder"),
      ])

      check vm.startOptions.val[0].key == "record-new-trace"
      check vm.startOptions.val[1].key == "open-local-trace"
      check vm.startOptions.val[2].key == "open-folder"
      dispose()

  test "trace tooltip becomes visible on hover and clears on leave":
    # Spec: "trace tooltip appears on hover" — hover sets hoveredRecording
    # to the trace id; leave clears it back to NO_HOVERED_RECORDING.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setRecentTraces(@[makeTrace("01949fcc-7d92-7e9c-aaaa-000000000007","/p")])
      check vm.hoveredRecording.val == NO_HOVERED_RECORDING

      vm.hoverTrace("01949fcc-7d92-7e9c-aaaa-000000000007")
      check vm.hoveredRecording.val == "01949fcc-7d92-7e9c-aaaa-000000000007"

      vm.clearHoveredTrace()
      check vm.hoveredRecording.val == NO_HOVERED_RECORDING
      dispose()

  test "hover state survives panel switch but is reset on list refresh":
    # The legacy view re-renders the welcome panels on every redraw
    # but the hover state lives on the component instance and would
    # bleed between renders.  The VM keeps hoveredRecording stable across
    # mode toggles but resets it whenever the underlying list is
    # bulk-replaced (so a stale id cannot survive a list refresh).
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setRecentTraces(@[makeTrace("01949fcc-7d92-7e9c-aaaa-000000000001","/p")])
      vm.hoverTrace("01949fcc-7d92-7e9c-aaaa-000000000001")
      vm.setMode(wsmNewRecord)
      check vm.hoveredRecording.val == "01949fcc-7d92-7e9c-aaaa-000000000001"  # survives mode change
      vm.setRecentTraces(@[makeTrace("01949fcc-7d92-7e9c-aaaa-000000000002","/q")])
      check vm.hoveredRecording.val == NO_HOVERED_RECORDING  # cleared on refresh
      dispose()

  test "click on recent trace dispatches load and flips loading":
    # Spec implication: clicking a recent trace shows the loading
    # overlay and dispatches the load command.  We verify the VM
    # flips ``loading`` true and stamps ``loadingRecordingId`` so the
    # spec's ``.welcome-screen-loading`` modifier becomes visible
    # synchronously.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let host = vm.installRecorder()
      vm.loadRecentTrace("01949fcc-7d92-7e9c-aaaa-00000000002a")
      drain()
      check vm.loading.val == true
      check vm.loadingRecordingId.val == "01949fcc-7d92-7e9c-aaaa-00000000002a"
      check host.recentTraces == @["01949fcc-7d92-7e9c-aaaa-00000000002a"]
      dispose()

  test "test_recent_trace_loading":
    # Verifies recent traces launch properly from welcome screen
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let host = vm.installRecorder()
      let recId = "01949fcc-7d92-7e9c-aaaa-000000000088"
      vm.setRecentTraces(@[makeTrace(recId, "/usr/bin/python3", @["test.py"])])
      vm.loadRecentTrace(recId)
      drain()
      check vm.loading.val == true
      check vm.loadingRecordingId.val == recId
      check host.recentTraces == @[recId]
      check store.session.val.debugSessionMode == completedReplay
      dispose()

  test "endLoading clears the overlay":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.beginLoadingTrace("01949fcc-7d92-7e9c-aaaa-000000000003")
      check vm.loading.val == true
      vm.endLoading()
      check vm.loading.val == false
      check vm.loadingRecordingId.val == NO_LOADING_RECORDING
      dispose()

# ---------------------------------------------------------------------------
# Spec 2: welcome-screen/edit_mode.spec.ts
# ---------------------------------------------------------------------------

suite "WelcomeScreenVM — edit_mode":

  test "enterEditMode flips mode and editMode flags":
    # Spec: "edit mode loads the main UI" — the welcome surface goes
    # away (``wsmEdit``) and ``editMode`` flips true so the legacy
    # bridge knows to mount the GoldenLayout main UI.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.enterEditMode("/tmp/project")
      check vm.mode.val == wsmEdit
      check vm.editMode.val == true
      check vm.launchConfig.val.editFolderPath == "/tmp/project"
      dispose()

  test "edit mode hides the welcome surface":
    # Spec: "edit mode does not show welcome screen" — when ``mode``
    # is ``wsmEdit`` the welcome-screen DOM is detached.  We mirror
    # this at the VM layer by asserting ``mode != wsmWelcome``.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.enterEditMode("/tmp/project")
      check vm.mode.val != wsmWelcome
      dispose()

  test "exitEditMode reverts to welcome and clears folder path":
    # Spec equivalent: leaving edit mode (cancel) returns to the
    # welcome surface and the folder path is cleared so a stale
    # value cannot bleed into the next session.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.enterEditMode("/tmp/project")
      vm.exitEditMode()
      check vm.mode.val == wsmWelcome
      check vm.editMode.val == false
      check vm.launchConfig.val.editFolderPath == ""
      dispose()

  test "loadRecentFolder pre-flips edit mode and dispatches":
    # Spec: clicking a recent folder swaps to edit mode immediately
    # so the GUI does not race the IPC roundtrip.  The legacy bridge
    # transitioned in the main process; the VM mirrors it locally.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let host = vm.installRecorder()
      vm.loadRecentFolder("/home/u/fib")
      drain()
      check vm.mode.val == wsmEdit
      check vm.editMode.val == true
      check vm.launchConfig.val.editFolderPath == "/home/u/fib"
      check host.recentFolders == @["/home/u/fib"]
      dispose()

  test "setMode keeps editMode consistent for non-edit modes":
    # The two flags are derived from one source of truth — flipping
    # to wsmNewRecord must turn editMode off, even when entering
    # from wsmEdit.  This guards against the "all three booleans"
    # fallthrough state the legacy ``method render`` allowed.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.enterEditMode("/tmp/p")
      vm.setMode(wsmNewRecord)
      check vm.editMode.val == false
      check vm.mode.val == wsmNewRecord
      dispose()

  test "showWelcome / showNewRecord / showOnlineTrace toggle the surface":
    # The three convenience wrappers map onto the spec's expectation
    # that the new-record / online-trace surfaces never co-exist with
    # the welcome surface and never carry an editMode=true flag.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)

      vm.showNewRecord()
      check vm.mode.val == wsmNewRecord
      check vm.editMode.val == false
      check vm.newRecord.val.executable == ""

      vm.showOnlineTrace()
      check vm.mode.val == wsmOnlineTrace

      vm.showWelcome()
      check vm.mode.val == wsmWelcome
      check vm.editMode.val == false
      dispose()

# ---------------------------------------------------------------------------
# Spec 3: welcome-screen/launch_config.spec.ts
# ---------------------------------------------------------------------------

suite "WelcomeScreenVM — launch_config":

  test "setLaunchConfigs populates the configs list":
    # Spec: "Launch Configurations submenu contains Python: Fibonacci"
    # and "Ruby: Fibonacci" — the VM owns the canonical list.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setLaunchConfigs(@[
        makeLaunchEntry("python-fibonacci", "Python: Fibonacci",
                        "python", "examples/python/fib.py"),
        makeLaunchEntry("ruby-fibonacci", "Ruby: Fibonacci",
                        "ruby", "examples/ruby/fib.rb"),
      ])
      check vm.launchConfig.val.configs.len == 2
      check vm.launchConfig.val.configs[0].slug == "python-fibonacci"
      check vm.launchConfig.val.configs[1].slug == "ruby-fibonacci"
      dispose()

  test "selectLaunchConfig sets the slug and selectedLaunchConfig memo":
    # Spec: "Launch config items are clickable" — clicking sets the
    # selection.  The selectedLaunchConfig memo recomputes
    # synchronously so the IsoNim view can highlight the active row.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setLaunchConfigs(@[
        makeLaunchEntry("python-fibonacci", "Python: Fibonacci",
                        "python", "examples/python/fib.py"),
        makeLaunchEntry("ruby-fibonacci", "Ruby: Fibonacci",
                        "ruby", "examples/ruby/fib.rb"),
      ])
      vm.selectLaunchConfig("ruby-fibonacci")
      check vm.launchConfig.val.selectedSlug == "ruby-fibonacci"
      let chosen = vm.selectedLaunchConfig.val
      check chosen.isSome
      check chosen.get.label == "Ruby: Fibonacci"
      check chosen.get.language == "ruby"
      dispose()

  test "selectLaunchConfig with empty slug clears the selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setLaunchConfigs(@[
        makeLaunchEntry("python-fibonacci", "Python: Fibonacci",
                        "python", "examples/python/fib.py"),
      ])
      vm.selectLaunchConfig("python-fibonacci")
      check vm.selectedLaunchConfig.val.isSome

      vm.selectLaunchConfig("")
      check vm.launchConfig.val.selectedSlug == ""
      check vm.selectedLaunchConfig.val.isNone
      dispose()

  test "setLaunchConfigs drops a stale selection when slug disappears":
    # Spec edge case: the list is refreshed and the previously
    # selected slug is no longer present.  The VM clears the
    # selection so the IsoNim view does not render a phantom
    # ``selected`` modifier.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setLaunchConfigs(@[
        makeLaunchEntry("python-fibonacci", "Python: Fibonacci",
                        "python", "examples/python/fib.py"),
        makeLaunchEntry("ruby-fibonacci", "Ruby: Fibonacci",
                        "ruby", "examples/ruby/fib.rb"),
      ])
      vm.selectLaunchConfig("ruby-fibonacci")
      vm.setLaunchConfigs(@[
        makeLaunchEntry("python-fibonacci", "Python: Fibonacci",
                        "python", "examples/python/fib.py"),
      ])
      check vm.launchConfig.val.selectedSlug == ""
      check vm.selectedLaunchConfig.val.isNone
      dispose()

  test "launchSelectedConfig dispatches when a slug is selected":
    # Spec: "Recording Ruby: Fibonacci produces a trace" — clicking
    # the entry triggers the launch flow.  The VM hands the host one
    # resolved ``LaunchConfigRequest``.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let host = vm.installRecorder()
      vm.setLaunchConfigs(@[
        makeLaunchEntry("ruby-fibonacci", "Ruby: Fibonacci",
                        "ruby", "examples/ruby/fib.rb"),
      ])
      vm.selectLaunchConfig("ruby-fibonacci")
      let dispatched = vm.launchSelectedConfig()
      drain()
      check dispatched == true
      check host.launches.len == 1
      check host.launches[0].slug == "ruby-fibonacci"
      # The slug→index translation the host IPC needs: sole entry, index 0.
      check host.launches[0].configIndex == 0
      dispose()

  test "native launch configs enter live MCR mode when native backend is installed":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let host = vm.installRecorder()
      vm.setRecordBackendAvailability(RecordBackendAvailability(
        nativeBackendInstalled: true,
        hostPlatform: rhpLinux,
      ))
      vm.setLaunchConfigs(@[
        makeLaunchEntry("c-app", "C app", "c", "examples/c/main.c"),
      ])
      vm.selectLaunchConfig("c-app")
      check vm.launchSelectedConfig()
      drain()
      check host.launches.len == 1
      check host.launches[0].recordBackend == "mcr"
      check host.launches[0].startsLive == true
      check host.launches[0].debugSessionMode == liveMcr
      check store.session.val.debugSessionMode == liveMcr
      dispose()

  test "loading a recent trace is replay mode only":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let host = vm.installRecorder()
      store.setSessionMode(liveMcr)
      vm.loadRecentTrace("018f25ea-3d65-7000-8000-000000000001")
      drain()
      check host.recentTraces == @["018f25ea-3d65-7000-8000-000000000001"]
      check store.session.val.debugSessionMode == completedReplay
      dispose()

  test "launchSelectedConfig returns false with no selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let host = vm.installRecorder()
      vm.setLaunchConfigs(@[
        makeLaunchEntry("ruby-fibonacci", "Ruby: Fibonacci",
                        "ruby", "examples/ruby/fib.rb"),
      ])
      let dispatched = vm.launchSelectedConfig()
      drain()
      check dispatched == false
      check host.launches.len == 0
      dispose()

  test "launchSelectedConfig refuses disabled entries":
    # Spec: "Launch config items are clickable" — the ``menu-enabled``
    # class is asserted on the parent.  A disabled entry must not
    # dispatch (the legacy view rendered it grayed out).
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let host = vm.installRecorder()
      vm.setLaunchConfigs(@[
        makeLaunchEntry("python-fibonacci", "Python: Fibonacci",
                        "python", "examples/python/fib.py",
                        enabled = false),
      ])
      vm.selectLaunchConfig("python-fibonacci")
      let dispatched = vm.launchSelectedConfig()
      drain()
      check dispatched == false
      check host.launches.len == 0
      dispose()

  test "setEditFolderPath updates the launch-config without changing mode":
    # Spec: ``test.use({ launchMode: "edit", editFolderPath: ... })``
    # — the fixture parameter must be observable from the VM but
    # changing it does not switch the welcome surface.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setEditFolderPath("/tmp/examples")
      check vm.launchConfig.val.editFolderPath == "/tmp/examples"
      check vm.mode.val == wsmWelcome
      dispose()

# ---------------------------------------------------------------------------
# WelcomeScreenVM — new-record form
#
# The new-record form is exercised indirectly by ``launch_config.spec.ts``'s
# "Recording Ruby: Fibonacci produces a trace" — the launch flow lands on
# the new-record-form / record path.  We cover the form here so the headless
# layer has a usable smoke for any future per-spec extension.
# ---------------------------------------------------------------------------

suite "WelcomeScreenVM — new_record_form":

  test "showNewRecord seeds the form with empty defaults":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.showNewRecord()
      check vm.mode.val == wsmNewRecord
      check vm.newRecord.val.executable == ""
      check vm.newRecord.val.args.len == 0
      check vm.newRecord.val.defaultOutputFolder == true
      dispose()

  test "setRecordExecutable / setRecordArgs / setRecordWorkDir update one field at a time":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setRecordExecutable("/usr/bin/python3")
      vm.setRecordArgs(@["fib.py", "--n", "10"])
      vm.setRecordWorkDir("/tmp/work")
      let form = vm.newRecord.val
      check form.executable == "/usr/bin/python3"
      check form.args == @["fib.py", "--n", "10"]
      check form.workDir == "/tmp/work"
      check form.defaultOutputFolder == true  # untouched
      dispose()

  test "setRecordOutputFolder flips defaultOutputFolder off":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setRecordOutputFolder("/tmp/output")
      check vm.newRecord.val.outputFolder == "/tmp/output"
      check vm.newRecord.val.defaultOutputFolder == false
      # Setting to empty re-enables the default.
      vm.setRecordOutputFolder("")
      check vm.newRecord.val.outputFolder == ""
      check vm.newRecord.val.defaultOutputFolder == true
      dispose()

  test "toggleDefaultOutputFolder flips the flag":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      check vm.newRecord.val.defaultOutputFolder == true
      vm.toggleDefaultOutputFolder()
      check vm.newRecord.val.defaultOutputFolder == false
      vm.toggleDefaultOutputFolder()
      check vm.newRecord.val.defaultOutputFolder == true
      dispose()

  test "isNewRecordValid requires an executable":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      check vm.isNewRecordValid == false
      vm.setRecordExecutable("/usr/bin/python3")
      check vm.isNewRecordValid == true
      dispose()

  test "submitNewRecord refuses an invalid form":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let host = vm.installRecorder()
      let dispatched = vm.submitNewRecord()
      drain()
      check dispatched == false
      check host.newRecords.len == 0
      dispose()

  test "submitNewRecord dispatches when valid":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let host = vm.installRecorder()
      vm.setRecordExecutable("/usr/bin/python3")
      vm.setRecordArgs(@["fib.py"])
      let dispatched = vm.submitNewRecord()
      drain()
      check dispatched == true
      check host.newRecords.len == 1
      check host.newRecords[0].executable == "/usr/bin/python3"
      check host.newRecords[0].args == @["fib.py"]
      dispose()

  test "native backend choices are shown only when native backend is installed":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setRecordExecutable("/tmp/main.c")
      vm.setRecordBackendAvailability(RecordBackendAvailability(
        nativeBackendInstalled: false,
        hostPlatform: rhpLinux,
      ))
      check vm.recordBackendOptions.val.len == 0
      check vm.showRecordBackendChoice.val == false
      check vm.newRecordSessionMode.val == completedReplay

      vm.setRecordBackendAvailability(RecordBackendAvailability(
        nativeBackendInstalled: true,
        hostPlatform: rhpLinux,
      ))
      check vm.showRecordBackendChoice.val == true
      check vm.recordBackendOptions.val.len == 2
      check vm.recordBackendOptions.val[0].backend == recordBackendMcr
      check vm.recordBackendOptions.val[1].backend == recordBackendRr
      check vm.newRecordSessionMode.val == liveMcr
      dispose()

  test "RR and TTD native choices record replay-only sessions":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let host = vm.installRecorder()
      vm.setRecordExecutable("/tmp/main.rs")
      vm.setRecordBackendAvailability(RecordBackendAvailability(
        nativeBackendInstalled: true,
        hostPlatform: rhpWindows,
      ))
      check vm.recordBackendOptions.val.len == 2
      check vm.recordBackendOptions.val[0].backend == recordBackendMcr
      check vm.recordBackendOptions.val[1].backend == recordBackendTtd

      vm.setRecordBackendChoice(recordBackendTtd)
      check vm.newRecordSessionMode.val == completedReplay
      check vm.submitNewRecord()
      drain()
      check host.newRecords.len == 1
      check host.newRecords[0].recordBackend == "ttd"
      check host.newRecords[0].startsLive == false
      check store.session.val.debugSessionMode == completedReplay
      dispose()

  test "macOS native recordings are always MCR live sessions":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setRecordExecutable("/tmp/app")
      vm.setRecordBackendAvailability(RecordBackendAvailability(
        nativeBackendInstalled: true,
        hostPlatform: rhpMacos,
      ))
      check vm.recordBackendOptions.val.len == 1
      check vm.showRecordBackendChoice.val == false
      check vm.newRecordSessionMode.val == liveMcr
      dispose()

  test "materialized recorders start live except blockchain-style recorders":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let host = vm.installRecorder()

      vm.setRecordExecutable("/tmp/fib.py")
      check vm.recordBackendOptions.val.len == 0
      check vm.newRecordSessionMode.val == liveMaterialized
      check vm.submitNewRecord()
      drain()
      check host.newRecords.len == 1
      check host.newRecords[0].recordBackend == "db"
      check host.newRecords[0].startsLive == true
      check store.session.val.debugSessionMode == liveMaterialized

      vm.setRecordExecutable("/tmp/contract.sol")
      check vm.newRecordSessionMode.val == completedReplay
      check vm.submitNewRecord()
      drain()
      # The second submit appends rather than replacing, so indexing [1] is
      # also an assertion that the first one was not re-delivered.
      check host.newRecords.len == 2
      check host.newRecords[1].recordBackend == "db"
      check host.newRecords[1].startsLive == false
      check store.session.val.debugSessionMode == completedReplay
      dispose()
