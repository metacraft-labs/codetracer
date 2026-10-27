## test_plat68_keybindings_file.nim — PLAT-68 Phase B: the ONE-TIME IMPORT of
## an old key configuration into `keybindings.json`, on the real filesystem.
##
## `viewmodel/host/keybindings_file.importOldConfigsOnce` is what the terminal,
## GPUI and the desktop's main process call at start-up: when there is no
## `keybindings.json` yet and an old surface exists (here `.cttui-keys`), it
## translates it (`keymap_importers`), writes the file, and reports one line;
## a second run does nothing, and the old file is left as it was. A suite
## outside `tui/app/` because it imports a host module — `tui/app/` is a
## declared SDK consumer (`ci/test/sdk-facade-boundary.sh`).
##
## No mocks: real files in a scratch directory.

import std/[os, strutils, unittest]

import codetracer_embed
import ../../viewmodel/host/keybindings_file

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 15

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const OldKeys = """
# CTUI-9 user keymap.
NORMAL  Ctrl+w  l  = focus-left      # deliberately crossed over
NORMAL  n          = -               # unbind step over
INSPECT y          = value-origin
"""

suite "PLAT-68: the one-time import of .cttui-keys":

  test "writes keybindings.json once, from the old file, and leaves it alone":
    let dir = getTempDir() / "plat68-cttui-import-" & $getCurrentProcessId()
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    let old = dir / ".cttui-keys"
    let target = dir / "keybindings.json"
    writeFile(old, OldKeys)
    let expected = parseUserKeymap(keybindingsText([importCttuiKeys(OldKeys)]))
    ck expected.rows.len > 0
    let first = importOldConfigsOnce(OldConfigs(cttuiKeys: @[old]), target)
    ck first.len == 1
    ck first[0].startsWith(".cttui-keys: 2 of 3 translated")
    ck fileExists(target)
    let loaded = readKeybindings(target)
    ck loaded.keymap.errors.len == 0
    ck loaded.keymap.rows.len == expected.rows.len
    # A second start finds the file and imports nothing.
    ck importOldConfigsOnce(OldConfigs(cttuiKeys: @[old]), target).len == 0
    ck readFile(old) == OldKeys          # the old file is left untouched
    ck readFile(target).len > 0

  test "nothing old is nothing written; an untranslatable file still ends the import":
    let dir = getTempDir() / "plat68-cttui-edges-" & $getCurrentProcessId()
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    let target = dir / "keybindings.json"
    # No old file: no summary, no file — and a missing keybindings.json reads
    # as no rows and no complaint (nobody is required to have one).
    ck importOldConfigsOnce(OldConfigs(cttuiKeys: @[dir / ".cttui-keys"]),
                            target).len == 0
    ck not fileExists(target)
    let absent = readKeybindings(target)
    ck not absent.exists and absent.readError.len == 0 and
      absent.keymap.rows.len == 0
    # A file of nothing but errors translates nothing, and the import still
    # writes keybindings.json, so it is never attempted again.
    let old = dir / ".cttui-keys"
    writeFile(old, "NORMAL n\nVISUAL n = step-over\n")
    let said = importOldConfigsOnce(OldConfigs(cttuiKeys: @[old]), target)
    ck said.len == 1 and said[0].startsWith(".cttui-keys: 0 of 2 translated")
    ck fileExists(target)
    let written = readKeybindings(target)
    ck written.keymap.errors.len == 0 and written.keymap.rows.len == 0

suite "PLAT-68 keybindings file: assertion count":
  test "the declared count was reached":
    check countedAssertions == ExpectedAssertions
