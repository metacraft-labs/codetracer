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

import std/[options, strutils, unittest]
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

proc commandCount(mock: MockBackendService; command: string): int =
  ## Local helper — count how many times ``command`` appears in the
  ## mock's received-command log.  ``MockBackendService`` exposes
  ## ``findCommand`` (returns the first match) but no count API; the
  ## tests below need to assert "exactly one dispatch" so we provide
  ## the count locally rather than mutating the upstream module.
  for rc in mock.receivedCommands:
    if rc.command == command:
      inc result

proc makeTrace(id: int; program: string;
               args: seq[string] = @[];
               date: string = "2026/05/02 12:00:00";
               duration: string = "0.5s";
               workdir: string = "/tmp"): RecentTraceRecord =
  ## Convenience constructor used across the suites.
  ##
  ## M-REC-2: the ``id: int`` parameter is mapped into a stable canonical
  ## UUIDv7 (last 12 digits encode the integer) so existing call sites
  ## that pass small ints keep working unchanged.  Tests that need a
  ## specific UUIDv7 can construct the ``RecentTraceRecord`` directly.
  let suffix = align($id, 12, '0')
  RecentTraceRecord(
    id: "01949fcc-7d92-7e9c-aaaa-" & suffix,
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
      check vm.hoveredTrace.val == NO_HOVERED_TRACE
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
      check vm.loadingTraceId.val == NO_LOADING_TRACE
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
        makeTrace(1, "/usr/bin/python3", @["fib.py"]),
        makeTrace(2, "/usr/bin/ruby", @["app.rb"]),
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
      vm.setRecentTraces(@[makeTrace(1, "/a")])
      vm.addRecentTrace(makeTrace(2, "/b"))
      check vm.recentTraces.val.len == 2
      check vm.recentTraces.val[1].id == 2
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
    # Spec: "trace tooltip appears on hover" — hover sets hoveredTrace
    # to the trace id; leave clears it back to NO_HOVERED_TRACE.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setRecentTraces(@[makeTrace(7, "/p")])
      check vm.hoveredTrace.val == NO_HOVERED_TRACE

      vm.hoverTrace("01949fcc-7d92-7e9c-aaaa-000000000007")
      check vm.hoveredTrace.val == "01949fcc-7d92-7e9c-aaaa-000000000007"

      vm.clearHoveredTrace()
      check vm.hoveredTrace.val == NO_HOVERED_TRACE
      dispose()

  test "hover state survives panel switch but is reset on list refresh":
    # The legacy view re-renders the welcome panels on every redraw
    # but the hover state lives on the component instance and would
    # bleed between renders.  The VM keeps hoveredTrace stable across
    # mode toggles but resets it whenever the underlying list is
    # bulk-replaced (so a stale id cannot survive a list refresh).
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let trace1Id = "01949fcc-7d92-7e9c-aaaa-000000000001"
      vm.setRecentTraces(@[makeTrace(1, "/p")])
      vm.hoverTrace(trace1Id)
      vm.setMode(wsmNewRecord)
      check vm.hoveredTrace.val == trace1Id  # survives mode change
      vm.setRecentTraces(@[makeTrace(2, "/q")])
      check vm.hoveredTrace.val == NO_HOVERED_TRACE  # cleared on refresh
      dispose()

  test "click on recent trace dispatches load and flips loading":
    # Spec implication: clicking a recent trace shows the loading
    # overlay and dispatches the load command.  We verify the VM
    # flips ``loading`` true and stamps ``loadingTraceId`` so the
    # spec's ``.welcome-screen-loading`` modifier becomes visible
    # synchronously.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let trace42Id = "01949fcc-7d92-7e9c-aaaa-000000000042"
      vm.loadRecentTrace(trace42Id)
      drain()
      check vm.loading.val == true
      check vm.loadingTraceId.val == trace42Id
      check mock.commandCount("ct/load-recent-trace") == 1
      dispose()

  test "endLoading clears the overlay":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.beginLoadingTrace("01949fcc-7d92-7e9c-aaaa-000000000003")
      check vm.loading.val == true
      vm.endLoading()
      check vm.loading.val == false
      check vm.loadingTraceId.val == NO_LOADING_TRACE
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
      let (store, mock) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.loadRecentFolder("/home/u/fib")
      drain()
      check vm.mode.val == wsmEdit
      check vm.editMode.val == true
      check vm.launchConfig.val.editFolderPath == "/home/u/fib"
      check mock.commandCount("ct/load-recent-folder") == 1
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
    # the entry triggers the launch flow.  The VM dispatches one
    # ``ct/launch-config`` command on the backend.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setLaunchConfigs(@[
        makeLaunchEntry("ruby-fibonacci", "Ruby: Fibonacci",
                        "ruby", "examples/ruby/fib.rb"),
      ])
      vm.selectLaunchConfig("ruby-fibonacci")
      let dispatched = vm.launchSelectedConfig()
      drain()
      check dispatched == true
      check mock.commandCount("ct/launch-config") == 1
      dispose()

  test "launchSelectedConfig returns false with no selection":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setLaunchConfigs(@[
        makeLaunchEntry("ruby-fibonacci", "Ruby: Fibonacci",
                        "ruby", "examples/ruby/fib.rb"),
      ])
      let dispatched = vm.launchSelectedConfig()
      drain()
      check dispatched == false
      check mock.commandCount("ct/launch-config") == 0
      dispose()

  test "launchSelectedConfig refuses disabled entries":
    # Spec: "Launch config items are clickable" — the ``menu-enabled``
    # class is asserted on the parent.  A disabled entry must not
    # dispatch (the legacy view rendered it grayed out).
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setLaunchConfigs(@[
        makeLaunchEntry("python-fibonacci", "Python: Fibonacci",
                        "python", "examples/python/fib.py",
                        enabled = false),
      ])
      vm.selectLaunchConfig("python-fibonacci")
      let dispatched = vm.launchSelectedConfig()
      drain()
      check dispatched == false
      check mock.commandCount("ct/launch-config") == 0
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
      let (store, mock) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let dispatched = vm.submitNewRecord()
      drain()
      check dispatched == false
      check mock.commandCount("ct/new-record") == 0
      dispose()

  test "submitNewRecord dispatches when valid":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      vm.setRecordExecutable("/usr/bin/python3")
      vm.setRecordArgs(@["fib.py"])
      let dispatched = vm.submitNewRecord()
      drain()
      check dispatched == true
      check mock.commandCount("ct/new-record") == 1
      dispose()
