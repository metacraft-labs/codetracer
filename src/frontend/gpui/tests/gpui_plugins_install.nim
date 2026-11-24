## gpui_plugins_install.nim — installs a plugin package as a component for the
## GPUI plugin window lane (`ci/test/gpui-plugins-window.sh`): the `acme-tools`
## test package through `plugin_process_fixture.installPackage`, or the
## `ct-lens` package (`src/plugins/ct-lens/`) through
## `ct_lens_fixture.installLens` — the same builds and the same `ct install`
## layout the plugin suites and the terminal's PTY suites use.
##
##   gpui_plugins_install <components-root> [capture|ct-lens]
##
## `capture` installs the acme-tools manifest with `flame` declaring
## `capturesWindowInput` (it then runs in a process of its own, and may push a
## window layer); `ct-lens` installs ct-lens as it ships. Prints the component
## directory.

import std/[json, os]

import ../../viewmodel/tests/unit/plugin_process_fixture
import ../../viewmodel/tests/unit/ct_lens_fixture

when isMainModule:
  let args = commandLineParams()
  doAssert args.len >= 1, "usage: gpui_plugins_install <components-root> [capture|ct-lens]"
  var manifest = ""
  if args.len >= 2 and args[1] == "capture":
    var doc = packageManifest()
    doc["plugins"][1]["capturesWindowInput"] = %*{"reason": "a modal layer"}
    manifest = $doc
  createDir(args[0])
  if args.len >= 2 and args[1] == "ct-lens":
    echo installLens(args[0])
  else:
    echo installPackage(args[0], manifest)
