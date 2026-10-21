## agent_activity_settings_panel_view_test.nim
##
## #861: the Agent Activity settings panel must survive its own dropdowns.
##
## The settings panel's scroll container is `div.agent-settings-panel`.  A
## user who scrolls down to DELIVERY or PERMISSIONS and opens, closes or
## chooses from a dropdown must keep their scroll position, which a browser
## only keeps while the SAME element stays mounted: a freshly built
## replacement starts at `scrollTop = 0`.
##
## `codetracer-specs/Refactoring-Plans/ViewModel-Architecture.md` "5.
## UI-Specific ViewModel Layer" puts scroll position among a panel's
## presentation state, and `Refactoring-Plans/Shared-DOM-Front-Ends.md`
## "What the DOM front-ends do instead" (item 5) names the defect pattern:
## a view that rebuilds a subtree with `r.clearChildren` inside a
## `createRenderEffect`.  So every test here asserts node IDENTITY — the
## panel element captured when the panel opened is the very object still
## mounted under the host afterwards — and, beside it, that the changed value
## really is on screen (the dropdown list appears and disappears, the trigger
## shows the chosen value, the toggle's class flips).  Identity alone would
## also pass for a panel that stopped updating altogether.
##
## The interactions are driven through the panel's own `onclick` handlers
## wherever the user would click (`fireEvent`), and through the ViewModel's
## setters where the change arrives from elsewhere (the branch list, the
## model, "Reset to defaults").
##
## TEST DOUBLE JUSTIFICATION (workspace policy).  One collaborator is supplied
## by the test: `MockRenderer`, IsoNim's headless renderer and the standard
## vehicle for every view suite in this repository.  The production
## `WebRenderer` needs a browser; the view code is generic over the renderer,
## so the *same* `renderAgentActivityPanel` body — including the render
## effects whose subscriptions are the subject of this file — runs either
## way.  What the mock cannot show is the browser's `scrollTop` itself; it
## shows the precondition the browser needs to keep it (the element is not
## replaced).  The store's `MockBackendService` is only there because
## `createAgentActivityVM` needs a store; nothing here talks to a backend.

import std/[strutils, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom

import backend/mock_backend
import store/replay_data_store
import viewmodels/agent_activity_vm
import views/isonim_agent_activity_view

proc makeStore(): ReplayDataStore =
  createReplayDataStore(
    newMockBackendService(autoRespond = true).toBackendService())

proc hasClass(node: MockNode; cls: string): bool =
  ## Nil-safe, so a missing node fails a `check` instead of crashing the
  ## suite (which is what the red run against the unfixed view needs).
  node != nil and node.kind == mnkElement and
    cls in node.attributes.getOrDefault("class", "").split(' ')

proc findByClass(node: MockNode; cls: string): MockNode =
  ## First descendant (or self) carrying `cls` as a whole class word.
  if node == nil:
    return nil
  if node.hasClass(cls):
    return node
  for child in node.children:
    let found = findByClass(child, cls)
    if found != nil:
      return found
  nil

proc collectByClass(node: MockNode; cls: string; acc: var seq[MockNode]) =
  if node == nil:
    return
  if node.hasClass(cls):
    acc.add(node)
  for child in node.children:
    collectByClass(child, cls, acc)

proc allByClass(node: MockNode; cls: string): seq[MockNode] =
  collectByClass(node, cls, result)

proc sameNode(a, b: MockNode): bool =
  ## Reference identity, deliberately not structural equality: a rebuilt
  ## panel with identical content is exactly the defect.  `==` on a `ref` is
  ## identity in Nim (`===` under `nim js`) and `mock_dom` does not overload
  ## it; the unique `id` every `createElement` assigns says the same thing
  ## even if an overload ever appears.
  a != nil and b != nil and a.id == b.id and system.`==`(a, b)

proc mountedPanel(host: MockNode): MockNode =
  ## The `agent-settings-panel` element currently mounted under the host,
  ## or nil when the panel is closed.
  for child in host.children:
    if child.hasClass("agent-settings-panel"):
      return child
  nil

proc triggerText(wrapper: MockNode): string =
  let text = findByClass(wrapper, "agent-settings-select-text")
  if text == nil: "" else: text.textContent

# Every helper below that asserts is a TEMPLATE, not a proc.  A unittest
# `check` inside a plain proc sets the module-level status instead of the
# running test's, so the test reports [OK] under the printed failure.  As a
# template the `check` expands in the test body and fails that test.

template click(node: MockNode) =
  ## The user's click on `node`, through the handler the view attached.  A
  ## missing node is a failed check rather than a nil dereference.
  let target = node
  check target != nil
  if target != nil:
    target.fireEvent("click")

proc dropdownShowing(panel: MockNode; value: string): MockNode =
  ## The dropdown wrapper whose trigger currently shows `value`.  Found by
  ## the value rather than by position: the DOM order of the dropdowns is
  ## not what these tests are about.
  for wrapper in allByClass(panel, "agent-settings-select-wrapper"):
    if wrapper.triggerText == value:
      return wrapper
  nil

proc listOf(wrapper: MockNode): MockNode =
  findByClass(wrapper, "agent-settings-dropdown-list")

proc itemNamed(wrapper: MockNode; label: string): MockNode =
  let list = wrapper.listOf
  if list == nil:
    return nil
  for item in allByClass(list, "agent-settings-dropdown-item"):
    if item.textContent == label:
      return item
  nil

template clickTrigger(wrapper: MockNode) =
  click(findByClass(wrapper, "agent-settings-select-trigger"))

proc appCallbacks(vm: AgentActivityVM): AgentActivityCallbacks =
  ## The callback the app wires to the toolbar's settings button
  ## (`buildAgentActivityCallbacks` in `ui/agent_activity.nim`), so the tests
  ## open the panel through the same button the user clicks.
  AgentActivityCallbacks(onSettingsSelect: proc() = vm.toggleSettingsOpen())

template openSettings(vm: AgentActivityVM; root, host: MockNode): MockNode =
  ## Opens the panel with the toolbar's settings button and returns the panel
  ## element that was mounted.
  click(findByClass(root, "agent-settings-button"))
  check vm.settingsOpen.val
  let opened = mountedPanel(host)
  check opened != nil
  opened

suite "#861 the settings panel survives its own dropdowns":

  test "opening and closing a dropdown keeps the same settings panel mounted":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let root = renderAgentActivityPanel(r, vm, componentId = 861,
                                          callbacks = appCallbacks(vm))
      let host = findByClass(root, "agent-settings-host")
      check host != nil
      let panel = openSettings(vm, root, host)

      let mode = dropdownShowing(panel, "New branch")
      check mode != nil
      check mode.listOf == nil

      # Open "Mode" the way the user does: click its trigger.
      mode.clickTrigger()
      check vm.settingsActiveDropdown.val == "deliveryMode"
      check sameNode(mountedPanel(host), panel)
      check mode.listOf != nil
      check mode.itemNamed("Existing branch") != nil
      check mode.itemNamed("New branch").hasClass(
        "agent-settings-dropdown-item--active")

      # Opening another dropdown closes the first, still in place.
      let permissions = dropdownShowing(panel, "Ask before commands")
      check permissions != nil
      permissions.clickTrigger()
      check vm.settingsActiveDropdown.val == "permissions"
      check sameNode(mountedPanel(host), panel)
      check mode.listOf == nil
      check permissions.listOf != nil

      # A second click on the trigger closes it.
      permissions.clickTrigger()
      check vm.settingsActiveDropdown.val == ""
      check sameNode(mountedPanel(host), panel)
      check permissions.listOf == nil

      # A close from outside the dropdown (what the click-outside handler
      # does in the browser) is a write to the same signal.
      mode.clickTrigger()
      check mode.listOf != nil
      vm.settingsActiveDropdown.val = ""
      check sameNode(mountedPanel(host), panel)
      check mode.listOf == nil

      dispose()

  test "choosing an option keeps the same panel and shows the chosen value":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let root = renderAgentActivityPanel(r, vm, componentId = 862,
                                          callbacks = appCallbacks(vm))
      let host = findByClass(root, "agent-settings-host")
      let panel = openSettings(vm, root, host)

      let mode = dropdownShowing(panel, "New branch")
      check mode != nil
      mode.clickTrigger()
      let choice = mode.itemNamed("Existing branch")
      check choice != nil
      choice.click()

      check vm.settingsDeliveryMode.val == "Existing branch"
      check vm.settingsActiveDropdown.val == ""
      check sameNode(mountedPanel(host), panel)
      # The same wrapper now shows the chosen value, and its list is gone.
      check mode.triggerText == "Existing branch"
      check mode.listOf == nil

      # Reopened, the list marks the new value as the active one.
      mode.clickTrigger()
      check sameNode(mountedPanel(host), panel)
      check mode.itemNamed("Existing branch").hasClass(
        "agent-settings-dropdown-item--active")
      check not mode.itemNamed("New branch").hasClass(
        "agent-settings-dropdown-item--active")

      # Permission level, the panel's last section.
      mode.clickTrigger()
      let permissions = dropdownShowing(panel, "Ask before commands")
      check permissions != nil
      permissions.clickTrigger()
      permissions.itemNamed("Deny all").click()
      check vm.settingsPermissions.val == "Deny all"
      check sameNode(mountedPanel(host), panel)
      check permissions.triggerText == "Deny all"
      check permissions.listOf == nil

      dispose()

  test "toggling network access and changing other settings keeps the same panel":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let root = renderAgentActivityPanel(r, vm, componentId = 863,
                                          callbacks = appCallbacks(vm))
      let host = findByClass(root, "agent-settings-host")
      let panel = openSettings(vm, root, host)

      let toggle = findByClass(panel, "agent-settings-toggle")
      check toggle != nil
      check not toggle.hasClass("agent-settings-toggle--on")
      toggle.click()
      check vm.settingsNetworkAccess.val
      check sameNode(mountedPanel(host), panel)
      check sameNode(findByClass(panel, "agent-settings-toggle"), toggle)
      check toggle.hasClass("agent-settings-toggle--on")
      toggle.click()
      check not vm.settingsNetworkAccess.val
      check not toggle.hasClass("agent-settings-toggle--on")

      # CPU and Memory, written through the VM.
      let cpu = dropdownShowing(panel, "2 cores")
      let memory = dropdownShowing(panel, "4 GB")
      check cpu != nil
      check memory != nil
      vm.settingsCpu.val = "8 cores"
      vm.settingsMemory.val = "16 GB"
      check sameNode(mountedPanel(host), panel)
      check cpu.triggerText == "8 cores"
      check memory.triggerText == "16 GB"

      # The agent chip follows the selected model.
      let chip = findByClass(panel, "agent-settings-agent-chip")
      check chip != nil
      check chip.textContent == "Claude·Sonnet ×1"
      vm.setSelectedModel("Codex GPT5")
      check sameNode(mountedPanel(host), panel)
      check chip.textContent == "Codex GPT5 ×1"

      # The target branch defaults to the checked-out branch, and its list
      # offers the repository's branches.
      vm.setBranchState("feature/x", ["main", "feature/x", "dev"])
      check sameNode(mountedPanel(host), panel)
      let target = dropdownShowing(panel, "feature/x")
      check target != nil
      target.clickTrigger()
      check sameNode(mountedPanel(host), panel)
      check target.itemNamed("main") != nil
      check target.itemNamed("dev") != nil
      check target.itemNamed("feature/x").hasClass(
        "agent-settings-dropdown-item--active")
      target.itemNamed("dev").click()
      check vm.settingsDeliveryBranch.val == "dev"
      check sameNode(mountedPanel(host), panel)
      check target.triggerText == "dev"

      # A branch list that arrives while the target list is open redraws that
      # list, and only that list.
      target.clickTrigger()
      check target.itemNamed("release") == nil
      vm.setBranchState("feature/x", ["main", "feature/x", "dev", "release"])
      check sameNode(mountedPanel(host), panel)
      check target.itemNamed("release") != nil
      check target.itemNamed("dev").hasClass(
        "agent-settings-dropdown-item--active")
      target.clickTrigger()
      check target.listOf == nil

      # The Runtime select, the panel's first section.
      let runtime = dropdownShowing(panel, "devcontainer")
      check runtime != nil
      runtime.clickTrigger()
      runtime.itemNamed("Local shell").click()
      check vm.settingsRuntime.val == "Local shell"
      check sameNode(mountedPanel(host), panel)
      check runtime.triggerText == "Local shell"

      # The rest of the pane redrawing around the open panel (typing in the
      # prompt re-renders the toolbar; a turn starting swaps Send for Stop)
      # leaves it alone.
      vm.inputValue.val = "draft prompt"
      vm.isLoading.val = true
      vm.isLoading.val = false
      check sameNode(mountedPanel(host), panel)

      # "Reset to defaults" puts every value back, in place.
      findByClass(panel, "agent-settings-reset").click()
      check sameNode(mountedPanel(host), panel)
      check cpu.triggerText == "2 cores"
      check memory.triggerText == "4 GB"
      check target.triggerText == "feature/x"
      check runtime.triggerText == "devcontainer"
      check not toggle.hasClass("agent-settings-toggle--on")

      dispose()

  test "closing the panel removes it and reopening builds one with the current values":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let root = renderAgentActivityPanel(r, vm, componentId = 864,
                                          callbacks = appCallbacks(vm))
      let host = findByClass(root, "agent-settings-host")
      let first = openSettings(vm, root, host)

      let mode = dropdownShowing(first, "New branch")
      mode.clickTrigger()
      # "Done" closes the panel and any open dropdown with it.
      findByClass(first, "agent-settings-done").click()
      check not vm.settingsOpen.val
      check vm.settingsActiveDropdown.val == ""
      check mountedPanel(host) == nil
      check host.children.len == 0

      # A value changed while the panel is closed shows on reopening.
      vm.settingsPermissions.val = "Allow all"
      let second = openSettings(vm, root, host)
      check not sameNode(second, first)
      check dropdownShowing(second, "Allow all") != nil
      check dropdownShowing(second, "New branch").listOf == nil

      # The closed panel's handlers are gone with it: writes no longer
      # reach the detached tree.
      vm.settingsCpu.val = "1 core"
      check dropdownShowing(first, "1 core") == nil
      check dropdownShowing(second, "1 core") != nil

      dispose()
