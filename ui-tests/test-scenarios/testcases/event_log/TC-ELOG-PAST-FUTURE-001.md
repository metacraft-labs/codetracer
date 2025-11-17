---
id: TC-ELOG-PAST-FUTURE-001
suite: LOG
title: Event Log — past active, future grayed; current visibly selected
type: manual
priority: P1
program: agnostic
app: [desktop, web]
---
### Steps
- [ ] Open any trace and select an event mid-execution.
- [ ] Inspect events before and after current selection.
- [ ] Move to a later event, then back earlier; inspect styling changes.

### Expected
- [ ] Current event has a distinct selected style.
- [ ] Earlier events appear active/clickable; later events are **grayed**.
