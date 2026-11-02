## codetracer/docs/book-isonim -- the "Setting up your terminal" page
## (`usage_guide/terminal-setup.md`, PLAT-71; CodeTracer-TUI-Terminal-
## Adaptation.md §11), rendered through the same `renderRoute` shell
## `just build` takes:
##
##   * the page is routed, in the Usage Guide, with the standard docs layout;
##   * it carries §11's eight sections, in §11's order;
##   * its tmux block holds every line §11.4 lists, each with the feature it
##     enables;
##   * its options table is the terminal front-end's OWN list of settings —
##     every terminal setting the shared settings module declares
##     (`layout_settings.isTerminalSetting`), each with exactly the values
##     that module accepts — so a setting added or a value renamed in the
##     product reddens this page's test instead of leaving the page stale;
##   * the report's source column names every source a report line can say
##     (`CapabilitySource`, the terminal front-end's own enum).
##
## No mocks: the book's own renderer over its own content, and the product's
## own settings module.

import std/[unittest, strutils, sequtils, os]
import core/[content]
import ../src/ssr
import ../../../src/frontend/viewmodel/viewmodels/layout_settings
import ../../../src/frontend/tui/app/theme/capabilities

const Route = "/usage_guide/terminal-setup"

proc pageSource(): string =
  readFile(currentSourcePath().parentDir().parentDir() /
           "content/usage_guide/terminal-setup.md")

proc tableRows(md, firstHeader: string): seq[seq[string]] =
  ## The body rows of the Markdown table whose header starts `firstHeader`.
  var inTable = false
  for line in md.splitLines():
    let t = line.strip()
    if not inTable:
      if t.startsWith("| " & firstHeader):
        inTable = true
      continue
    if not t.startsWith("|"):
      break
    if t.startsWith("|---"):
      continue
    result.add t.strip(chars = {'|'}).split('|').mapIt(it.strip())

suite "book: Setting up your terminal (Terminal-Adaptation §11)":
  let (status, html) = renderRoute(Route, "content")
  let md = pageSource()

  test "the page is routed in the Usage Guide, standard layout":
    check status == 200
    check html.contains("Setting up your terminal")
    check html.contains("The four things that matter most")
    check html.contains("allow-passthrough")
    check html.contains("id=\"docs-region-nav\"")
    check not html.contains("docs-frame--minimal")
    let entries = loadContentEntries(currentSourcePath().parentDir()
                                       .parentDir() / "content")
    var found = false
    for e in entries:
      if e.routePath == Route:
        found = true
        check e.section == "usage_guide"
    check found

  test "§11's eight sections, in order":
    let sections = ["## 1. Check", "## 2. The four things that matter most",
                    "## 3. Per terminal", "## 4. tmux", "## 5. SSH and mosh",
                    "## 6. CJK and ambiguous width", "## 7. The options",
                    "## 8. When something looks wrong"]
    var at = -1
    for s in sections:
      let next = md.find("\n" & s & "\n")
      checkpoint(s)
      check next > at
      at = next
    check md.contains("ct doctor terminal")
    check md.contains("--capabilities=json")
    check md.contains("--no-probe")
    check md.contains("--glyphs=basic") and md.contains("--glyphs=ascii")

  test "§11.4: every tmux line, each with what it enables":
    for line in ["set -g mouse on",
                 "set -as terminal-features ',<your-term>*:RGB'",
                 "set -g extended-keys on",
                 "set -g allow-passthrough on",
                 "set -g set-clipboard on",
                 "set -g focus-events on"]:
      checkpoint(line)
      var commented = false
      for l in md.splitLines():
        if l.startsWith(line) and l.contains("# "):
          commented = true
      check commented

  test "§7's table is the product's terminal settings and their values":
    let rows = tableRows(md, "Setting")
    var documented: seq[string] = @[]
    for r in rows:
      check r.len == 3
      let name = r[0].strip(chars = {'`'})
      documented.add name
      var known = false
      for s in LayoutSetting:
        if $s == name:
          known = true
          checkpoint(name)
          check s.isTerminalSetting
          let values = r[1].split(',').mapIt(it.strip().strip(chars = {'`'}))
          check values == settingValues(s)
      check known
    for s in LayoutSetting:
      if s.isTerminalSetting:
        checkpoint($s)
        check $s in documented

  test "the report's sources, every one named":
    let rows = tableRows(md, "Source")
    let named = rows.mapIt(it[0].strip(chars = {'`'}))
    # Exactly the sources a report line can name (`CapabilitySource`).
    var sources: seq[string] = @[]
    for c in CapabilitySource: sources.add $c
    check named.len == sources.len
    for c in sources:
      checkpoint(c)
      check c in named
    # And the report example shows a source on its lines.
    check md.contains("(probe)") and md.contains("(default")
