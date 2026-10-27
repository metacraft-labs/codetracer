## viewmodels/scrollbar_interaction.nim — how a scrollbar answers the
## pointer, and how it fades: the part of Scrollbar-Scrubbers.md §7 that does
## not depend on what a front-end draws with.
##
## The terminal (cells) and the GPUI window (pixels) both drive this model:
##
##   * the options (§7.1) — `ScrollbarOptions`, read from the layout settings;
##   * the four states a bar is drawn in (§7.4) — `BarState`;
##   * the thumb GRAB: the point of the thumb the pointer took is kept while
##     it is dragged (`grabOffset`, `grabbedTop`), rather than the thumb
##     re-centring itself on the pointer;
##   * the two rules a press on the TRACK follows (§7.4) — the 2026-10-05
##     jump, which then continues as a grab of the thumb by its middle, or a
##     page toward the pointer that repeats while the press is held
##     (`pageToward`, `TrackHold`);
##   * the FADE (§7.5) — `FadeState`, moved linearly in time toward 0 or 1
##     and drawn through a smoothstep, so both directions are animated.
##
## Every position here is a fraction of the track, as the scrubber model's
## (`scrollbar_scrubber.trackFractionAt`), so the arithmetic is the same at
## any resolution. Pure; C and JavaScript backends.

import ./scrollbar_scrubber

type
  BarAxis* = enum
    axVertical = "vertical"
    axHorizontal = "horizontal"

  BarThickness* = enum
    ## `scrollbar-thickness` (§7.2).
    btHairline = "hairline"
    btThin = "thin"
    btThick = "thick"
    btFull = "full"

  TrackClickRule* = enum
    ## `scrollbar-click` (§7.4): what a left press on the track does. The
    ## middle button always does the other one.
    tcJump = "jump"
    tcPage = "page"

  ScrollbarOptions* = object
    thickness*: BarThickness
    fade*: bool
    track*: bool
    click*: TrackClickRule
    modernUnicode*: bool
      ## Terminal only: Symbols for Legacy Computing glyphs (§7.2).
    reduceMotion*: bool
      ## Not a setting yet: the seam for PLAT-71's `reduce-motion` (and a
      ## slow link) — the fade jumps to where it is going instead of
      ## animating. Its visibility still follows §7.5's triggers.

  BarState* = enum
    ## What the pointer is doing to a bar (§7.4).
    bsIdle = "idle"
    bsHoverTrack = "hover-track"   ## on the bar, off the thumb
    bsHoverThumb = "hover-thumb"   ## on the thumb: it can be grabbed
    bsHeld = "held"                ## the thumb is held

  FadeState* = object
    ## One bar's visibility (§7.5). `level` moves linearly between 0 and 1
    ## at `FadeInMs` / `FadeOutMs` per full sweep; `easeFade(level)` is what
    ## is drawn.
    level*: float
    lastWakeMs*: int64
      ## When something last asked for the bar.
    steppedMs*: int64
      ## When `stepFade` last ran.

  TrackHold* = object
    ## A press held on the track under the paging rule: it pages again at
    ## `dueMs`, toward `fraction`, until the thumb reaches it.
    active*: bool
    fraction*: float
    dir*: int
      ## The direction of the first page; the repeat never turns round.
    dueMs*: int64

const
  DefaultScrollbarOptions* = ScrollbarOptions(
    thickness: btHairline, fade: true, track: false, click: tcJump,
    modernUnicode: false)
    ## §7.1's defaults.
  FadeInMs* = 180
  FadeOutMs* = 400
  FadeAfterMs* = 1200
    ## The quiet time before a bar starts fading out.
  FadeFrameMs* = 16
    ## The longest a front-end waits between two frames of a moving fade.
  RepeatDelayMs* = 350
    ## A held paging press pages again after this long ...
  RepeatEveryMs* = 55
    ## ... and then this often.

func otherRule*(r: TrackClickRule): TrackClickRule =
  if r == tcJump: tcPage else: tcJump

func isHeld*(s: BarState): bool = s == bsHeld

func widened*(s: BarState): bool =
  ## The states in which the thumb is drawn one step wider (§7.2).
  s in {bsHoverThumb, bsHeld}

func trackRevealed*(s: BarState): bool =
  ## The states in which the track is drawn even with `track` off (§7.4).
  s in {bsHoverTrack, bsHeld}

# ---------------------------------------------------------------------------
# The grab
# ---------------------------------------------------------------------------

func grabOffset*(m: ScrubberModel; fraction: float): float =
  ## Where on the thumb a press at track fraction `fraction` took it: the
  ## pointer's distance from the thumb's start, kept for the whole drag.
  fraction - m.thumbStart

func grabbedTop*(m: ScrubberModel; fraction, offset: float): int =
  ## The first visible row while the thumb, grabbed `offset` from its start,
  ## is held at track fraction `fraction` (§3.3): the thumb stays under the
  ## pointer by the point it was taken by.
  m.dragTo(fraction - offset)

func jumpGrabOffset*(m: ScrubberModel): float =
  ## The grab a JUMP leaves behind (§7.4): the jump centres the pointer's row,
  ## so the press continues holding the thumb by its middle.
  m.thumbLength / 2.0

# ---------------------------------------------------------------------------
# Paging
# ---------------------------------------------------------------------------

func pageSize*(m: ScrubberModel): int =
  ## One page: the view's rows (or columns) less one, at least one.
  max(1, m.visible - 1)

func pageDirection*(m: ScrubberModel; fraction: float): int =
  ## Which way a page toward track fraction `fraction` goes: -1 (it is before
  ## the thumb), 1 (after it), 0 (the thumb covers it).
  let start = m.thumbStart
  if fraction < start: -1
  elif fraction > start + m.thumbLength: 1
  else: 0

func pageToward*(m: ScrubberModel; fraction: float; dir: int): int =
  ## The first visible row after one more page in direction `dir` toward
  ## `fraction`, or -1 once the thumb has reached it — covers it, or has
  ## passed it — so a held press stops there instead of turning round.
  if dir == 0 or m.pageDirection(fraction) != dir:
    return -1
  let top = max(0, min(m.maxFirstVisible, m.firstVisible + dir * m.pageSize))
  if top == m.firstVisible: -1 else: top

proc start*(h: var TrackHold; fraction: float; dir: int; nowMs: int64) =
  h = TrackHold(active: dir != 0, fraction: fraction, dir: dir,
                dueMs: nowMs + RepeatDelayMs)

func due*(h: TrackHold; nowMs: int64): bool =
  h.active and nowMs >= h.dueMs

proc repeated*(h: var TrackHold; nowMs: int64) =
  h.dueMs = nowMs + RepeatEveryMs

# ---------------------------------------------------------------------------
# Fading
# ---------------------------------------------------------------------------

func initFade*(nowMs: int64; visible = true): FadeState =
  FadeState(level: (if visible: 1.0 else: 0.0), lastWakeMs: nowMs,
            steppedMs: nowMs)

proc wake*(f: var FadeState; nowMs: int64) =
  ## Something asked for the bar: it fades in (if it was not there) and stays
  ## for `FadeAfterMs`.
  ##
  ## A bar that was not wanted (fading out, or gone) starts its fade-in AT
  ## the wake: the time since the last step is not counted toward it. A loop
  ## steps a gone bar only at its idle tick (up to `IdlePollMs` apart), and a
  ## pointer arriving just before the next tick would otherwise be credited
  ## with all of that time — an instant fade-in.
  if nowMs - f.lastWakeMs >= FadeAfterMs:
    f.steppedMs = max(f.steppedMs, nowMs)
  f.lastWakeMs = max(f.lastWakeMs, nowMs)

func fadeTarget*(f: FadeState; o: ScrollbarOptions; nowMs: int64;
                 held = false): float =
  ## 1 while the bar is wanted — recently woken, the pointer on it or its
  ## thumb held (`held`), or `fade` off — else 0.
  if not o.fade or held or nowMs - f.lastWakeMs < FadeAfterMs: 1.0
  else: 0.0

proc stepFade*(f: var FadeState; o: ScrollbarOptions; nowMs: int64;
               held = false): bool =
  ## Advance to `nowMs`; true while the level is still moving (paint again
  ## within `FadeFrameMs`).
  let target = f.fadeTarget(o, nowMs, held)
  # A fade-out runs from the moment the quiet time ran out, however late the
  # step that sees it comes.
  let since = if target < f.level: max(f.steppedMs, f.lastWakeMs + FadeAfterMs)
              else: f.steppedMs
  let dt = float(max(0'i64, nowMs - since))
  f.steppedMs = nowMs
  if not o.fade:
    f.level = 1.0
    return false
  if o.reduceMotion:
    f.level = target
    return false
  if f.level < target:
    f.level = min(target, f.level + dt / float(FadeInMs))
  elif f.level > target:
    f.level = max(target, f.level - dt / float(FadeOutMs))
  f.level != target

func easeFade*(level: float): float =
  ## Smoothstep: a fade that starts and ends gently.
  let x = max(0.0, min(1.0, level))
  x * x * (3.0 - 2.0 * x)

func visibility*(f: FadeState; o: ScrollbarOptions): float =
  if not o.fade: 1.0 else: easeFade(f.level)

func nextFadeMs*(f: FadeState; o: ScrollbarOptions): int64 =
  ## When a resting, visible bar starts fading out — so a loop can sleep
  ## until then — or -1.
  if not o.fade or f.level <= 0.0: -1'i64
  else: f.lastWakeMs + FadeAfterMs
