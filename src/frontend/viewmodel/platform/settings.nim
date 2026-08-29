## The settings-and-secrets facade.
##
## Desktop: OS config files and the keychain. Web: browser storage, and **no
## secrets** (Noir-Studio.md §3.1, §8). Container: container-side config.
##
## ## Settings and secrets are separate surfaces, on purpose
##
## They look alike — both are string-keyed stores — and collapsing them would
## be the expensive mistake. A setting is durable, readable, syncable and dull.
## A secret must never be written where the platform cannot protect it, and the
## web platform cannot protect anything. If they shared an interface, the web
## instantiation would have to decide *per key* whether a write was safe, and
## it would decide by convention. Kept apart, the web instantiation simply does
## not have `capSecretStore`, and a caller that wants one gets `pkNotSupported`
## at the only place that could have leaked it.
##
## ## Environment variables are a settings concern, and a read-only one
##
## `getEnv` appears throughout the front end today. It is host access: the web
## has no environment and a container's is not the browser's. It is exposed
## here as `environment`, read-only, because nothing in a front end has a good
## reason to mutate the environment of a process it does not own — and the two
## desktop sites that do (`LD_LIBRARY_PATH` setup before a spawn) belong to
## `ProcessSpec.env`, which is scoped to the child.

import ./outcome
import ./capabilities

export outcome

type
  SettingsScope* = enum
    ssUser
      ## Follows the person: the config the desktop keeps in `~/.config` and
      ## the web keeps in origin storage.
    ssWorkspace
      ## Follows the project. Travels with an export or a shared link, so it
      ## must never hold anything user-identifying.
    ssSession
      ## Discarded when the session ends. The only scope guaranteed to exist
      ## on every platform, because it needs no durability.

  SettingsFacade* {.requiresInit.} = ref object
    ## `{.requiresInit.}` for the reason spelled out on `FileSystemFacade` in
    ## `fs.nim`: without it, an unassigned field is `nil` rather than a compile
    ## error, and an operation that only makes sense in-process could be added
    ## without `host/remote_stub.nim` noticing.
    profile*: PlatformProfile

    get*: proc(scope: SettingsScope;
               key: string): PlatformFuture[PlatformOutcome[string]]
      ## `pkNotFound` when unset — never an empty string, which a caller
      ## cannot distinguish from a deliberately empty value.
    set*: proc(scope: SettingsScope; key,
               value: string): PlatformFuture[PlatformOutcome[Nothing]]
    delete*: proc(scope: SettingsScope;
                  key: string): PlatformFuture[PlatformOutcome[Nothing]]
    keys*: proc(scope: SettingsScope; prefix: string
               ): PlatformFuture[PlatformOutcome[seq[string]]]

    environment*: proc(name: string): PlatformFuture[PlatformOutcome[string]]
      ## The host's environment, read-only. `pkNotFound` when unset;
      ## `pkNotSupported` where there is no environment at all.

    # -- secrets (capSecretStore) -------------------------------------------
    getSecret*: proc(account,
                     key: string): PlatformFuture[PlatformOutcome[string]]
    setSecret*: proc(account, key,
                     value: string): PlatformFuture[PlatformOutcome[Nothing]]
    deleteSecret*: proc(account,
                        key: string): PlatformFuture[PlatformOutcome[Nothing]]

proc unavailableSettings*(profile: PlatformProfile): SettingsFacade =
  SettingsFacade(
    profile: profile,
    get: proc(scope: SettingsScope; key: string): auto =
      resolvedUnsupported[string]("reading settings"),
    set: proc(scope: SettingsScope; key, value: string): auto =
      resolvedUnsupported[Nothing]("writing settings"),
    delete: proc(scope: SettingsScope; key: string): auto =
      resolvedUnsupported[Nothing]("writing settings"),
    keys: proc(scope: SettingsScope; prefix: string): auto =
      resolvedUnsupported[seq[string]]("reading settings"),
    environment: proc(name: string): auto =
      resolvedUnsupported[string]("the host environment"),
    getSecret: proc(account, key: string): auto =
      resolvedUnsupported[string]("stored secrets"),
    setSecret: proc(account, key, value: string): auto =
      resolvedUnsupported[Nothing]("stored secrets"),
    deleteSecret: proc(account, key: string): auto =
      resolvedUnsupported[Nothing]("stored secrets"))
