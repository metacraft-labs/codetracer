## The Agent Harbor playback stories: a story whose viewmodels follow a
## scenario replayed on a clock, and the controls every story host's shared
## chrome offers over it.
##
## A playback story names its scenario in its fixture,
## `playback-<scenario>` (`front-ends`, `initiative-run`: the synthetic
## scenarios of nim-agents-isonim-viewmodels' `playback_scenarios.nim`). Its
## viewmodels are built by the same constructors as every other Agent Harbor
## story (`agent_harbor_stories.nim`), over ONE `PlaybackDataSource` of that
## scenario, and nothing else feeds them: the source sends the scenario's
## entries through the data-source seam's subscriptions as its head moves,
## and the viewmodels fold them. No host wiring moves a viewmodel.
##
## `AhPlayback` is that source and the controls over it, as every host's
## chrome calls them: play, pause, step to the next entry, seek to a named
## moment (the previous or next one, or one by name), rewind. A seek to an
## earlier moment rebuilds from the first frame (the source sends a reset and
## every viewmodel loads again; `PlaybackDataSource.seek`). `changed` moves
## whenever what the chrome shows may have changed (a control, a delivered
## entry, and every `TickerMs` while playing, for the time it shows), so a
## host redraws its chrome from it.
##
## The clock is the host's: IsoNim's `RealClock` in a story host that plays
## in real time, a `TestClock` in tests and captures, which move only when
## the test advances them or seek. Nothing here reads wall time.
##
## Plain viewmodel code: it compiles natively and to JavaScript, and imports
## no renderer.

import std/strutils

import isonim/core/[signals, clock]
import nim_agents_isonim_viewmodels/agent_harbor/[data_source, playback_source,
                                                   playback_scenarios]

export signals, clock, playback_source, playback_scenarios

const
  PlaybackFixturePrefix* = "playback-"
    ## A playback story's fixture: `playback-<scenario name>`.
  TickerMs = 500.0
    ## How often a playing story's chrome is told the time moved.

type
  AhPlayback* = ref object
    ## A playback story's source and the controls its host's chrome calls.
    surface*, fixture*: string
    source*: PlaybackDataSource
    changed*: Signal[int]
      ## Moves whenever the chrome's readout may have changed.
    ticker: int
    hasTicker: bool
    subscriptions: seq[proc()]
      ## Cancels this object's own subscriptions to the source.
    disposed: bool

proc isPlaybackFixture*(fixture: string): bool =
  fixture.startsWith(PlaybackFixturePrefix)

proc playbackScenarioNameOf*(fixture: string): string =
  ## The scenario a playback fixture names; raises `ValueError` for a
  ## fixture that is not one.
  if not fixture.isPlaybackFixture:
    raise newException(ValueError, "not a playback story fixture: " & fixture)
  fixture[PlaybackFixturePrefix.len .. ^1]

proc bump(pb: AhPlayback) =
  if not pb.disposed: pb.changed.val = pb.changed.val + 1

proc stopTicker(pb: AhPlayback) =
  if pb.hasTicker:
    pb.source.clock.cancel(pb.ticker)
    pb.hasTicker = false

proc startTicker(pb: AhPlayback) =
  ## While the source plays, tell the chrome every `TickerMs` that the time
  ## moved; stops once the source is no longer playing (paused, or the run
  ## is over).
  pb.stopTicker()
  if pb.disposed or not pb.source.playing: return
  let target = pb
  pb.ticker = pb.source.clock.schedule(proc() =
    target.hasTicker = false
    target.bump()
    if target.source.playing: target.startTicker(), TickerMs)
  pb.hasTicker = true

proc newAhPlayback*(surface, fixture: string; clock: ClockBase): AhPlayback =
  ## A paused playback of the scenario `fixture` names, at its first frame,
  ## on `clock`. Raises `ValueError` for a fixture that names no scenario.
  ## Subscribes to every kind the source sends only to move `changed`; the
  ## viewmodels subscribe on their own when they load.
  let scenario = playbackScenario(playbackScenarioNameOf(fixture))
  let pb = AhPlayback(surface: surface, fixture: fixture,
                      source: newPlaybackDataSource(scenario, clock),
                      changed: createSignal(0))
  let s = pb.source
  let frames = s.subscribeFleetFrames(proc(e: DataResult[FleetFrame]): ProgressDelivery =
    pb.bump(); pdUnchanged)
  let resumes = s.subscribeResumes(proc(e: DataResult[ResumeEvent]): ProgressDelivery =
    pb.bump(); pdUnchanged)
  let progress = s.subscribeProgress(proc(e: DataResult[ProgressEvent]): ProgressDelivery =
    pb.bump(); pdUnchanged)
  let recordings = s.subscribeRecordings(proc(e: DataResult[RecordingEvent]): ProgressDelivery =
    pb.bump(); pdUnchanged)
  let resets = s.subscribeResets(proc(e: DataResult[StreamReset]): ProgressDelivery =
    pb.bump(); pdUnchanged)
  pb.subscriptions = @[proc() = frames.cancel(), proc() = resumes.cancel(),
                       proc() = progress.cancel(), proc() = recordings.cancel(),
                       proc() = resets.cancel()]
  pb

proc dispose*(pb: AhPlayback) =
  ## Stops the playback and drops this object's subscriptions (the
  ## viewmodels drop theirs when they are disposed).
  if pb.isNil or pb.disposed: return
  discard pb.source.pause()
  pb.stopTicker()
  for cancel in pb.subscriptions: cancel()
  pb.disposed = true

# ---------------------------------------------------------------------------
# What the chrome shows
# ---------------------------------------------------------------------------

proc momentNames*(pb: AhPlayback): seq[string] = pb.source.scenario.momentNames
proc playing*(pb: AhPlayback): bool = pb.source.playing
proc finished*(pb: AhPlayback): bool = pb.source.finished

proc currentMoment*(pb: AhPlayback): string =
  ## The named moment the head is at; "" between moments.
  pb.source.currentMoment

proc elapsedLabel*(pb: AhPlayback): string =
  ## The head's time since the scenario's first moment, `+m:ss`.
  let seconds = max(0'i64, (pb.source.currentMs - pb.source.scenario.firstMs) div 1000)
  "+" & $(seconds div 60) & ":" & align($(seconds mod 60), 2, '0')

proc momentLabel*(pb: AhPlayback): string =
  ## What the readout names: the moment the head is at, `first frame`
  ## before anything was played, or `between moments`.
  let m = pb.currentMoment
  if m.len > 0: m
  elif pb.source.position == 0: "first frame"
  else: "between moments"

proc stateLabel*(pb: AhPlayback): string =
  if pb.playing: "playing" elif pb.finished: "ended" else: "paused"

proc readout*(pb: AhPlayback): string =
  ## The chrome's one line of text: the moment, then the time.
  pb.momentLabel & " \xC2\xB7 " & pb.elapsedLabel

proc momentIndex(pb: AhPlayback): int =
  ## The index of the last named moment at or before the head; -1 before
  ## the first.
  result = -1
  let now = pb.source.currentMs
  for i, name in pb.momentNames:
    if pb.source.scenario.momentMs(name) <= now: result = i

# ---------------------------------------------------------------------------
# The controls
# ---------------------------------------------------------------------------

proc play*(pb: AhPlayback): bool =
  ## Plays from the head on the clock. False when already playing or ended.
  result = pb.source.play()
  if result: pb.startTicker()
  pb.bump()

proc pause*(pb: AhPlayback): bool =
  result = pb.source.pause()
  pb.stopTicker()
  pb.bump()

proc togglePlay*(pb: AhPlayback): bool =
  ## Play when paused, pause when playing: the chrome's one play button.
  if pb.playing: pb.pause() else: pb.play()

proc step*(pb: AhPlayback): bool =
  ## Pauses and delivers the next entry (every entry at its moment).
  result = pb.source.step()
  pb.stopTicker()
  pb.bump()

proc seekMoment*(pb: AhPlayback; moment: string): bool =
  ## Moves the head to a named moment; an earlier one rebuilds from the
  ## first frame. False, and nothing moves, for a name the scenario lacks.
  result = pb.source.seekMoment(moment)
  if pb.source.playing: pb.startTicker() else: pb.stopTicker()
  pb.bump()

proc nextMoment*(pb: AhPlayback): bool =
  ## Seeks to the first named moment after the head.
  let names = pb.momentNames
  let now = pb.source.currentMs
  for name in names:
    if pb.source.scenario.momentMs(name) > now: return pb.seekMoment(name)
  false

proc previousMoment*(pb: AhPlayback): bool =
  ## Seeks to the named moment before the one the head is at (or, between
  ## moments, to the last one passed); before the first, rewinds.
  let names = pb.momentNames
  var i = pb.momentIndex
  if i >= 0 and pb.currentMoment.len == 0:
    # Between moments: back to the last one passed.
    return pb.seekMoment(names[i])
  dec i
  if i >= 0: return pb.seekMoment(names[i])
  if pb.source.position == 0: return false
  pb.source.rewind()
  pb.stopTicker()
  pb.bump()
  true

proc rewind*(pb: AhPlayback) =
  ## Back to the first frame, paused.
  pb.source.rewind()
  pb.stopTicker()
  pb.bump()

proc openAtMoment*(pb: AhPlayback; moment: string) =
  ## Where a host opens a story asked for a named moment (its URL parameter
  ## or command-line option): "" leaves it at the first frame. Raises
  ## `ValueError` naming the scenario's moments for a name it lacks, so a
  ## capture never shows another state under the moment's name.
  if moment.len == 0: return
  if not pb.seekMoment(moment):
    raise newException(ValueError, "the playback scenario '" & pb.source.scenario.name &
                       "' has no moment named '" & moment & "' (its moments: " &
                       pb.momentNames.join(", ") & ")")

# ---------------------------------------------------------------------------
# The hosts' controls, one vocabulary
# ---------------------------------------------------------------------------

type
  PlaybackControl* = enum
    ## The chrome's buttons, in the order every host draws them.
    pcPlay = "play"          ## play, or pause while playing
    pcStep = "step"          ## the next entry
    pcPrevious = "previous"  ## the previous named moment
    pcNext = "next"          ## the next named moment
    pcRewind = "rewind"      ## the first frame

proc controlLabel*(pb: AhPlayback; control: PlaybackControl): string =
  ## A button's word, the same in every host.
  case control
  of pcPlay: (if pb.playing: "Pause" else: "Play")
  of pcStep: "Step"
  of pcPrevious: "\xE2\x97\x80 Moment"
  of pcNext: "Moment \xE2\x96\xB6"
  of pcRewind: "Rewind"

proc controlTitle*(control: PlaybackControl): string =
  ## A button's tooltip.
  case control
  of pcPlay: "Play the scenario in real time, or pause it"
  of pcStep: "Deliver the next entry of the scenario"
  of pcPrevious: "Seek to the previous named moment (rebuilds from the first frame)"
  of pcNext: "Seek to the next named moment"
  of pcRewind: "Back to the first frame"

proc applyControl*(pb: AhPlayback; control: PlaybackControl): bool =
  ## What a chrome button (or the terminal's key for it) does. True when the
  ## playback moved or changed state.
  case control
  of pcPlay: pb.togglePlay()
  of pcStep: pb.step()
  of pcPrevious: pb.previousMoment()
  of pcNext: pb.nextMoment()
  of pcRewind:
    let moved = pb.source.position > 0 or pb.playing
    pb.rewind()
    moved

proc controlAction*(pb: AhPlayback; control: PlaybackControl): proc() =
  ## A button's click handler, built in a proc of its own so each closure
  ## owns its control (a closure made in a loop would share the loop's).
  result = proc() = discard pb.applyControl(control)
