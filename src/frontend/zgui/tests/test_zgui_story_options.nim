## test_zgui_story_options.nim — `codetracer-zgui-story`'s command line.
##
## The story-parity harness passes `--title="$title"`, and a layout story has no tab title, so
## the host sees `--title=` with an empty value followed by `--width=1100`. Nim's `parseopt`
## took the next argument as the empty option's value by default, so the width was lost and the
## host drew at its default 1600: CI's default-debug captures came out 1600x760 against the DOM
## arm's 1100x760 and could not be compared (codetracer run 45804661393).

import std/[strutils, unittest]
import ../story_options

var countedAssertions = 0
const ExpectedAssertions = 12

template ck(condition: untyped) =
  inc countedAssertions
  check condition

suite "codetracer-zgui-story's options":
  test "an empty --title does not take the next option as its value":
    let o = parseOptions(@["--story=layout/default-debug/populated", "--title=",
                           "--width=1100", "--height=760", "--scale=1", "--out=x.png"])
    ck o.title == ""
    ck o.width == 1100
    ck o.height == 760
    ck o.scale == 1.0

  test "the harness's whole argument list, as it passes it":
    let o = parseOptions(@["--story=panel/calltrace/populated", "--title=Calltrace",
                           "--width=1920", "--height=1080", "--scale=2",
                           "--build-root=/b", "--out=/o/zgui.png"])
    ck o.kind == "panel" and o.surface == "calltrace" and o.fixture == "populated"
    ck o.title == "Calltrace"
    ck (o.width, o.height, o.scale) == (1920, 1080, 2.0)
    ck o.buildRoot == "/b" and o.outPath == "/o/zgui.png"

  test "defaults, and refusals":
    let o = parseOptions(@["--story=panel/event-log", "--out=e.png"])
    ck (o.width, o.height, o.scale, o.fixture, o.theme) == (1600, 1000, 1.0, "populated", "dark")
    expect ValueError: discard parseOptions(@["--story=panel", "--out=e.png"])
    ck true
    expect ValueError: discard parseOptions(@["--story=panel/x", "--out=e.png", "--colour=red"])
    ck true
    expect ValueError: discard parseOptions(@["--story=panel/x"])
    ck true

  test "every assertion ran":
    check countedAssertions == ExpectedAssertions
