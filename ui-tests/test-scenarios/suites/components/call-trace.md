# Call Trace Suite (Program-Agnostic)

Covers navigation, expansion, search, and cross-panel synchronization. Run on both Electron and Web; prioritize Chromium for smoke and add Firefox/Safari for regression.

## CT-001 Collapse and expand child calls

- Suite: Call Trace
- Type: Functional, Smoke
- Platform: Electron and Web (Browser: Chrome/Chromium)
- Operating Systems: Fedora, Ubuntu
- Program: Program-agnostic
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Open the Call Trace panel.

### Steps and Expected Results
1. Expand a parent frame with multiple children. — Children render in order beneath the parent.
2. Collapse the parent. — Child entries hide without altering selection state.
3. Re-expand the parent. — Previously visible children return; selection remains stable.

## CT-002 Jump from Call Trace updates editor and event log

- Suite: Call Trace
- Type: Integration, Regression
- Platform: Electron and Web (Browser: Chrome/Chromium, Firefox)
- Operating Systems: Fedora, macOS
- Program: Program-agnostic
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Event Log and Call Trace panels are open.

### Steps and Expected Results
1. Select a frame and trigger jump. — Editor opens the associated file/line; event log highlights the matching event.
2. Expand a child frame and jump. — Editor navigates to the child call site; event log updates to the new event.

## CT-003 Context menu actions on function names

- Suite: Call Trace
- Type: Functional, Regression
- Platform: Electron and Web (Browser: Chrome/Chromium)
- Operating Systems: Fedora, Ubuntu
- Program: Program-agnostic
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Call Trace panel is open with expandable frames.

### Steps and Expected Results
1. Open the context menu on a function entry. — Menu displays options including `Collapse call children` and `Expand full callstack`.
2. Choose `Collapse call children`. — The selected entry’s children collapse; parent remains selected.
3. Re-open the context menu and choose `Expand full callstack`. — All frames expand down to the deepest child.

## CT-004 Search and jump via results

- Suite: Call Trace
- Type: Functional, Regression
- Platform: Web (Browser: Chrome/Chromium, Firefox, Safari); Electron (where supported)
- Operating Systems: Fedora, macOS
- Program: Program-agnostic
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Call Trace panel is open; search box is visible.

### Steps and Expected Results
1. Enter a function name in the search box and press Enter. — Search results list appears with matching frames.
2. Click a search result. — Call Trace focuses that frame; editor jumps to the related source location.

## CT-005 Call Trace reflects Event Log jumps

- Suite: Call Trace
- Type: Integration, Regression
- Platform: Electron and Web (Browser: Chrome/Chromium)
- Operating Systems: Fedora
- Program: Program-agnostic
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Event Log and Call Trace panels are open.

### Steps and Expected Results
1. Jump to an event from the event log. — Call Trace scrolls to the frame that produced the event and highlights it.
2. Jump to a later event. — Call Trace updates to the new frame; previous selection clears.

## CT-006 Call Trace reflects Omniscience Loop Control jumps

- Suite: Call Trace
- Type: Integration, Regression
- Platform: Electron and Web (Browser: Chrome/Chromium)
- Operating Systems: Fedora, Ubuntu
- Program: Program-agnostic
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Call Trace panel and loop controls are open.

### Steps and Expected Results
1. Jump forward using loop controls. — Call Trace selection advances to the corresponding call frame; expansion state persists.
2. Jump backward. — Call Trace selection moves to the earlier frame; no stale highlights remain.

## CT-007 Panel lifecycle (open/close)

- Suite: Call Trace
- Type: Reliability, Smoke
- Platform: Electron and Web (Browser: Chrome/Chromium)
- Operating Systems: Fedora
- Program: Program-agnostic
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.

### Steps and Expected Results
1. Close the Call Trace panel. — Panel disappears; other panels stay intact.
2. Re-open Call Trace from the menu. — Panel restores with previous state or a clean default view; no crashes or missing controls.
