## keybindings_location.nim — WHERE the one user keymap and the old
## configuration files live, for every host that reads them: the terminal,
## GPUI and the desktop's Electron main process (which reads and watches the
## files with Node's `fs`, so this half is pure enough to compile to
## JavaScript too).
##
## Base-Keymaps-And-Layer-Stack.md §3.5: `CODETRACER_KEYBINDINGS`, else
## `keybindings.json` in the product's configuration directory
## (`ct_home.ctConfigDir`: `$CODETRACER_HOME/config`,
## `$XDG_CONFIG_HOME/codetracer`, `~/.config/codetracer`).

import std/os

import ../../../common/ct_home

type
  OldConfigs* = object
    ## Where the old surfaces are on this host. Fields, not lookups, so a
    ## suite names its own and the product's are `defaultOldConfigs`.
    cttuiKeys*: seq[string]
      ## Candidate `.cttui-keys` paths, first existing one wins.
    userYaml*: string
      ## The desktop's user `.config.yaml`.
    defaultYaml*: string
      ## The shipped `default_config.yaml` text the user's is compared with.

const KeybindingsEnvVar* = "CODETRACER_KEYBINDINGS"

proc keybindingsPath*(): string =
  let override = getEnv(KeybindingsEnvVar)
  if override.len > 0: override
  else: ctConfigDir() / "keybindings.json"

proc defaultOldConfigs*(defaultYaml: string): OldConfigs =
  OldConfigs(
    cttuiKeys: @[userHomeDir() / ".cttui-keys", ctConfigDir() / ".cttui-keys"],
    userYaml: ctConfigDir() / ".config.yaml",
    defaultYaml: defaultYaml)
