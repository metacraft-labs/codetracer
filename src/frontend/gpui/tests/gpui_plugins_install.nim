## gpui_plugins_install.nim — installs the `acme-tools` test package as a
## component for the GPUI plugin window lane (`ci/test/gpui-plugins-window.sh`),
## through `plugin_process_fixture.installPackage`: the same build and the
## same `ct install` layout the plugin-process suite and the terminal's PTY
## suite use.
##
##   gpui_plugins_install <components-root> [capture]
##
## `capture` installs the manifest with `flame` declaring
## `capturesWindowInput` (it then runs in a process of its own, and may push a
## window layer). Prints the component directory.

import std/[json, os]

import ../../viewmodel/tests/unit/plugin_process_fixture

when isMainModule:
  let args = commandLineParams()
  doAssert args.len >= 1, "usage: gpui_plugins_install <components-root> [capture]"
  var manifest = ""
  if args.len >= 2 and args[1] == "capture":
    var doc = packageManifest()
    doc["plugins"][1]["capturesWindowInput"] = %*{"reason": "a modal layer"}
    manifest = $doc
  createDir(args[0])
  echo installPackage(args[0], manifest)
