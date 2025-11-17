---
id: TC-ELOG-EDITOR-001
suite: LOG
title: Event Log — jump opens correct editor tab (multi-file)
type: manual
priority: P1
program: noir_space_ship
app: [desktop, web]
---
### Steps
- [ ] Launch CodeTracer using **noir_space_ship**; open a multi-file trace.
- [ ] Click an event from file A, then an event from file B.

### Expected
- [ ] Active tab switches to file A then file B; caret is at the correct line/expression each time.
