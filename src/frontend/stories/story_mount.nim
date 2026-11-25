## Mounting a declared story through any IsoNim renderer.
##
## A story is a ViewModel state built on the stand-in backend
## (`story_fixtures`) under a production view. StoryBook mounts it through
## `WebRenderer` (`storybook_components.mountCodeTracerStory`); the native
## story hosts mount the same story, through the same procs here, with their
## own renderer, so every renderer draws the same state with the same view
## code. Only the renderer differs.

import isonim/rxcore
import isonim/viewmodel
import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

import ../viewmodel/store/[replay_data_store, types]
import ../viewmodel/viewmodels/[agent_activity_vm, build_vm, calltrace_vm,
  command_palette_vm, errors_vm, event_log_vm, filesystem_vm, low_level_code_vm,
  repl_vm, scratchpad_vm, search_results_vm, state_vm, terminal_output_vm,
  trace_log_vm]
import ../viewmodel/views/[isonim_agent_activity_view, isonim_build_view,
  isonim_calltrace_view, isonim_command_palette_view, isonim_errors_view,
  isonim_event_log_view, isonim_filesystem_view, isonim_low_level_code_view,
  isonim_repl_view, isonim_scratchpad_view, isonim_search_results_view,
  isonim_state_view, isonim_terminal_output_view, isonim_trace_log_view]
import ./story_fixtures

# A view instantiated through these procs is instantiated where they are
# called, and the `ui` macro's expansion names `createRenderEffect` and the
# control-flow components there, as the views themselves note: exported, as
# the views export them, so a host needs no IsoNim import of its own.
export signals, computation, components, ui

type StoryDispose* = proc()

proc withStore(body: proc(store: ReplayDataStore): StoryDispose): StoryDispose =
  ## Runs `body` in a reactive root over a fresh story store, as
  ## `storybook_components.mountWithStore` does.
  var rootDisposer: proc()
  var store: ReplayDataStore
  var vmDisposer: StoryDispose
  createRoot proc(dispose: proc()) =
    rootDisposer = dispose
    store = makeStore()
    vmDisposer = body(store)
  result = proc() =
    if vmDisposer != nil: vmDisposer()
    if store != nil: store.dispose()
    if rootDisposer != nil: rootDisposer()

const nativePanelSurfaces* = ["event-log", "calltrace", "state", "filesystem",
  "scratchpad", "agent-activity", "build",
  "command-palette"]
  ## The panel surfaces `mountPanelStory` mounts, each as
  ## `storybook_components.mountCodeTracerStory` mounts it for the DOM.

template panelStory(r, container, createVm, applyFixture, renderCall: untyped): StoryDispose =
  ## A story store, the pane's ViewModel on it with the fixture applied
  ## (`applyFixture`, which names it `vm`), and its view appended.
  withStore(proc(store: ReplayDataStore): StoryDispose =
    let vm {.inject.} = createVm(store)
    applyFixture
    r.appendChild(container, renderCall)
    result = proc() = vm.dispose())

proc mountPanelStory*[R, N](r: R; container: N; surface, fixture: string): StoryDispose =
  ## Mounts the panel story `surface` / `fixture` into `container`, with the
  ## fixture applied as the StoryBook mount applies it.
  case surface
  of "event-log":
    panelStory(r, container, createEventLogVM):
      if fixture == "loading": vm.loadingState.val = lsLoading
      else: vm.applyEventLog()
    do: renderEventLogPanel[R, N](r, vm)
  of "calltrace":
    panelStory(r, container, createCalltraceVM):
      if fixture != "empty": vm.applyCalltrace()
    do: renderCalltracePanel[R, N](r, vm)
  of "state":
    withStore(proc(store: ReplayDataStore): StoryDispose =
      let vm = createStateVM(store)
      if fixture == "empty": store.applyEmptyState()
      else: vm.applyState()
      store.locals.loadingState.val = lsIdle
      r.appendChild(container, renderStatePanel[R, N](r, vm))
      store.locals.loadingState.val = lsIdle
      result = proc() = vm.dispose())
  of "filesystem":
    panelStory(r, container, createFilesystemVM):
      if fixture != "empty": vm.applyFilesystem()
    do: renderFilesystemPanel[R, N](r, vm)
  of "scratchpad":
    panelStory(r, container, createScratchpadVM):
      if fixture != "empty": vm.applyScratchpad()
    do: renderScratchpadPanel[R, N](r, vm)
  of "agent-activity":
    panelStory(r, container, createAgentActivityVM):
      if fixture != "empty": vm.applyAgentActivity()
      if fixture == "reference": vm.setTerminals(@[])
      if fixture == "loading": vm.setLoading(true)
    do: renderAgentActivityPanel[R, N](r, vm, 101, "storybook-agent-input")
  of "build":
    panelStory(r, container, createBuildVM):
      vm.applyBuild(fixture)
    do: renderBuildPanel[R, N](r, vm)
  of "command-palette":
    panelStory(r, container, createCommandPaletteVM):
      if fixture != "empty": vm.applyCommandPalette()
    do: renderCommandPalettePanel[R, N](r, vm)
  else:
    raise newException(ValueError, "no native mount for the panel story " & surface)
