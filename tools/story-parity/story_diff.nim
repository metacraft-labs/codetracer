## story_diff — compare one renderer's capture of a story with the DOM
## arm's, pixel by pixel and region by region.
##
##   story_diff <reference.png> <candidate.png> [--regions=<json>]
##              [--json=<out.json>] [--heat=<out.png>]
##
## A pixel *differs* when any of its R, G, B channels differs at all; the
## harness's target is zero such pixels. The report also gives how far the
## differing pixels are off (the largest channel difference, in four bands),
## because a residual made only of a few levels on glyph edges and one made
## of wrong colours are different findings, and codetracer-image-diff's FLIP
## mean, the perceptual measure PLAT-35 used.
##
## Regions are the DOM arm's (`capture-dom.mjs --regions`), in CSS pixels,
## scaled by the capture's scale. Each region's differing pixels are counted
## on their own; pixels in no region count as `outside`.
##
## `--heat` writes the reference dimmed to a quarter with every differing
## pixel in red, so a reader sees where.
##
## Exit status: 0 when both images were read and compared (whatever the
## count), 2 when they could not be (a missing file, different sizes).

import std/[json, os, parseopt, strutils]

import ../../src/common/png
import image_diff

type
  Band = enum bExact, bFaint, bModerate, bStrong
  Region = object
    name: string
    x0, y0, x1, y1: int
    differing: int
    area: int

const BandNames = ["0", "1-8", "9-32", "33-255"]

func band(d: int): Band =
  if d == 0: bExact elif d <= 8: bFaint elif d <= 32: bModerate else: bStrong

proc load(path: string): DecodedPng =
  if not fileExists(path): quit("story_diff: no image at " & path, 2)
  decodePng(readFile(path))

proc main() =
  var paths: seq[string]
  var regionsPath, jsonPath, heatPath: string
  for kind, key, value in getopt():
    case kind
    of cmdArgument: paths.add key
    of cmdLongOption:
      case key
      of "regions": regionsPath = value
      of "json": jsonPath = value
      of "heat": heatPath = value
      else: quit("story_diff: unknown option --" & key, 2)
    else: discard
  if paths.len != 2:
    quit("usage: story_diff <reference.png> <candidate.png> [--regions=] [--json=] [--heat=]", 2)
  let a = load(paths[0])
  let b = load(paths[1])
  if a.width != b.width or a.height != b.height:
    let msg = "sizes differ: " & $a.width & "x" & $a.height & " against " & $b.width & "x" & $b.height
    if jsonPath.len > 0:
      writeFile(jsonPath, $(%*{"comparable": false, "reason": msg}))
    quit("story_diff: " & msg, 2)
  let w = a.width
  let h = a.height

  var regions: seq[Region]
  if regionsPath.len > 0 and fileExists(regionsPath):
    let doc = parseJson(readFile(regionsPath))
    let scale = doc{"scale"}.getFloat(1.0)
    for r in doc["regions"]:
      let x0 = max(0, int(r["x"].getFloat * scale))
      let y0 = max(0, int(r["y"].getFloat * scale))
      let x1 = min(w, int((r["x"].getFloat + r["w"].getFloat) * scale))
      let y1 = min(h, int((r["y"].getFloat + r["h"].getFloat) * scale))
      if x1 > x0 and y1 > y0:
        regions.add Region(name: r["name"].getStr, x0: x0, y0: y0, x1: x1, y1: y1,
                           area: (x1 - x0) * (y1 - y0))

  var bands: array[Band, int]
  var differing, outside = 0
  var heat = newSeq[uint8](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = (y * w + x) * 4
      var d = 0
      for c in 0 .. 2: d = max(d, abs(int(a.rgba[i + c]) - int(b.rgba[i + c])))
      inc bands[band(d)]
      if d > 0:
        inc differing
        var inAny = false
        for r in regions.mitems:
          if x >= r.x0 and x < r.x1 and y >= r.y0 and y < r.y1:
            inc r.differing
            inAny = true
        if not inAny: inc outside
        heat[i] = 255; heat[i + 1] = 0; heat[i + 2] = 0
      else:
        for c in 0 .. 2: heat[i + c] = a.rgba[i + c] div 4
      heat[i + 3] = 255

  let f = flip(a.rgba, b.rgba, w, h, 4)

  var report = %*{
    "comparable": true,
    "width": w, "height": h,
    "differing": differing,
    "differingFraction": differing.float / float(w * h),
    "outsideRegions": outside,
    "flipMean": f.mean, "flipP99": f.p99,
  }
  var bandJson = newJObject()
  for bnd in Band: bandJson[BandNames[ord(bnd)]] = %bands[bnd]
  report["maxChannelDifference"] = bandJson
  var regionJson = newJArray()
  for r in regions:
    regionJson.add %*{"name": r.name, "differing": r.differing, "area": r.area,
                      "box": [r.x0, r.y0, r.x1 - r.x0, r.y1 - r.y0]}
  report["regions"] = regionJson
  if jsonPath.len > 0: writeFile(jsonPath, report.pretty)
  if heatPath.len > 0:
    let problem = writePng(heatPath, w, h, heat)
    if problem.len > 0: quit("story_diff: " & problem, 2)
  echo "differing ", differing, " of ", w * h, " px (",
    formatFloat(100.0 * differing.float / float(w * h), ffDecimal, 2), "%), FLIP mean ",
    formatFloat(f.mean, ffDecimal, 4)
  for r in regions:
    echo "  ", r.name.alignLeft(28), " ", r.differing, " / ", r.area

when isMainModule:
  main()
