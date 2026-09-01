## The topbar's action set, derived from platform capability.
##
## ## What this replaces, and why it is worth replacing
##
## Noir-Studio.md §1a.2: "The topbar is already parametric, and nobody had to
## make it so. Window controls appear on desktop and not on the web, because the
## platform either owns the window frame or does not. Share and identity are the
## same slot from the other side."
##
## That is the claim. The code did not match it. Three decisions in
## `ui/menu.nim` were build checks:
##
## | site | was | is |
## | --- | --- | --- |
## | `applyCaptionBarWindowMode` | `reserveWindowControls = defined(ctmacos)` | `capWindowControls` + `overlaysCaptionBar` |
## | `MenuShellModel.showNavigation` | `not defined(ctmacos)` | `not capNativeMenuBar` |
## | `MenuShellModel.showWindowMenu` | `inElectron and not defined(ctmacos)` | `capWindowControls and not capNativeMenuBar` |
##
## A `defined()` is decided when the binary is built, so it cannot be varied by
## a test, cannot describe a desktop build running headless, and multiplies by
## the number of platforms at every site that asks. NS1's
## `test_topbar_actions_follow_capability_not_build` is exactly this:
##
##   "An action unavailable on a platform is absent because its capability is,
##    not because the code asked which build it was; adding a platform adds an
##    instantiation rather than a branch."
##
## ## Why `overlaysCaptionBar` is a capability-shaped fact and not `defined(ctmacos)`
##
## macOS is the one platform where the OS paints its own window buttons *over*
## the application's caption bar, so the bar has to start clear of them. That is
## a property of the window system, not of the build — a macOS build running in
## a browser has no such overlay, and a future Linux compositor that did would
## want the same reservation. It therefore belongs on the profile, next to the
## capabilities, rather than in a `when` at the call site.
##
## This module is pure. It reads a `PlatformProfile`, which is data, and returns
## a record. It is in the host-free surface, and `ci/test/hostfree-build.sh`
## keeps it there.

import ../platform/capabilities

type
  TopbarAction* = enum
    ## Every slot the topbar can carry. Absence is the interesting case: an
    ## action not in the set is not rendered, not rendered-and-disabled.
    tbaDebuggerControls
      ## Step, reverse-step, continue.
      ##
      ## They *were* documented here as "always present — they are the
      ## product", and that was the defect `Edit-Mode-Toolbar.md` §1 is about:
      ## thirteen stepping buttons painted in Edit mode, where there is no
      ## session for them to control. They are still unconditional in
      ## `topbarModel`, which is the **platform** layer and has no business
      ## knowing about modes; the gate is `viewmodels/edit_mode_toolbar.nim`,
      ## which composes this set with the mode.
    tbaBuild
      ## Edit mode only. Runs the project's declared build task, or the
      ## conventional command for the recognised project kind.
    tbaRun
      ## Edit mode only, and it is a **mode transition**: Run records, and the
      ## trace it produces is what Debug mode replays (§9).
    tbaActionOverflow
      ## Edit mode only. Everything else the project declared, which is a list
      ## no toolbar can size in advance.
    tbaRunTests
      ## Both modes: re-running tests from a session is how you check a fix.
    tbaRecordTests
      ## Both modes: recording a test run is one of the two ways into Debug
      ## mode. Split from `tbaRunTests` per §10.3 — they have different
      ## backings and different availability, and Noir has the first and
      ## refuses the second.
    tbaOmnibar
    tbaSessionTabs
    tbaInPageMenu
      ## The application's own menu, drawn in the page. Needed exactly when the
      ## platform does NOT give us a native menu bar to put it in.
    tbaWindowControls
      ## Minimise / maximise / close, drawn by us because the platform expects
      ## the application to.
    tbaShare
      ## Noir-Studio.md §1a.2's one genuinely new icon. Appears where the
      ## platform supplies sharing — the mirror of window controls.
    tbaIdentityAvatar
    tbaRevealProject
      ## "Show in Finder / Explorer".
    tbaOpenProjectDialog

  TopbarModel* = object
    actions*: set[TopbarAction]
    reserveWindowControlSpace*: bool
      ## The caption bar must start clear of buttons the OS paints over it.
      ## Distinct from `tbaWindowControls in actions`: on macOS the OS draws
      ## them (so we must not, but must leave room), and on Windows and Linux we
      ## draw them (so we must, and need no reservation). Collapsing the two is
      ## how the traffic lights end up on top of the menu.
    captionBarFullscreen*: bool

proc topbarModel*(profile: PlatformProfile;
                  fullscreen = false): TopbarModel =
  ## The whole decision, in one place, from data.
  var actions: set[TopbarAction] = {tbaDebuggerControls, tbaOmnibar,
                                    tbaSessionTabs}

  # The menu goes in the page unless the platform hosts it for us.
  if not profile.has(capNativeMenuBar):
    actions.incl tbaInPageMenu

  # We draw the window buttons when the platform gives us the window frame AND
  # does not paint its own over us.
  if profile.has(capWindowControls) and not profile.overlaysCaptionBar:
    actions.incl tbaWindowControls

  if profile.has(capShareLink):
    actions.incl tbaShare
    actions.incl tbaIdentityAvatar

  if profile.has(capRevealInFileManager):
    actions.incl tbaRevealProject

  if profile.has(capOpenFileDialog):
    actions.incl tbaOpenProjectDialog

  TopbarModel(
    actions: actions,
    reserveWindowControlSpace:
      profile.overlaysCaptionBar and profile.has(capWindowControls) and
      not fullscreen,
    captionBarFullscreen: profile.overlaysCaptionBar and fullscreen)

proc has*(model: TopbarModel; action: TopbarAction): bool =
  action in model.actions

proc absentBecause*(profile: PlatformProfile; action: TopbarAction): string =
  ## Why an action is not on the bar, in the words the degradation table uses.
  ## The UI does not show this today, but a bug report should be able to ask —
  ## and having to answer keeps the capability mapping honest, because an
  ## action whose absence cannot be explained is one whose absence was a guess.
  case action
  of tbaInPageMenu:
    if profile.has(capNativeMenuBar):
      "the platform supplies a native menu bar, so the menu is not drawn in the page"
    else: ""
  of tbaWindowControls:
    if profile.overlaysCaptionBar and profile.has(capWindowControls):
      "the window system paints its own controls over the caption bar"
    elif not profile.has(capWindowControls):
      profile.degradedBehaviour(capWindowControls)
    else: ""
  of tbaShare, tbaIdentityAvatar:
    if not profile.has(capShareLink): profile.degradedBehaviour(capShareLink)
    else: ""
  of tbaRevealProject:
    if not profile.has(capRevealInFileManager):
      profile.degradedBehaviour(capRevealInFileManager)
    else: ""
  of tbaOpenProjectDialog:
    if not profile.has(capOpenFileDialog):
      profile.degradedBehaviour(capOpenFileDialog)
    else: ""
  of tbaBuild, tbaRun, tbaActionOverflow, tbaRunTests, tbaRecordTests:
    # Absence of a command slot is a decision about the MODE and about what the
    # project declared, not about the platform, so the profile alone cannot
    # answer it. `edit_mode_toolbar.editModeToolbar` carries the per-button
    # `reason`, and EMT-A28 asserts it is never empty. Answering here with a
    # plausible sentence would put a second, wrong explanation in the tree.
    ""
  of tbaDebuggerControls, tbaOmnibar, tbaSessionTabs:
    ""
