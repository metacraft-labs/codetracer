# Cross-Window Panel Transfer: Decision

## Decision: Context Menu "Send to Window" (not GL fork)

### Rationale

- GL dev branch v3 has not been published to npm and is maintained by a single developer
- HTML5 DnD across Electron BrowserWindows has known edge cases
  (drop events lost when crossing native window boundaries, intermittent
  failures on Wayland/X11 compositors)
- Context menu approach provides the same user-facing functionality with
  significantly less integration risk
- Can be upgraded to DnD later if GL v3 stabilises or if a GL fork is adopted

### User Flow

1. Right-click on any Golden Layout panel tab
2. "Send to Window" submenu appears listing all open windows (except the current one)
3. User selects a target window
4. The panel's config and component state are serialised
5. The panel is removed from the source window's GL instance
6. An Electron IPC message (`CODETRACER::panel-detach`) carries the serialised
   config to the main process, which forwards it to the target window
7. The target window receives `CODETRACER::panel-attach` and creates the panel
   in its own GL instance

### IPC Channels

| Channel                        | Direction         | Payload                                            |
|-------------------------------|-------------------|----------------------------------------------------|
| `CODETRACER::panel-detach`    | renderer -> main  | `{ targetWindowId, panelConfig, sessionId }`        |
| `CODETRACER::panel-attach`    | main -> renderer  | `{ panelConfig, sessionId }`                        |
| `CODETRACER::list-windows`    | renderer -> main  | (none)                                              |
| `CODETRACER::list-windows-reply` | main -> renderer | `{ windows: [{ id, title }] }`                    |

### Mixed-Session Support (M22)

When a panel is transferred between windows that belong to different replay
sessions, the panel carries its original `sessionId`. The target window routes
DAP events for that panel through the correct `ReplaySession` based on the
embedded session identifier rather than defaulting to `activeSessionIndex`.

### Future Evolution

- If GL v3 is published and stabilises, the DnD path can be revisited
- The IPC infrastructure implemented here remains useful regardless, since
  DnD would still need the same serialisation + remote-create logic
