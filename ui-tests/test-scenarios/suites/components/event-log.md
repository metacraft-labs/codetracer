# Event Log Suite (Program-Agnostic)

Covers navigation, visual state, and cross-panel synchronization for the event log. Run on both Electron and Web builds; prefer Chromium for fast checks and include Firefox/Safari during regression.

## EL-001 Jump to event opens the correct editor location

- Suite: Event Log
- Type: Functional, Regression
- Platform: Electron and Web (Browser: Chrome/Chromium, Firefox, Safari)
- Operating Systems: Fedora, Ubuntu, macOS
- Program: Program-agnostic (run with `noir_space_ship` and spot-check with `ruby_space_ship`)
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Ensure the event log is visible and populated.

### Steps and Expected Results
1. Click an event tied to `iterate_asteroids` in the event log. — The row is highlighted as the active selection.
2. Use the jump control on that row. — The editor opens the associated file and caret at the event line; the event log retains the selection.
3. Repeat for a second event in another file. — Editor switches to the new file and line; event log updates the active row without stale highlights.

### Notes
- Map to automated coverage under the Editor navigation helpers when available.

## EL-002 Event timeline states (past, current, future)

- Suite: Event Log
- Type: Functional, Smoke
- Platform: Electron and Web (Browser: Chrome/Chromium)
- Operating Systems: Fedora, Ubuntu
- Program: Program-agnostic
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Step the timeline to populate past/current/future events.

### Steps and Expected Results
1. Identify the currently executing event. — It is marked active and selected with the expected styling.
2. Inspect earlier events. — They are marked as past/non-active but remain clickable.
3. Inspect future events. — They render as grayed/disabled until reached; attempted clicks do not move execution ahead.

## EL-003 Event log reflects editor-driven jumps

- Suite: Event Log
- Type: Integration, Regression
- Platform: Electron and Web (Browser: Chrome/Chromium, Firefox)
- Operating Systems: Fedora, macOS
- Program: Program-agnostic
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Open the editor and event log.

### Steps and Expected Results
1. From the editor, trigger a jump to a specific execution point (e.g., via gutter navigation). — The event log scrolls to and highlights the matching event.
2. Jump to a different line in the editor tied to another event. — The event log updates the active row and deselects the previous one.

## EL-004 Event log reacts to Call Trace jumps

- Suite: Event Log
- Type: Integration, Regression
- Platform: Electron and Web (Browser: Chrome/Chromium, Firefox)
- Operating Systems: Fedora, Ubuntu
- Program: Program-agnostic
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Open the Call Trace panel and Event Log.

### Steps and Expected Results
1. In Call Trace, select a function frame and use the jump action. — The event log scrolls to the corresponding event and marks it active.
2. Expand a child call, jump to it. — Event log updates to the child event; call trace and event log stay in sync.

## EL-005 Event log reacts to Program State variable history jumps

- Suite: Event Log
- Type: Integration, Regression
- Platform: Electron and Web (Browser: Chrome/Chromium)
- Operating Systems: Fedora, macOS
- Program: Program-agnostic
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Open the Program State panel; variable history is populated.

### Steps and Expected Results
1. In variable history, select a prior value and jump to that point. — Event log highlights the matching historical event.
2. Select a later value. — Event log updates to the future event; current selection changes accordingly.

## EL-006 Event log reacts to Omniscience Loop Control jumps

- Suite: Event Log
- Type: Integration, Regression
- Platform: Electron and Web (Browser: Chrome/Chromium)
- Operating Systems: Fedora, Ubuntu
- Program: Program-agnostic
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Omniscience loop controls are visible.

### Steps and Expected Results
1. Jump forward using loop control (e.g., next iteration). — Event log advances to the targeted future event and marks it active.
2. Jump backward. — Event log tracks back to the earlier event and updates styling; future events remain grayed out until revisited.

## EL-007 Jump reliability across repeated navigation

- Suite: Event Log
- Type: Reliability
- Platform: Electron and Web (Browser: Chrome/Chromium)
- Operating Systems: Fedora
- Program: Program-agnostic
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Event log contains at least 10 events.

### Steps and Expected Results
1. Perform 5 sequential jumps to different events. — Each jump lands on the correct editor location; event log selection updates without stale focus.
2. Rapidly jump back and forth between two events. — Selection toggles correctly; no missed updates or frozen UI.
