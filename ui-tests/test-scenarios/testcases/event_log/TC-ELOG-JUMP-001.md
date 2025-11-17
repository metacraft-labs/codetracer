---
id: TC-ELOG-JUMP-001
suite: LOG
title: Event Log — clicking a row jumps to the correct source/time
type: manual
priority: P1
program: noir_space_ship
app: [desktop, web]
os: [ubuntu, fedora, nixos, macos]
browsers: [chrome, chromium, firefox, safari]
preconditions:
  - A recorded trace for noir_space_ship exists with ≥ 10 events across ≥ 2 files.
---
### Steps
- [ ] Launch CodeTracer using the **noir_space_ship** program.
- [ ] Open the recorded trace.
- [ ] In **Event Log**, click an event known to map to a file different from the currently open file.
- [ ] Observe the **Source** panel and **time cursor**.
- [ ] Click a second event from another file; observe again.

### Expected
- [ ] Editor switches to the correct file/tab and line for each clicked event.
- [ ] Time cursor aligns to the event timestamp/frame.
- [ ] Clicked row is highlighted as **active/selected**.
- [ ] Past events remain active; future events are **grayed out** relative to current time.

### Evidence
- [ ] Screenshot of Event Log + Source alignment.
