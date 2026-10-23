## test_plat70h_scrollbar_model.nim — PLAT-70 Part H (Scrollbar-Scrubbers.md
## §7), the PURE part both native front-ends drive, swept rather than sampled:
##
##   * the fade (§7.5): from absent to drawn takes `FadeInMs`, from drawn to
##     absent `FadeOutMs` after `FadeAfterMs` of quiet, both in steps (no jump
##     at either end), the drawn curve is monotonic; a wake while fading out
##     turns it round; `fade off` and `reduceMotion` jump;
##   * the grab (§3.3): over populations, views and pointer positions, a
##     thumb grabbed at an offset stays under the pointer by that offset;
##   * paging (§7.4): one page toward the pointer, repeated, stops once the
##     thumb reaches the pointer and never turns round; the repeat's timing;
##   * the settings (§7.1): every setting's every value round-trips through
##     the `:set` line, the flag, the omnibox target and the remembered
##     `name=value` text; a value outside the list is refused by name.
##
## No mocks: pure functions of values. Runs on the C and the JS backends.

import std/[strutils, unittest]

import viewmodels/scrollbar_scrubber
import viewmodels/scrollbar_interaction
import viewmodels/layout_settings

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 895

const On = DefaultScrollbarOptions

proc sweepFade(start: FadeState; o: ScrollbarOptions; fromMs, toMs: int64;
               stepMs: int64; held = false): seq[float] =
  ## The drawn visibility at every step from `fromMs` to `toMs`.
  var f = start
  var t = fromMs
  while t <= toMs:
    discard f.stepFade(o, t, held)
    result.add f.visibility(o)
    t += stepMs

suite "PLAT-70 Part H: the fade is animated both ways":

  test "a resting bar stays drawn, then fades out over FadeOutMs, in steps":
    let f = initFade(0)
    let vis = sweepFade(f, On, 0, FadeAfterMs + FadeOutMs + 100, 16)
    var drawn, between, gone = 0
    var monotonic = true
    for i, v in vis:
      if v >= 1.0: inc drawn
      elif v <= 0.0: inc gone
      else: inc between
      if i > 0 and v > vis[i - 1]: monotonic = false
    ck drawn >= FadeAfterMs div 16
    ck between >= FadeOutMs div 16 - 2   # the out-fade is many frames
    ck gone > 0
    ck monotonic

  test "a wake fades in over FadeInMs, never in one frame":
    var f = initFade(0, visible = false)
    f.wake(1000)
    f.steppedMs = 1000
    var vis: seq[float] = @[]
    var t = 1000'i64
    while t <= 1000 + FadeInMs + 32:
      ck f.stepFade(On, t) or f.level == 1.0
      vis.add f.visibility(On)
      t += 16
    var between = 0
    for i, v in vis:
      if v > 0.0 and v < 1.0: inc between
      if i > 0: ck v >= vis[i - 1]
    ck between >= FadeInMs div 16 - 2
    ck vis[^1] == 1.0
    ck vis[0] < 0.2

  test "a wake long after the last step still fades in over FadeInMs":
    # The loop steps a gone bar only at its idle tick (200 ms apart): a
    # pointer that arrives just before the next tick must not be credited
    # with the time since the last one, or the fade-in is instant.
    var f = initFade(0, visible = false)
    discard f.stepFade(On, 5000)
    f.wake(5000 + 199)
    discard f.stepFade(On, 5000 + 199)
    ck f.level < 0.2
    discard f.stepFade(On, 5000 + 199 + 16)
    ck f.level > 0.0 and f.level < 1.0

  test "a wake while fading out turns the fade round":
    var f = initFade(0)
    discard f.stepFade(On, FadeAfterMs + FadeOutMs div 2)
    let low = f.level
    ck low > 0.0 and low < 1.0
    f.wake(FadeAfterMs + FadeOutMs div 2)
    discard f.stepFade(On, FadeAfterMs + FadeOutMs div 2 + 16)
    ck f.level > low

  test "held, the bar stays; fade off and reduce-motion jump to the end":
    var f = initFade(0)
    for t in countup(0'i64, 5000'i64, 16'i64):
      discard f.stepFade(On, t, held = true)
    ck f.level == 1.0
    var off = On
    off.fade = false
    var g = initFade(0, visible = false)
    ck not g.stepFade(off, 10)
    ck g.visibility(off) == 1.0
    var rm = On
    rm.reduceMotion = true
    var h = initFade(0)
    ck not h.stepFade(rm, FadeAfterMs + 1)
    ck h.level == 0.0
    h.wake(FadeAfterMs + 2)
    ck not h.stepFade(rm, FadeAfterMs + 3)
    ck h.level == 1.0

  test "the eased curve is monotonic and pinned at its ends":
    ck easeFade(0.0) == 0.0 and easeFade(1.0) == 1.0
    var prev = -1.0
    for i in 0 .. 100:
      let v = easeFade(float(i) / 100.0)
      ck v >= prev
      prev = v

  test "nextFadeMs is when a resting bar starts to fade":
    var f = initFade(500)
    ck f.nextFadeMs(On) == 500 + FadeAfterMs
    var off = On
    off.fade = false
    ck f.nextFadeMs(off) == -1

suite "PLAT-70 Part H: the grab keeps its offset":

  test "a thumb grabbed at any point stays under the pointer by that point":
    var cases, kept = 0
    for total in [40, 200, 10_000]:
      for visible in [10, 30]:
        for top in [0, total div 3]:
          let m = scrubberModel(total, top, visible)
          for k in 0 .. 4:
            # Grab at a point k/4 along the thumb.
            let at = m.thumbStart + m.thumbLength * float(k) / 4.0
            let offset = m.grabOffset(at)
            ck abs(offset - m.thumbLength * float(k) / 4.0) < 1e-9
            # Not moved: the view does not move.
            ck m.grabbedTop(at, offset) == m.dragTo(m.thumbStart)
            # Moved by d: the thumb's start moved by d.
            for d in [-0.2, 0.05, 0.3]:
              inc cases
              let want = m.dragTo(m.thumbStart + d)
              if m.grabbedTop(at + d, offset) == want: inc kept
    ck kept == cases
    # The jump's grab is the thumb's middle.
    let m = scrubberModel(1000, 0, 50)
    ck m.jumpGrabOffset == m.thumbLength / 2.0

suite "PLAT-70 Part H: paging toward the pointer":

  test "pages one view less one, repeated until the thumb reaches the pointer":
    for total in [100, 1000]:
      for visible in [10, 37]:
        for target in [0.95, 0.5]:
          var m = scrubberModel(total, 0, visible)
          let dir = m.pageDirection(target)
          ck dir == 1
          var pages = 0
          while true:
            let top = m.pageToward(target, dir)
            if top < 0: break
            ck top - m.firstVisible == min(m.pageSize,
                                           m.maxFirstVisible - m.firstVisible)
            m = scrubberModel(total, top, visible)
            inc pages
            ck pages < 1000
          # Stopped where the thumb reached the pointer — not past it.
          ck m.pageDirection(target) != 1
          ck m.thumbStart <= target
          # And it never turns round.
          ck m.pageToward(target, dir) == -1
    let m = scrubberModel(100, 50, 10)
    ck m.pageDirection(0.0) == -1
    ck m.pageToward(0.0, -1) == 41
    ck m.pageDirection(m.thumbStart + m.thumbLength / 2.0) == 0
    ck m.pageToward(0.5, 0) == -1

  test "the held press repeats after the delay, then at the repeat rate":
    var h: TrackHold
    h.start(0.9, 1, 1000)
    ck h.active
    ck not h.due(1000 + RepeatDelayMs - 1)
    ck h.due(1000 + RepeatDelayMs)
    h.repeated(1000 + RepeatDelayMs)
    ck not h.due(1000 + RepeatDelayMs + RepeatEveryMs - 1)
    ck h.due(1000 + RepeatDelayMs + RepeatEveryMs)
    var none: TrackHold
    none.start(0.5, 0, 0)
    ck not none.active
    ck tcJump.otherRule == tcPage and tcPage.otherRule == tcJump

suite "PLAT-70 Part H: the scrollbar settings":

  test "every value of every setting round-trips through every form":
    var forms = 0
    for which in LayoutSetting:
      ck settingValues(which).len >= 2
      for value in settingValues(which):
        let sl = parseSetLine(":set " & $which & " " & value)
        ck sl.isSet and sl.ok and sl.setting == which and sl.value == value
        let flag = parseSettingFlag("--" & $which & "=" & value)
        ck flag.isFlag and flag.ok and flag.word == value
        let target = parseSettingCommandTarget(settingCommandTarget(which, value))
        ck target.ok and target.setting == which and target.value == value
        var s = defaultLayoutSettings()
        ck s.assignValue(which, value)
        ck s.valueText(which) == value
        let back = decodeLayoutSettings(encodeLayoutSettings(s))
        ck back.ok and back.settings == s
        ck settingCommandLabel(which, value).endsWith(": " & value)
        inc forms
    ck forms == 2 + 2 + 2 + 4 + 2 + 2 + 2 + 2

  test "the defaults are §7.1's":
    let d = defaultLayoutSettings()
    ck d.scrollbars == DefaultScrollbarOptions
    ck d.scrollbars.thickness == btHairline and d.scrollbars.fade and
       not d.scrollbars.track and d.scrollbars.click == tcJump and
       not d.scrollbars.modernUnicode
    ck d.valueText(lsScrollbarThickness) == "hairline"
    ck d.valueText(lsScrollbarFade) == "on"
    ck d.valueText(lsScrollbarTrack) == "off"

  test "a value outside the list is refused by name":
    let sl = parseSetLine(":set scrollbar-thickness huge")
    ck sl.isSet and not sl.ok
    ck sl.message.contains("huge") and sl.message.contains("hairline") and
       sl.message.contains("full")
    let flag = parseSettingFlag("--scrollbar-click=drag")
    ck flag.isFlag and not flag.ok and flag.message.contains("jump")
    let bare = parseSettingFlag("--scrollbar-thickness")
    ck bare.isFlag and not bare.ok and bare.message.contains("=thin")
    let stored = decodeLayoutSettings("scrollbar-thickness=huge\n")
    ck not stored.ok and stored.message.contains("scrollbar-thickness=huge")
    var s = defaultLayoutSettings()
    ck not s.assignValue(lsScrollbarFade, "maybe")
    ck s == defaultLayoutSettings()

suite "PLAT-70 Part H: assertion count":
  test "every assertion ran":
    check CHECKS == ExpectedAssertions
