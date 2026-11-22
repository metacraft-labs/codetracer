## overlay_rows.nim — the keys of the overlays every base shares: the program
## menu, a shown text (an event's content), the terminal's information dialog,
## and the Terminal Output pane's and the Video Player's own keys.
##
## Owns: those rows as data (Input-Routing §4.3: no binding is installed by
## code; each of these was a `case` over key names in each front-end's view).
##
## Refuses to own: what the operations do (each front-end's operation tables
## onto `MenuVM` and the rest), the base-specific rows (`cua_keymap`,
## `emacs_keymap`, `navigation_keymap`), and resolution.
##
## These overlays read the same keys under every base, on purpose: an open menu
## in Vim is still a menu, as VS Code's is under a Vim extension. A user's row
## rebinds any of them like any other.

import ./base_rows

const
  OverlayRows*: seq[BaseRow] = @[
    # --- The program menu, while it is open (CUA-Keymap.md §3.8) -----------
    BaseRow(chords: "Up", operation: "menu.focus-previous", table: MenuTable),
    BaseRow(chords: "Down", operation: "menu.focus-next", table: MenuTable),
    BaseRow(chords: "Right", operation: "menu.enter-folder", table: MenuTable),
    BaseRow(chords: "Left", operation: "menu.leave-folder", table: MenuTable),
    BaseRow(chords: "Enter", operation: "menu.accept", table: MenuTable),
    BaseRow(chords: "Escape", operation: "menu.close", table: MenuTable),

    # --- A text shown over the window: an event's content, a tracepoint's hits
    BaseRow(chords: "Escape", operation: "content-view.close", table: ContentViewTable),
    BaseRow(chords: "Enter", operation: "content-view.close", table: ContentViewTable),
    BaseRow(chords: "q", operation: "content-view.close", table: ContentViewTable),
    BaseRow(chords: "Up", operation: "content-view.scroll-up", table: ContentViewTable),
    BaseRow(chords: "k", operation: "content-view.scroll-up", table: ContentViewTable),
    BaseRow(chords: "Down", operation: "content-view.scroll-down", table: ContentViewTable),
    BaseRow(chords: "j", operation: "content-view.scroll-down", table: ContentViewTable),
    BaseRow(chords: "PageUp", operation: "content-view.page-up", table: ContentViewTable),
    BaseRow(chords: "PageDown", operation: "content-view.page-down", table: ContentViewTable),
    BaseRow(chords: "Space", operation: "content-view.page-down", table: ContentViewTable),

    # --- The terminal's information dialog (CodeTracer-TUI-Terminal-Adaptation) -
    BaseRow(chords: "Escape", operation: "terminal-info.close", table: TerminalInfoTable),
    BaseRow(chords: "q", operation: "terminal-info.close", table: TerminalInfoTable),
    BaseRow(chords: "Up", operation: "terminal-info.scroll-up", table: TerminalInfoTable),
    BaseRow(chords: "Down", operation: "terminal-info.scroll-down", table: TerminalInfoTable),
    BaseRow(chords: "r", operation: "terminal-info.ask-again", table: TerminalInfoTable),
    BaseRow(chords: "y", operation: "terminal-info.glyphs-look-right", table: TerminalInfoTable),
    BaseRow(chords: "n", operation: "terminal-info.glyphs-look-wrong", table: TerminalInfoTable),
    BaseRow(chords: "c", operation: "terminal-info.copy-test", table: TerminalInfoTable),

    # --- A layout gesture in flight: `Escape` cancels it under every base -----
    BaseRow(chords: "Escape", operation: "layout.cancel-drag", table: LayoutGestureTable),

    # --- The Terminal Output pane (Terminal-Output-Pane.md §3): `v` toggles the
    # lines and screen views. `Left` / `Right` are the view's, under every base,
    # and in the screen view that operation steps a write.
    BaseRow(chords: "Left", operation: "view.scroll-left",
            table: PaneTablePrefix & "terminalOutput"),
    BaseRow(chords: "Right", operation: "view.scroll-right",
            table: PaneTablePrefix & "terminalOutput"),
    BaseRow(chords: "v", operation: "terminal-output.toggle-view",
            whenText: "paneKind == terminalOutput && !textInputFocus",
            table: PaneTablePrefix & "terminalOutput"),

    # --- A story host's playback chrome: the terminal story host's keys for
    # its controls (a terminal bar's buttons are one glyph wide), the same
    # under every base.
    BaseRow(chords: "Space", operation: "story-playback.play", table: StoryPlaybackTable),
    BaseRow(chords: "n", operation: "story-playback.step", table: StoryPlaybackTable),
    BaseRow(chords: "[", operation: "story-playback.previous", table: StoryPlaybackTable),
    BaseRow(chords: "]", operation: "story-playback.next", table: StoryPlaybackTable),
    BaseRow(chords: "0", operation: "story-playback.rewind", table: StoryPlaybackTable),

    # --- The session activity timeline (the cardless timeline of one Agent
    # Harbor session): the same under every base, as a list pane's arrows
    # are. `Right` / `Left` open and close the focused line, `Enter` steps
    # in, `+` / `-` open every group and close everything.
    BaseRow(chords: "Right", operation: "session-activity.open", table: SessionActivityTable),
    BaseRow(chords: "Left", operation: "session-activity.close", table: SessionActivityTable),
    BaseRow(chords: "Enter", operation: "session-activity.step-in", table: SessionActivityTable),
    BaseRow(chords: "+", operation: "session-activity.expand-all", table: SessionActivityTable),
    BaseRow(chords: "-", operation: "session-activity.collapse-all", table: SessionActivityTable),
    BaseRow(chords: "Down", operation: "session-activity.focus-next", table: SessionActivityTable),
    BaseRow(chords: "Up", operation: "session-activity.focus-previous", table: SessionActivityTable),

    # --- The omnibox composer: `Enter` sends the instruction where the
    # sheet's bar marks, `Down` / `Up` move that mark (the omnibox's own
    # result keys), the same under every base.
    BaseRow(chords: "Enter", operation: "composer.send", table: ComposerTable),
    BaseRow(chords: "Down", operation: "composer.next-destination", table: ComposerTable),
    BaseRow(chords: "Up", operation: "composer.previous-destination", table: ComposerTable),

    # --- The control center: `Down` / `Up` walk the sessions waiting for the
    # operator and `Enter` opens the one they are on, the same under every
    # base, as a list pane's arrows are. Its launch form is the composer's,
    # whose keys are above.
    BaseRow(chords: "Down", operation: "control-center.next", table: ControlCenterTable),
    BaseRow(chords: "Up", operation: "control-center.previous", table: ControlCenterTable),
    BaseRow(chords: "Enter", operation: "control-center.open", table: ControlCenterTable),

    # --- The gaze mark: one key pauses and resumes gaze tracking anywhere in
    # the window, the same under every base (Eye-Tracking-Context "Privacy
    # and control"). `Ctrl+Alt+Y` (the eye): measured free in every base's
    # rows and in every binding set and desktop preset, where `Ctrl+Alt+G`
    # is the chorded stepping set's Continue and `F9` toggles a breakpoint
    # (P2c study D65).
    BaseRow(chords: "Ctrl+Alt+Y", operation: "gaze.toggle-pause", table: GlobalTable),

    # --- The omnibox's result commands: `Enter` opens the selected row,
    # `Down` / `Up` move the selection, `Tab` inserts a completion (the
    # launcher's sigil rule), the same under every base.
    BaseRow(chords: "Enter", operation: "results.open", table: ResultsTable),
    BaseRow(chords: "Down", operation: "results.next", table: ResultsTable),
    BaseRow(chords: "Up", operation: "results.previous", table: ResultsTable),
    BaseRow(chords: "Tab", operation: "results.insert", table: ResultsTable),

    # --- The Agent Harbor Changes panel: `Down` / `Up` move the keyboard
    # through the spec cards or the files, `Enter` opens or closes the one
    # it is on, `Right` / `Left` step the tabs, `PageDown` / `PageUp`
    # scroll, the same under every base, as a list pane's keys are.
    BaseRow(chords: "Down", operation: "changes.focus-next", table: ChangesTable),
    BaseRow(chords: "Up", operation: "changes.focus-previous", table: ChangesTable),
    BaseRow(chords: "Enter", operation: "changes.toggle", table: ChangesTable),
    BaseRow(chords: "Right", operation: "changes.next-tab", table: ChangesTable),
    BaseRow(chords: "Left", operation: "changes.previous-tab", table: ChangesTable),
    BaseRow(chords: "PageDown", operation: "changes.page-down", table: ChangesTable),
    BaseRow(chords: "PageUp", operation: "changes.page-up", table: ChangesTable),

    # --- The Agent Harbor Inbox: `]` / `[` Next and Previous over the
    # server's cursor (Agent Harbor's own keys for them), `1`-`4` the item's
    # priority, the arrows and the page keys scroll. A story host's playback
    # bar keeps `[` / `]` (its scope comes first there).
    BaseRow(chords: "]", operation: "inbox.next", table: InboxTable),
    BaseRow(chords: "[", operation: "inbox.previous", table: InboxTable),
    BaseRow(chords: "1", operation: "inbox.priority-1", table: InboxTable),
    BaseRow(chords: "2", operation: "inbox.priority-2", table: InboxTable),
    BaseRow(chords: "3", operation: "inbox.priority-3", table: InboxTable),
    BaseRow(chords: "4", operation: "inbox.priority-4", table: InboxTable),
    BaseRow(chords: "Down", operation: "inbox.scroll-down", table: InboxTable),
    BaseRow(chords: "Up", operation: "inbox.scroll-up", table: InboxTable),
    BaseRow(chords: "PageDown", operation: "inbox.page-down", table: InboxTable),
    BaseRow(chords: "PageUp", operation: "inbox.page-up", table: InboxTable),

    # --- The Video Player (Visual-Replay.md § Keyboard Shortcuts): its keys
    # while it has the focus, the same under every base, as the desktop's
    # player always had them.
    BaseRow(chords: "Space", operation: "video-player.toggle-play", table: VideoPlayerTable),
    BaseRow(chords: "k", operation: "video-player.toggle-play", table: VideoPlayerTable),
    BaseRow(chords: "j", operation: "video-player.rewind", table: VideoPlayerTable),
    BaseRow(chords: "l", operation: "video-player.fast-forward", table: VideoPlayerTable),
    BaseRow(chords: "Left", operation: "video-player.step-frame-back", table: VideoPlayerTable),
    BaseRow(chords: "Right", operation: "video-player.step-frame-forward", table: VideoPlayerTable),
    BaseRow(chords: "Shift+Left", operation: "video-player.step-draw-back", table: VideoPlayerTable),
    BaseRow(chords: "Shift+Right", operation: "video-player.step-draw-forward", table: VideoPlayerTable),
    BaseRow(chords: "Home", operation: "video-player.jump-start", table: VideoPlayerTable),
    BaseRow(chords: "End", operation: "video-player.jump-end", table: VideoPlayerTable),
    BaseRow(chords: "p", operation: "video-player.toggle-picker", table: VideoPlayerTable),
    # While the pixel picker is on, `Escape` cancels it (a layer the pane
    # pushes, so `Escape` is the pane's only then).
    BaseRow(chords: "Escape", operation: "video-player.cancel-picker", table: VideoPickerTable),
    # While the terminal's magnifier is open over the frame — the picker's
    # keyboard stage — the arrows move the picked pixel (with Shift, by eight),
    # `Enter` picks it, and `Escape` or `p` cancels.
    BaseRow(chords: "Left", operation: "video-player.move-magnifier-left(1)", table: VideoMagnifierTable),
    BaseRow(chords: "Right", operation: "video-player.move-magnifier-right(1)", table: VideoMagnifierTable),
    BaseRow(chords: "Up", operation: "video-player.move-magnifier-up(1)", table: VideoMagnifierTable),
    BaseRow(chords: "Down", operation: "video-player.move-magnifier-down(1)", table: VideoMagnifierTable),
    BaseRow(chords: "Shift+Left", operation: "video-player.move-magnifier-left(8)", table: VideoMagnifierTable),
    BaseRow(chords: "Shift+Right", operation: "video-player.move-magnifier-right(8)", table: VideoMagnifierTable),
    BaseRow(chords: "Shift+Up", operation: "video-player.move-magnifier-up(8)", table: VideoMagnifierTable),
    BaseRow(chords: "Shift+Down", operation: "video-player.move-magnifier-down(8)", table: VideoMagnifierTable),
    BaseRow(chords: "Enter", operation: "video-player.commit-pick", table: VideoMagnifierTable),
    BaseRow(chords: "Escape", operation: "video-player.cancel-picker", table: VideoMagnifierTable),
    BaseRow(chords: "p", operation: "video-player.cancel-picker", table: VideoMagnifierTable),
  ]
