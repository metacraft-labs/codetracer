---
id: TC-CTREE-JUMP-001
suite: CALL
title: Call Trace — frame jump navigates to correct source/time
type: manual
priority: P1
program: noir_space_ship
app: [desktop, web]
---
### Steps
- [ ] Double-click a non-leaf frame; observe Source and time cursor.
- [ ] Double-click a deeper leaf frame; observe again.

### Expected
- [ ] Source navigates to the frame’s file/line each time; time aligns to the call anchor.
