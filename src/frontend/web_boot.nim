## The web build's boot sequence and its one-line account of itself.
##
## ## Why this is a module and not the top of `web_main.nim`
##
## Because it now has two callers, and until NS9 it had one — which is the
## whole of the defect this module was carved out to fix.
##
## `boot()` installs the web platform by calling `installPlatform`, and
## `installPlatform` writes a module-level `var installedPlatform` in
## `viewmodel/platform/platform.nim`. A `nim js` program gets ONE of those
## vars. Two separately compiled programs get two, and no amount of care makes
## them the same one: `ci/test/web-bundle-assets.sh` wraps each deployed bundle
## in its own IIFE precisely so that `ui.js` stops redefining 196 of `web.js`'s
## functions and 85 of its type tables, and that scoping — which is
## load-bearing, and is mutation arm C of `ci/test/web-renderer-mounts.sh` —
## is exactly what guarantees the two `installedPlatform`s can never meet.
##
## So the deployment used to boot the platform in `web.js` and render in
## `ui.js`, and the renderer's `ctPlatform()` returned the refusing
## `uninstalledProfile` on every load. `web-bundle-assets.sh` said so in its
## own words: "the two arms still cannot share Nim state, so the renderer
## cannot see the platform, project store or wasm registry that `web.js`
## booted. That is one bundle's worth of work and it is NS9's."
##
## ## Why a bridge over `window` was rejected rather than not considered
##
## The obvious cheaper fix is to publish the booted platform on `window` from
## `web.js` and read it from `ui.js`. It does not work, and the reason is a
## property of the code generator rather than a matter of taste.
##
## `Platform` is a Nim object whose fields are closures, and those closures
## construct and consume Nim values — `PlatformOutcome[T]`, `seq`, `JsonNode`,
## `WasmRegistry`. `nim js` gives every such value an `m_type` pointing into
## the *defining bundle's* `NTI*` tables, and every generic operation on it
## (`nimCopy`, `chckIndx`, the variant-field checks) is resolved against the
## reader's tables. Hand a `web.js` value to `ui.js` code and those two
## disagree. That is not a prediction; it is the failure already recorded in
## `web-bundle-assets.sh`'s header, which is what unwrapping the IIFEs
## produces:
##
##     field 'elems' is not accessible for type 'JsonNodeObj'
##     using 'kind = JArray'   at web_browser.deploymentDescriptor
##
## A bridge could carry flat JavaScript — strings, numbers, plain objects — and
## the thing the renderer needs is none of those. It needs `ctPlatform()` to
## answer with a platform whose `wasm` facade it can then CALL. So the bridge
## would have to re-implement the facade on the far side, in which case it is
## not a bridge, it is a second instantiation.
##
## ONE BUNDLE IS THEREFORE NOT THE EXPENSIVE OPTION, IT IS THE ONLY SOUND ONE.
## And it is cheap, because the loop arm was never large: everything below is
## `web_main.nim`'s entire body. What changes is that `ui_js.nim`'s web arm
## calls it too, in the same program, so the `installedPlatform` the renderer
## reads is the one `boot()` wrote.
##
## ## Why `web_main.nim` still exists
##
## `ci/test/web-bundle-smoke.sh` builds it with `nim js -d:nodejs -d:ctWeb` and
## runs the result under node, which is a genuinely different check from the
## browser gate: it drives §4.2's third row (no OPFS, in-memory volume, a
## session that announces it will lose work) without a browser, and it asserts
## the bundle contains no `require(` of a node built-in. Keeping a headless
## entry point for the boot sequence costs one four-line file and keeps that
## gate pointed at the boot sequence rather than at a renderer.

when not defined(js):
  {.error: "web_boot.nim is part of the web instantiation; it is compiled " &
           "only by `nim js -d:ctWeb` builds".}

import std/[asyncjs]

import viewmodel/host/web_browser
import platform_host

export web_browser

const bootLinePrefix* = "codetracer-web-boot:"
  ## `ci/test/web-bundle-smoke.sh` and `ci/test/web-renderer-mounts.sh` both
  ## grep for this. A stable prefix rather than a parsed structure, because the
  ## question both ask is "did it boot, and into which storage condition" — two
  ## facts, not a protocol.

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

proc describeBoot*(boot: WebBoot): string =
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
  #
  # THAT IS NOW THE LOAD-BEARING SENTENCE RATHER THAN A PRECAUTION. In the
  # merged bundle this line runs in the same program as the renderer, so
  # `platform=pkWeb` on the console is the renderer's OWN `ctPlatform()`
  # answering — the fact `ci/test/web-renderer-mounts.sh`'s reach arm then
  # confirms from inside a mounted surface.
  let running = ctPlatform()
  bootLinePrefix & " ok condition=" & $boot.condition &
    " platform=" & $running.profile.kind &
    # `spawn` IS THE WASM REGISTRY, READ THROUGH THE FRONT END'S OWN ACCESSOR,
    # and that is worth stating because the field looks like a formality.
    #
    # `web_platform.newWebPlatform` narrows the profile when the registry is
    # empty — "the profile follows the registry", and it subtracts
    # `capProcessSpawn` and `capProcessSignal` with a `webNoModulesLoaded`
    # degradation. So `spawn=true` read off `ctPlatform()` is not a claim about
    # the document's descriptor; it is the statement that the platform THIS
    # PROGRAM will hand a Build button has a non-empty `WasmHost.registry`.
    # `toolchain=` below is the other half — what the deployment delivered —
    # and the two being different is exactly the state that shipped: a
    # descriptor naming two Noir modules beside a renderer holding
    # `uninstalledProfile`, which reports `spawn=false`.
    " spawn=" & $running.can(capProcessSpawn) &
    # WHAT THIS DEPLOYMENT ACTUALLY DELIVERED, and the reason the line grew a
    # field. Every other clause here is a property of the BUILD, and a build is
    # not a deployment: the same bundle reports an identical line whether it
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
    # WHICH ADDRESS THIS TAB WAS OPENED ON, and what the product decided it
    # means. Added for the same reason `toolchain` was, one defect later: the
    # bundle is byte-identical at every URL it serves, so "the entry layer ran"
    # and "the entry layer is dead code" were indistinguishable from outside —
    # and the second was true for the whole life of the deployment. A user
    # typing `/noir` reached the welcome screen and nothing anywhere said why.
    #
    # `efBare/evTemplate/noir` is the value that answers the bug report. It is
    # on the same line as the rest because a reader comparing two runs should
    # not have to correlate two lines to see which one routed.
    " entry=" & describeEntry(boot.entry) &
    " announcement=" & (if boot.announcement.len > 0: boot.announcement
                        else: "(none)")

proc describeRunningPlatform*(): string =
  ## What `ctPlatform()` hands back, as one clause for the RENDERER's line.
  ##
  ## ## Why this is here rather than spelled out at the call site
  ##
  ## `ui_js.nim` has ~200 imports and no view of the platform facade at all;
  ## reaching `ctPlatform().profile.kind` and `can(capProcessSpawn)` from there
  ## means importing `platform_host` and `capabilities` into a module whose
  ## import list is already the tree's most collision-prone. One proc keeps
  ## that surface at one symbol.
  ##
  ## ## Why the RENDERER says this and not only `boot()`
  ##
  ## Because they were different facts until this milestone, and the whole
  ## defect lived in the gap. `boot()` reported `platform=pkWeb` from `web.js`
  ## and was telling the truth about `web.js`; the renderer in `ui.js` held a
  ## separate `installedPlatform` that nothing had ever written, so a Build
  ## button would have found `pkHeadless` with every capability absent. Two
  ## programs, two answers, and only one of them was ever printed.
  ##
  ## Now there is one program, so this clause and the boot line's must agree —
  ## and `ci/test/web-renderer-mounts.sh` asserts that they do, which is a
  ## check that could not even be written before.
  let running = ctPlatform()
  " platform=" & $running.profile.kind &
    # `run` IS THE WASM REGISTRY. `web_platform.newWebPlatform` subtracts
    # `capProcessSpawn` when `bridge.wasm.registry.modules.len == 0` — "the
    # profile follows the registry" — so `run=true` read here is the statement
    # that the platform THIS RENDERER will hand a Build button has a non-empty
    # `WasmHost`, and `run=false` is the statement that it has not. It is not a
    # claim about the descriptor; the boot line's `toolchain=` is that, and the
    # gate asserts the two agree.
    " run=" & $running.can(capProcessSpawn)

proc bootAndReport(): Future[WebBoot] {.async.} =
  let booted = await boot()
  jsReport(describeBoot(booted).cstring)
  return booted

var sessionFuture: Future[WebBoot]
var sessionStarted = false

proc startWebSession*(): Future[WebBoot] =
  ## Boot, report, and hand the result back — ONCE, however many times this is
  ## called.
  ##
  ## Returns the `WebBoot` rather than swallowing it so a caller — the
  ## renderer, or a headless test — can act on `condition` and `announcement`.
  ## §4.2's gate is unchanged and is not this module's to open:
  ## `readyForEditing` stays false until something calls
  ## `acknowledgeDurability`, and the facade's writes refuse until it does. An
  ## entry point that acknowledged on the user's behalf would defeat the one
  ## mechanism standing between a volatile session and silent data loss.
  ##
  ## ## Why it is memoised, and why that is not just hygiene
  ##
  ## `boot()` requests persistence, opens an OPFS store and installs a
  ## platform. Running it twice would open the store twice and install twice,
  ## and the second install would replace a platform the renderer may already
  ## be holding. One future, handed to every caller, makes "has the session
  ## booted" a question with one answer.
  if not sessionStarted:
    sessionStarted = true
    sessionFuture = bootAndReport()
  sessionFuture

# ---------------------------------------------------------------------------
# THE BOOT STARTS AT MODULE INITIALISATION, AND THAT IS A CORRECTNESS
# REQUIREMENT RATHER THAN AN OPTIMISATION.
#
# ## The regression this line exists to prevent, measured
#
# When the two bundles were merged, `ci/test/web-renderer-mounts.sh`'s arm A
# went red — and it was right to. Arm A deletes the third-party bundle, so
# `ui.js` raises `ReferenceError: monaco is not defined` at module scope
# (`ui/agent_activity.nim:46` builds two Monaco models during initialisation)
# and dies about a quarter of the way through its own top-level code.
#
# While the boot call sat at the TAIL of `ui_js.nim`, that throw meant `boot()`
# was never reached at all. Two programs used to fail independently — a broken
# renderer still left a boot line saying the storage layer was healthy — and
# merging them silently traded that away. Arm A's twin assertion, "the loop arm
# still booted", is exactly the check that caught it.
#
# ## Why starting here restores it
#
# This module is imported at the TOP of `ui_js.nim`'s web arm, so its
# initialiser runs before the modules that touch `monaco`. `boot()` is `async`:
# it returns at its first `await` having already queued its continuation, and a
# later uncaught exception in the same synchronous module-init pass does not
# cancel queued promise reactions. So the boot line is reported even when the
# renderer dies before it — which is the property arm A measures.
#
# It is also strictly faster. Boot's OPFS work now overlaps the renderer's
# module initialisation instead of being serialised after it.
#
# `discard`, and the exception path is inside `bootAndReport`'s `async` —
# a rejection here would be an unhandled promise rejection, so `boot()`'s own
# refusal handling (§4.5 returns a refusal as a VALUE, not a raise) is what
# keeps this safe rather than an omission.
discard startWebSession()
