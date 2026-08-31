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
## ## Why this module DOES import `platform_host`, and why that was once wrong
##
## The first version of this file deliberately avoided `platform_host`, because
## that module's `when defined(js)` arm imported `host/desktop_electron` — so
## importing it pulled `require('fs')` and `require('child_process')` into the
## web bundle. Measured: 43 `require(` calls. The web build therefore had to
## route around the front end's own platform accessor, which is not something a
## second platform instantiation should ever have to do; every other module in
## `src/frontend/` reaches the platform through `ctPlatform()`, and a web build
## that could not was a web build no pane could ever be shared with.
##
## `platform_host` is a three-way switch now (`js` + `ctWeb`, `js`, native), and
## its web arm imports no host module at all. So this module imports it like
## anything else, and the bundle still contains zero `require(` — which
## `ci/test/web-bundle-smoke.sh` measures rather than assumes, and which is now
## a check on the SWITCH rather than on this file's import list.
##
## The assertion below is the point: after `boot()`, `ctPlatform()` must hand
## back the web platform. That is one call, and it is the difference between
## "the web instantiation exists" and "the front end is running on it".
##
## ## Why the outcome is reported twice
##
## A page wants it in the DOM; a smoke test running under node has no DOM. Both
## are the same fact, so both come from one call: the console line is the
## contract `ci/test/web-bundle-smoke.sh` asserts on, and the DOM write is what
## a page shows. Neither is a fallback for the other — a browser produces both.

import std/[asyncjs, jsffi]

import viewmodel/host/web_browser
import platform_host

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
  # `ctPlatform()` is asked here rather than `boot.web.platform`, and the
  # difference is the whole assertion: the first goes through the front end's
  # own accessor, which every pane uses, and is what would have handed back the
  # ELECTRON platform on this build until the switch and the bootstrap fix.
  # Reporting `boot.web.platform.profile.kind` instead would say `web` even
  # when the front end at large could not see it.
  let running = ctPlatform()
  bootLinePrefix & " ok condition=" & $boot.condition &
    " platform=" & $running.profile.kind &
    " spawn=" & $running.can(capProcessSpawn) &
    # WHAT THIS DEPLOYMENT ACTUALLY DELIVERED, and the reason the line grew a
    # field. Every other clause here is a property of the BUILD, and a build is
    # not a deployment: the same `web.js` reports an identical line whether it
    # was served alongside 20 MB of Noir wasm or alongside nothing. So a page
    # that had silently lost its modules was indistinguishable from a correct
    # one, which is precisely how a sibling campaign shipped a replay engine no
    # page referenced and read every dead session as "the engine is stale".
    #
    # `toolchain=(none)` is a legitimate and common value — most builds ship no
    # modules and say so. What matters is that it is SAID, so "the deployment
    # delivers no compiler" and "the compiler is broken" are different lines
    # rather than the same shrug.
    " toolchain=" & (if boot.toolchain.len > 0: boot.toolchain else: "(none)") &
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
