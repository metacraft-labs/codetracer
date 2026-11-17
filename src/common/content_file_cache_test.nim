## content_file_cache_test.nim — the generated-file cache the GPUI icons are
## drawn from (`content_file_cache.nim`).
##
## Runs against the real filesystem, in the scratch `CODETRACER_HOME` every
## test program gets (`test_support/state_isolation.nim`), so `ctCacheDir`
## is a directory this run owns. No mocks.

import std/[os, strutils, unittest]

import ./content_file_cache
import ./ct_home

proc filesIn(dir: string): seq[string] =
  for kind, path in walkDir(dir):
    if kind == pcFile: result.add path.extractFilename

suite "content_file_cache":

  test "the cache is the per-user one, which CODETRACER_HOME relocates":
    check contentFileDir("icons") == ctCacheDir() / "icons"
    let home = getEnv("CODETRACER_HOME")
    check home.len > 0 # the harness isolated this run
    check contentFileDir("icons").startsWith(home)

  test "the same content is one file at one path, however often it is asked for":
    let area = "same-content"
    let a = contentFile(area, "plus-b0b0b0.svg", "<svg>plus</svg>")
    let b = contentFile(area, "plus-b0b0b0.svg", "<svg>plus</svg>")
    check a == b
    check readFile(a) == "<svg>plus</svg>"
    check filesIn(contentFileDir(area)) == @[a.extractFilename]

  test "a different content under the same name is a different file":
    # One name in two inks must not be one file overwritten under a path
    # GPUI has already cached.
    let area = "two-inks"
    let dark = contentFile(area, "state-copy.svg", "<svg fill=\"#ddd\"/>")
    let light = contentFile(area, "state-copy.svg", "<svg fill=\"#333\"/>")
    check dark != light
    check readFile(dark) == "<svg fill=\"#ddd\"/>"
    check readFile(light) == "<svg fill=\"#333\"/>"
    check filesIn(contentFileDir(area)).len == 2

  test "the name keeps its stem and extension, the digest goes between":
    let n = contentFileName("tab-close-light.png", "x")
    check n.startsWith("tab-close-light-")
    check n.endsWith(".png")
    check n.len == "tab-close-light-".len + 16 + ".png".len
    check contentFileName("a.svg", "x") == contentFileName("a.svg", "x")
    check contentFileName("a.svg", "x") != contentFileName("a.svg", "y")

  test "a stored name gives back the name it was asked for":
    for name in ["plus-b0b0b0.svg", "call-collapse-active.svg", "a.png", "x"]:
      check nameOfContentFile(contentFileName(name, "<svg/>")) == name
    # A name without the cache's digest is not shortened.
    check nameOfContentFile("window-restore.svg") == "window-restore.svg"
    check nameOfContentFile("bar-0123456789abcdeg.svg") ==
      "bar-0123456789abcdeg.svg" # not hex
    check nameOfContentFile("bar-0123456789ABCDEF.svg") ==
      "bar-0123456789ABCDEF.svg" # the digest is lower case
    check nameOfContentFile("-0123456789abcdef.svg") ==
      "-0123456789abcdef.svg" # no stem before it

  test "a file at the path that holds anything else is rewritten, not drawn":
    let area = "stale"
    let content = "<svg>the real icon</svg>"
    let path = contentFileDir(area) / contentFileName("icon.svg", content)
    createDir(contentFileDir(area))
    writeFile(path, "<svg>trunc") # truncated, or another content's collision
    check contentFile(area, "icon.svg", content) == path
    check readFile(path) == content
    # Nothing is left behind by the atomic write.
    check filesIn(contentFileDir(area)) == @[path.extractFilename]

  test "a verified file that has gone since is written again":
    let area = "deleted"
    let path = contentFile(area, "icon.svg", "<svg>kept</svg>")
    removeFile(path)
    check contentFile(area, "icon.svg", "<svg>kept</svg>") == path
    check readFile(path) == "<svg>kept</svg>"

  test "an area or name that is not a plain file name is refused":
    for (area, name) in [("", "a.svg"), ("icons", ""), ("../up", "a.svg"),
                         ("icons", "sub/a.svg"), ("..", "a.svg"),
                         ("icons", "..")]:
      expect ValueError:
        discard contentFile(area, name, "x")
