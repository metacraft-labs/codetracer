## install_acme_tools.nim — `plugin_process_fixture.installPackage` as a
## command, for the suites that are not Nim: the GUI suite's plugin specs
## (`src/tests/gui/tests/plugins/`) build and install the `acme-tools` test
## package with
##
##     nim c -r --hints:off install_acme_tools.nim <components root> [--captures-window-input]
##
## and read the component directory it prints. With `--captures-window-input`
## `flame` declares `capturesWindowInput`, without which its window layer is
## refused (§11.7.3). Not a suite (no `test_`
## prefix), so no lane collects it.

import std/[json, os]

import ./plugin_process_fixture

when isMainModule:
  if paramCount() < 1:
    quit "usage: install_acme_tools <components root>", 2
  createDir(paramStr(1))
  var manifest = ""
  if paramCount() >= 2 and paramStr(2) == "--captures-window-input":
    var doc = packageManifest()
    doc["plugins"][1]["capturesWindowInput"] = %*{"reason": "a modal layer"}
    manifest = $doc
  echo installPackage(paramStr(1), manifest)
