# Noir Space Ship Program Suite

Program-specific flows for the `noir_space_ship` sample. These scenarios combine multiple components and rely on the program’s domain behaviors.

## NS-001 Flow loop slider appears after iterating asteroids

- Suite: Program-specific (`noir_space_ship`)
- Type: Functional, Regression
- Platform: Electron and Web (Browser: Chrome/Chromium)
- Operating Systems: Fedora, Ubuntu
- Program: noir_space_ship
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Call Trace and Event Log panels are open.

### Steps and Expected Results
1. In Call Trace, select the `iterate_asteroids` call (or jump to `shield.nr:14`). — Omniscience flow loop slider renders within the loop control panel.
2. Scrub the slider to a later iteration. — Event log advances to the matching event; editor shows the corresponding code line.
3. Scrub back to an earlier iteration. — Event log and editor rewind; Call Trace highlights the earlier frame.

## NS-002 Event log and call trace stay aligned across rapid loop jumps

- Suite: Program-specific (`noir_space_ship`)
- Type: Reliability
- Platform: Electron and Web (Browser: Chrome/Chromium, Firefox)
- Operating Systems: Fedora
- Program: noir_space_ship
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Flow loop slider is visible (see NS-001).

### Steps and Expected Results
1. Use the loop control to jump forward through at least five iterations in sequence. — Call Trace and Event Log move together without lag or stale highlights.
2. Rapidly jump backward twice, then forward once. — Both panels resync to the selected iteration; editor reflects the same call site each time.

## NS-003 Call trace search identifies asteroid processing functions

- Suite: Program-specific (`noir_space_ship`)
- Type: Functional
- Platform: Web (Browser: Chrome/Chromium, Firefox, Safari)
- Operating Systems: macOS
- Program: noir_space_ship
- Preconditions:
  - Launch CodeTracer using the `noir_space_ship` program.
  - Call Trace panel is open with populated frames.

### Steps and Expected Results
1. Search for `process_asteroid`. — Results include the asteroid processing frame(s).
2. Select the result. — Call Trace focuses the frame and editor jumps to the handler; event log highlights the associated event.
