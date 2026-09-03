## Where a user's chosen preset lives, and the order the answers are tried in.
##
## ## TWO TIERS, AND ONLY ONE OF THEM IS BUILT
##
## `CodeTracer-Identity.md` §4 draws the line this feature sits exactly on:
##
##     Anything served as static files is free and anonymous. As soon as a
##     dynamic server surface is involved, it requires an account.
##
## A keymap choice in `localStorage` touches no server, so it is free and
## anonymous — and it must be, because §4.2 promises that "every product's
## core loop is static, and therefore works with no account", and stepping
## through a program with the keys you chose is the core loop.
##
## Syncing that choice across devices IS a dynamic surface and therefore needs
## an account. `resolvePreference` below is written so that the account tier is
## a value it is GIVEN, not a call it makes: the anonymous path has no branch
## that could reach the network, which is what keeps
## `ci/test/noir-studio-signed-out.sh`'s zero-egress measurement true.
##
## ## WHY `localStorage` HERE, WHEN THE PLATFORM FACADE REFUSES IT
##
## `viewmodel/platform/web_platform.nim` backs `SettingsFacade` with the OPFS
## volume and says why it does not use `localStorage`: "synchronous, 5 MB, and
## — the reason that decides it — evicted on a different schedule from OPFS".
## Every one of those objections is about storing a PROJECT. None of them
## applies to this:
##
##   * SYNCHRONOUS IS THE REQUIREMENT, not the drawback. The preset has to be
##     known before `defaultRendererConfig` builds the `ShortcutMap`, which
##     happens while the tab is composing its own `CODETRACER::no-trace`
##     payload — before any `await` is possible. An asynchronous read would
##     mean binding the default set first and rebinding afterwards, and a
##     user's first keypress landing on whichever set won the race.
##   * 5 MB IS FOUR ORDERS OF MAGNITUDE MORE than one enum spelling.
##   * EVICTION IS SURVIVABLE, and that is the test. Losing a project is data
##     loss; losing this returns a user to the default bindings, which is
##     exactly what `parsePresetId` does with an unreadable value anyway.
##
## And the sibling product already reserved the key: BlockTracer
## `Configuration.md` §4 specifies `"bt.ui": { …, "keymap": "default", … }` in
## `localStorage`. Storing CodeTracer's under a different mechanism would give
## one preference two homes in one product family.

import std/options

import ./shortcut_presets

type
  PresetSource* = enum
    ## WHERE the active value came from, which the dialog has to be able to
    ## say. BlockTracer `Configuration.md` §6: "The UI must always be able to
    ## answer 'why is this the active value'".
    psAccount     ## the signed-in user's stored choice
    psLocal       ## this browser's stored choice
    psDefault     ## nobody has chosen; the built-in default

  ResolvedPreset* = object
    id*: ShortcutPresetId
    source*: PresetSource

proc resolvePreference*(account: Option[string];
                        local: Option[string]): ResolvedPreset =
  ## The active preset, and why.
  ##
  ## ACCOUNT BEFORE LOCAL, and the order is a decision rather than a
  ## convention. A signed-in user who set their keymap on their desktop and
  ## then opens the studio on a borrowed laptop should get their keymap, not
  ## the laptop's. The reverse order would mean the account value could only
  ## ever apply on a browser that had never been used, which is no sync at all.
  ##
  ## Both tiers go through `parsePresetId`, so an unreadable value at either
  ## one yields the default rather than an error — but note the asymmetry the
  ## `isSome` checks create: a PRESENT but unrecognised account value resolves
  ## to `psAccount` with the default id, because the user did choose, and the
  ## build simply does not know that spelling. Falling through to `local` would
  ## silently reinstate a choice they had replaced.
  if account.isSome:
    return ResolvedPreset(id: parsePresetId(account.get), source: psAccount)
  if local.isSome:
    return ResolvedPreset(id: parsePresetId(local.get), source: psLocal)
  ResolvedPreset(id: DefaultShortcutPresetId, source: psDefault)

proc migrationOnSignIn*(account: Option[string];
                        local: Option[string]): Option[string] =
  ## What the anonymous choice should write into a just-created account, if
  ## anything.
  ##
  ## THE RULE: an anonymous choice is adopted by an account that has none, and
  ## never overwrites one that has.
  ##
  ## The first half is what makes signing up non-destructive. A user configures
  ## their keys, likes the product enough to open an account, and the act of
  ## opening it must not throw the configuration away — that would punish
  ## exactly the moment the product wants to encourage.
  ##
  ## The second half is what makes signing IN on a new machine safe. A user
  ## with an established keymap who signs in from a borrowed browser must not
  ## have that browser's leftover local value promoted over their own; the
  ## anonymous value there is an artefact of the machine, not a decision they
  ## made.
  ##
  ## Returns `none` when there is nothing to write, so the caller performs no
  ## request at all — the migration is not a call that sometimes writes the
  ## same value back.
  if account.isSome:
    return none(string)
  if local.isNone:
    return none(string)
  # NORMALISED ON THE WAY UP, not copied. An unrecognised local value must not
  # be promoted into the account verbatim: it would then be delivered to every
  # other device, each of which would fall back to the default while reporting
  # `psAccount`, and the user would have an account setting that does nothing
  # and cannot be seen to be doing nothing.
  some($parsePresetId(local.get))

when defined(js):
  # The browser half. Both wrappers are guarded exactly the way
  # `ui/web_project_persistence.nim`'s `sessionStorage` pair is: a `typeof`
  # check for the environments that have no storage object at all, and a
  # `try/catch` for the ones that have it and throw on access — Safari in
  # private mode, and any browser with site data blocked. A settings dialog is
  # not worth a `TypeError` that stops the renderer booting.
  proc jsReadLocal(key: cstring): cstring {.importjs: """
    (function(k) {
      try {
        if (typeof localStorage === 'undefined' || localStorage === null) return '';
        var v = localStorage.getItem(k);
        return (v === null || v === undefined) ? '' : v;
      } catch (e) { return ''; }
    })(#)""".}

  proc jsWriteLocal(key, value: cstring) {.importjs: """
    (function(k, v) {
      try {
        if (typeof localStorage === 'undefined' || localStorage === null) return;
        localStorage.setItem(k, v);
      } catch (e) { }
    })(#, #)""".}

  proc storedPreset*(): Option[string] =
    ## This browser's stored choice, or `none`.
    ##
    ## An empty string is `none` — "nobody has chosen" — and not the empty
    ## spelling of a preset. `parsePresetId("")` would answer the default
    ## either way, but the SOURCE differs, and the dialog reports it.
    let raw = $jsReadLocal(cstring(ShortcutPresetStorageKey))
    if raw.len == 0: none(string) else: some(raw)

  proc storePreset*(id: ShortcutPresetId) =
    ## Remember a choice for this browser.
    jsWriteLocal(cstring(ShortcutPresetStorageKey), cstring($id))

  proc activePreset*(): ShortcutPresetId =
    ## What a tab should build its `ShortcutMap` with.
    ##
    ## `none` for the account tier because there is no account tier yet — the
    ## signature is where it will arrive, and `resolvePreference` already
    ## handles it, so the anonymous build takes the path it will keep taking
    ## rather than a temporary one.
    resolvePreference(account = none(string), local = storedPreset()).id
