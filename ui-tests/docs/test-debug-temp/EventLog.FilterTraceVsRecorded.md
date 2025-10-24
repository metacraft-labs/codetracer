# EventLog.FilterTraceVsRecorded

- **Test Id:** `EventLog.FilterTraceVsRecorded`
- **Current Status:** Blocked (keyboard shortcut gaps)
- **Last Attempt:** Not yet executed in this debugging session
- **Purpose:** Toggles the event log dropdown between “Trace events” and “Recorded events”, ensuring counts shrink and then restore as expected.
- **Notes:** Capture the dropdown DOM if it fails to close or if the row counts remain unchanged.

## Run Log

- 2025-10-23 15:36:46Z — Removed from `TestRegistry` because the Web runtime requires alternate shortcuts and our current Playwright chord dispatch is unreliable across platforms. Will revisit after shortcut infrastructure changes.
