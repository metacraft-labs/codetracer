## tui/agent_harbor/ah_tui_story_host.nim — CTF-P1b. The terminal story host:
## ONE story of the `CodeTracer/Agent Harbor` StoryBook section, by its
## StoryBook id, in a colour mode, at the terminal's size.
##
## StoryBook shows each story in the browser and `codetracer-gpui-story`
## (`gpui/agent_harbor/ah_story_window.nim`) in a GPUI window; this is the
## terminal's: `tui/agent_harbor/ah_tui_stories.mountStory` over the same
## story constructors, painted as a snapshot app (`testing/test_app_runtime`)
## so a TermAssert suite can read the frame with the cursor barrier and drive
## it with SGR mouse reports. A press acts on what is under it (a fold, a
## filter, a tab, `+N`), motion moves the hover (the initiative popup), and
## the frame is repainted from the viewmodel.
##
## It is a snapshot app (`testing/test_app_runtime`), the test-only runtime
## no shipped binary links: `tests/apps/app_agent_harbor_story.nim` includes
## this module so the Tier-2 suites build it as they build every child app,
## and `just ctf-p1b-tui-story` builds it on its own. Nothing in `main.nim`
## reaches it.
##
## Command line (the runtime's own flags pass through):
##
##   ah_tui_story_host --story=<storybook id> [--theme=dark|light]
##                     [--moment=<name>] [--cols=<n>] [--rows=<n>]
##                     [--list] [--captures]
##
## A playback story (`stories/agent_harbor_playback.nim`) plays on IsoNim's
## `RealClock`, its playback bar on the last row (`ah_tui_playback_bar.nim`);
## a click on a button or its key (space play / pause, `n` step, `[` and `]`
## the previous and next named moment, `0` rewind) controls it, and the
## runtime's idle hook pumps the clock and repaints when it moved.
## `--moment` opens it at one of its scenario's named moments (an unknown
## name, or a story that is not a playback story, is a usage error, 2).
##
## `--list` prints every story id of the section and exits; `--captures`
## prints the capture name of every story, size and theme
## (`agent-harbor-<story>-<size>-<theme>`, the web and GPUI records' names). The sizes the
## captures use are `ah_tui_stories.TuiSizes`: laptop 180×56 and sidebar
## 45×56, the brief's 1440×900 and 360×900 at 8×16 px a cell. Colours are
## 24-bit (the views' design-system roles), so the terminal should be
## truecolor. Like every snapshot app it ends after
## `TestAppDeadlineSeconds` or on `q`.
##
## `just ctf-p1b-tui-story <id> [dark|light]` builds and runs it at the
## terminal's size.

import std/strutils

import isonim_tui

import ./ah_tui_stories

const
  MouseOn = "\x1b[?1003h\x1b[?1006h"
    ## Any-motion tracking (1003, so the popup follows the pointer) in SGR
    ## encoding (1006).

type
  StoryArgs = object
    story, theme, moment: string
    list, captures: bool
    rest: seq[string]
      ## The snapshot runtime's flags (`--cols`, `--rows`, `--test-ipc`, …).

proc parseStoryArgs(args: openArray[string]): StoryArgs =
  result.theme = "dark"
  for arg in args:
    if arg.startsWith("--story="): result.story = arg["--story=".len .. ^1]
    elif arg.startsWith("--theme="): result.theme = arg["--theme=".len .. ^1]
    elif arg.startsWith("--moment="): result.moment = arg["--moment=".len .. ^1]
    elif arg == "--list": result.list = true
    elif arg == "--captures": result.captures = true
    else: result.rest.add arg

when isMainModule:
  import std/os
  import ../testing/test_app_runtime

  proc main(): int =
    let a = parseStoryArgs(commandLineParams())
    let section = agentHarborSection()
    if a.list:
      for story in section.stories: echo storybookId(section, story)
      return 0
    if a.captures:
      for story in section.stories:
        for (size, _, _) in TuiSizes:
          for theme in ["dark", "light"]:
            echo captureIdOf(storybookId(section, story), size, theme)
      return 0
    if a.theme notin ["dark", "light"]:
      stderr.writeLine("app_agent_harbor_story: --theme is dark or light, not " & a.theme)
      return 2
    var story: CodeTracerStory
    try:
      story = findStory(a.story)
    except KeyError as e:
      stderr.writeLine("app_agent_harbor_story: " & e.msg & " (--list prints them)")
      return 2
    if a.moment.len > 0:
      # Checked before the first paint, which must not raise.
      if not isPlaybackStory(story.surface, story.fixture):
        stderr.writeLine("app_agent_harbor_story: --moment names a moment of a playback " &
                         "story; " & a.story & " is not one")
        return 2
      let names = playbackScenario(playbackScenarioNameOf(story.fixture)).momentNames
      if a.moment notin names:
        stderr.writeLine("app_agent_harbor_story: " & a.story & " has no moment named '" &
                         a.moment & "' (its moments: " & names.join(", ") & ")")
        return 2
    let mode = if a.theme == "light": dmLight else: dmDark
    var mount: AhTuiMount = nil
    let build = proc(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
      if mount.isNil or mount.cols != cols or mount.rows != rows:
        if not mount.isNil: mount.dispose()
        mount = mountStory(story, cols, rows, mode, moment = a.moment)
      styledRowsTree(r, mount.rowsOf)
    let input = proc(token: string): bool =
      not mount.isNil and mount.handleInput(token)
    let idle = proc(): bool = not mount.isNil and mount.idle()
    let prologue = proc(cols, rows: int): string = MouseOn
    result = snapshotAppMain(build, a.rest, input, prologue = prologue, idle = idle)
    if not mount.isNil: mount.dispose()

  quit(main())
