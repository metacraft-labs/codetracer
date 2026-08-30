## The web build's entry point — NS2, and the first thing in the tree that
## calls `boot()`.
##
## ## What this is, and what it deliberately is not
##
## NS2 built the web instantiation, the project store, the durability model and
## the URL entry layer, and then left them unreachable: its own HONEST RESIDUAL
## says "nothing is wired to a running application ... `boot()` assembles
## persistence, volume, store and platform in the order §4.2 and §4.5 require,
## and no entry point calls it". This module is that entry point.
##
## It is **not** the product's UI, and pretending otherwise would be the more
## damaging kind of progress. Rendering panes means `renderer.nim`, which
## imports `platform_host`, which imports `host/desktop_electron` under
## `when defined(js)` — so a browser build of the current renderer links
## `require('child_process')` and `require('fs')`. Splitting that import into a
## three-way switch is real work with its own risks, and doing it badly would
## produce a bundle that loads and then behaves like a desktop build, which is
## exactly the failure this campaign keeps finding.
##
## So the scope here is the boot sequence and nothing else: request
## persistence, choose a volume, open the store, install the platform, and make
## the outcome **observable**. That is the whole of what "the web build runs"
## can honestly mean today, and it is a bundle that a CI recipe produces and a
## smoke test executes.
##
## ## Why this module does not import `platform_host`
##
## It would be the natural way to install the platform, and it is the one thing
## that must not happen here: `platform_host` imports `desktop_electron` on the
## JS backend, so importing it would pull Electron's host bindings into the web
## bundle. `boot()` installs through `platform.installPlatform` instead, and
## `ctPlatform()` was taught not to overwrite that
## (`tests/platform_bootstrap_test.nim`). The absence of the import is
## load-bearing, which is why it is written down rather than left to look like
## an oversight.
##
## ## Why the outcome is reported twice
##
## A page wants it in the DOM; a smoke test running under node has no DOM. Both
## are the same fact, so both come from one call: the console line is the
## contract `ci/test/web-bundle-smoke.sh` asserts on, and the DOM write is what
## a page shows. Neither is a fallback for the other — a browser produces both.

import std/[asyncjs, jsffi]

import viewmodel/host/web_browser

const bootLinePrefix* = "codetracer-web-boot:"
  ## The smoke test greps for this. A stable prefix rather than a parsed
  ## structure, because the test's question is "did it boot, and into which
  ## storage condition" — two facts, not a protocol.

proc jsReport(line: cstring) {.importjs: """
(function (s) {
  try { if (typeof console !== 'undefined') { console.log(s); } } catch (e) {}
  try {
    if (typeof document !== 'undefined') {
      var el = document.getElementById('codetracer-boot');
      if (el) { el.textContent = s; }
    }
  } catch (e) {}
})(#)""".}
  ## The value is bound ONCE, as the IIFE's argument, and used twice as `s`.
  ##
  ## Writing `#` at both use sites does not work and does not fail quietly: a
  ## bare `#` consumes the *next* parameter, so the second one asks for an
  ## argument this proc does not have and the module does not compile
  ## (`wrong importcpp pattern; expected parameter at position 2`). `#1` is not
  ## honoured in this position either. Binding once is also the better shape —
  ## the two sites are the same value by construction rather than by matching
  ## spellings.

proc describe(boot: WebBoot): string =
  ## One line, deliberately: a boot that half-worked must not be reportable as
  ## two half-lines that a reader assembles differently than a test does.
  if not boot.ok:
    return bootLinePrefix & " refused condition=" & $boot.condition &
           " reason=" & boot.refusal
  bootLinePrefix & " ok condition=" & $boot.condition &
    " announcement=" & (if boot.announcement.len > 0: boot.announcement
                        else: "(none)")

proc startWebSession*(): Future[WebBoot] {.async.} =
  ## Boot, report, and hand the result back.
  ##
  ## Returns the `WebBoot` rather than swallowing it so a caller — the page's
  ## eventual UI, or a test — can act on `condition` and `announcement`. §4.2's
  ## gate is unchanged and is not this module's to open: `readyForEditing` stays
  ## false until something calls `acknowledgeDurability`, and the facade's
  ## writes refuse until it does. An entry point that acknowledged on the user's
  ## behalf would defeat the one mechanism standing between a volatile session
  ## and silent data loss.
  let booted = await boot()
  jsReport(describe(booted).cstring)
  return booted

when isMainModule:
  discard startWebSession()
