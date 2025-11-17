# Ruby Space Ship Program Suite

Program-specific flows for the `ruby_space_ship` sample to complement the Noir coverage.

## RS-001 Event log and call trace across ruby control flow

- Suite: Program-specific (`ruby_space_ship`)
- Type: Functional, Regression
- Platform: Electron and Web (Browser: Chrome/Chromium, Firefox)
- Operating Systems: Fedora, Ubuntu
- Program: ruby_space_ship
- Preconditions:
  - Launch CodeTracer using the `ruby_space_ship` program.
  - Event Log and Call Trace panels are open.

### Steps and Expected Results
1. Jump to the first controller event (e.g., `engine_control`). — Event log highlights the event; Call Trace selects the matching frame; editor opens the associated Ruby file and line.
2. Expand a child call and jump. — Event log reflects the child event; call trace and editor stay synchronized.

## RS-002 Call trace search and reopen flow

- Suite: Program-specific (`ruby_space_ship`)
- Type: Reliability, Smoke
- Platform: Web (Browser: Chrome/Chromium, Safari)
- Operating Systems: macOS
- Program: ruby_space_ship
- Preconditions:
  - Launch CodeTracer using the `ruby_space_ship` program.
  - Call Trace panel is open.

### Steps and Expected Results
1. Search for `navigation`. — Search results list relevant frames.
2. Select a result to jump. — Editor navigates to the frame’s source; event log highlights the linked event.
3. Close the Call Trace panel, then reopen it from the menu. — Panel restores and preserves the last selection or reloads cleanly without errors.
