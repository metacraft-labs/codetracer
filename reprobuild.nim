import std/[algorithm, os, strutils]

import repro_project_dsl

const PublicResourceRoot = "src/public"

proc normalizedRelPath(path: string): string =
  path.replace('\\', '/')

proc stableHashHex(value: string): string =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  toHex(hash, 8).toLowerAscii()

proc actionSlug(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '_', '-'}:
      result.add(ch.toLowerAscii())
    else:
      result.add("-" & toHex(ord(ch), 2).toLowerAscii())
  if result.len == 0:
    result = "resource"

proc publicResourceActionId(relative: string): string =
  let normalized = normalizedRelPath(relative)
  let tail = splitPath(normalized).tail
  "frontend-public-resource-" & actionSlug(tail) & "-" &
    stableHashHex(normalized)

proc collectPublicResourceTree(root: string): tuple[dirs: seq[string];
    files: seq[string]] =
  if not dirExists(root):
    return
  var pending = @[root]
  while pending.len > 0:
    let dir = pending.pop()
    result.dirs.add(dir)
    for kind, path in walkDir(dir):
      case kind
      of pcDir:
        pending.add(path)
      of pcFile:
        result.files.add(path)
      else:
        discard
  result.dirs.sort()
  result.files.sort()

proc publicResourceOutput(sourcePath: string): string =
  "public" / normalizedRelPath(relativePath(sourcePath, PublicResourceRoot))

const
  CtConfigHeader = """
#ifndef REPROBUILD_CT_SUBSET_CONFIG_H
#define REPROBUILD_CT_SUBSET_CONFIG_H
#define REPROBUILD_CT_SUBSET_GENERATED 1
#endif
"""
  CommonNimDefines = @[
    "chronicles_sinks=json",
    "chronicles_line_numbers=true",
    "chronicles_timestamps=UnixTime",
    "ssl",
    "nimNoLentIterators",
    "debug"
  ]
  RendererDefines = @[
    "chronicles_enabled=off",
    "ctRenderer"
  ]
  NativeDefines = @[
    "chronicles_sinks=json",
    "chronicles_line_numbers=true",
    "chronicles_timestamps=UnixTime",
    "ssl",
    "nimNoLentIterators",
    "debug",
    "testing",
    "ctEntrypoint",
    "withTup",
    "useOpenssl3",
    "ssl"
  ]
  DisabledNimHints = @[
    "Processing]:off",
    "Conf]:off",
    "CC]:off",
    "Pattern]:off",
    "XDeclaredButNotUsed]:off",
    "XCannotRaiseY]:off"
  ]
  DisabledCaseTransitionWarning = @["CaseTransition]:off"]
  CodeTracerNimPaths = @[
    "libs/NimYAML",
    "libs/asynctools",
    "libs/karax/karax",
    "libs/nim",
    "libs/nim-chronicles/",
    "libs/nim-faststreams",
    "libs/nim-json-serialization",
    "libs/nim-prompt",
    "libs/nim-serialization",
    "libs/nim-stew",
    "libs/nim-unicodedb/src",
    "libs/poly",
    "libs/quicktest",
    "libs/asynctools",
    "libs/chronos",
    "libs/parsetoml/src",
    "libs/nim-result",
    "libs/nim-confutils",
    "libs/nimcrypto",
    "libs/zip",
    "libs/jsony/src",
    "libs/nim-uuid4/src"
  ]
  NativeDynlibOverrides = @[
    "libcrypto",
    "libssl",
    "sqlite3",
    "pcre",
    "libzip"
  ]
  NativePassL = @[
    "-lssl",
    "-lcrypto",
    "-lsqlite3",
    "-lpcre",
    "-lzip"
  ]

package codeTracer:
  usesImportPath "reprobuild/packages"
  uses:
    "nim >=1.6 <3.0"
    "node >=20"
    "gcc >=1"

  build:
      template ctNimJs(actionName: string;
                       definesValue: seq[string];
                       outputPath, sourcePath: string;
                       extraInputsValue: openArray[string] = [];
                       extraOutputsValue: openArray[string] = [];
                       debugInfoOnValue = false;
                       sourcemapOnValue = false;
                       hotCodeReloadingOnValue = false): BuildActionDef =
        nim.js(
          actionId = actionName,
          defines = definesValue,
          mm = "refc",
          hintsOff = true,
          warningsOff = true,
          disabledHints = DisabledNimHints,
          disabledWarnings = DisabledCaseTransitionWarning,
          debugInfo = true,
          debugInfoOn = debugInfoOnValue,
          lineDirOn = true,
          stacktraceOn = true,
          linetraceOn = true,
          sourcemapOn = sourcemapOnValue,
          hotCodeReloadingOn = hotCodeReloadingOnValue,
          output = outputPath,
          extraInputs = extraInputsValue,
          extraOutputs = extraOutputsValue,
          paths = CodeTracerNimPaths,
          source = sourcePath)

      template ctNative(actionName, outputPath, sourcePath,
                        nimcachePath: string): BuildActionDef =
        nim.c(
          actionId = actionName,
          defines = NativeDefines,
          mm = "refc",
          hintsOff = true,
          warningsOff = true,
          disabledHints = DisabledNimHints,
          disabledWarnings = DisabledCaseTransitionWarning,
          debugInfo = true,
          lineDirOn = true,
          stacktraceOn = true,
          linetraceOn = true,
          boundChecksOn = true,
          warningsOn = true,
          hintsOn = true,
          dynlibOverrides = NativeDynlibOverrides,
          passL = NativePassL,
          nimcache = nimcachePath,
          output = outputPath,
          source = sourcePath)

      fs.writeText(
        actionId = "generate-config-header",
        output = "build/generated/ct_config.h",
        text = CtConfigHeader)
      let buildCDir = fs.ensureDir(actionId = "build-c-dir", path = "build/c")

      ctNimJs(
        actionName = "nim-js-ipc-registry-test",
        definesValue = CommonNimDefines & RendererDefines,
        outputPath = "tests/ipc_registry_test.js",
        sourcePath = "src/frontend/tests/ipc_registry_test.nim",
        extraInputsValue = @[
          "src/frontend/index/ipc_registry.nim",
          "src/frontend/lib/jslib.nim"
        ],
        debugInfoOnValue = true,
        hotCodeReloadingOnValue = true)

      ctNimJs(
        actionName = "frontend-ui-js",
        definesValue = CommonNimDefines & RendererDefines,
        outputPath = "ui.js",
        sourcePath = "src/frontend/ui_js.nim",
        debugInfoOnValue = true,
        hotCodeReloadingOnValue = true)

      fs.copyFile(
        actionId = "frontend-public-ui-js",
        source = "ui.js",
        output = "public/ui.js")

      ctNimJs(
        actionName = "frontend-index-js",
        definesValue = CommonNimDefines & @["ctIndex", "nodejs"],
        outputPath = "index.js",
        extraOutputsValue = @["index.js.map"],
        sourcePath = "src/frontend/index.nim",
        sourcemapOnValue = true)

      fs.copyFile(
        actionId = "frontend-src-index-js",
        source = "index.js",
        output = "src/index.js")

      ctNimJs(
        actionName = "frontend-server-index-js",
        definesValue = CommonNimDefines & @["ctIndex", "server", "nodejs"],
        outputPath = "server_index.js",
        extraOutputsValue = @["server_index.js.map"],
        sourcePath = "src/frontend/index.nim",
        sourcemapOnValue = true)

      ctNimJs(
        actionName = "frontend-subwindow-js",
        definesValue = CommonNimDefines & RendererDefines,
        outputPath = "subwindow.js",
        extraOutputsValue = @["subwindow.js.map"],
        sourcePath = "src/frontend/subwindow.nim",
        debugInfoOnValue = true,
        sourcemapOnValue = true,
        hotCodeReloadingOnValue = true)

      fs.copyFile(
        actionId = "frontend-src-subwindow-js",
        source = "subwindow.js",
        output = "src/subwindow.js")

      fs.copyFile(
        actionId = "frontend-index-html",
        source = "src/frontend/index.html",
        output = "index.html")

      fs.copyFile(
        actionId = "frontend-subwindow-html",
        source = "src/frontend/subwindow.html",
        output = "subwindow.html")

      fs.copyFile(
        actionId = "frontend-src-helpers-js",
        source = "helpers.js",
        output = "src/helpers.js")

      # Coarse generated-copy resource semantics for the current src/public
      # tree. This intentionally enumerates regular files only and is not a
      # full model of Tup !tup_preserve, symlink behavior, removal cleanup, or
      # platform-specific resource installation semantics.
      let publicTree = collectPublicResourceTree(PublicResourceRoot)
      for dirPath in publicTree.dirs:
        providerDirectoryInput(normalizedRelPath(dirPath))
      var publicResourceOutputs: seq[string] = @[]
      for sourcePath in publicTree.files:
        let relative = normalizedRelPath(relativePath(sourcePath,
          PublicResourceRoot))
        let actionId = publicResourceActionId(relative)
        let output = publicResourceOutput(sourcePath)
        publicResourceOutputs.add(output)
        fs.copyFile(
          actionId = actionId,
          source = normalizedRelPath(sourcePath),
          output = output)

      fs.stamp(
        actionId = "frontend-public-resources",
        output = "build/reprobuild/frontend-public-resources.stamp",
        title = "CodeTracer frontend public resource tree",
        entries = publicResourceOutputs,
        inputs = publicResourceOutputs)

      fs.stamp(
        actionId = "frontend",
        output = "build/reprobuild/frontend.stamp",
        title = "CodeTracer frontend aggregate",
        entries = @[
          "src/index.js",
          "src/subwindow.js",
          "public/ui.js",
          "server_index.js",
          "index.html",
          "subwindow.html",
          "src/helpers.js",
          "build/reprobuild/frontend-public-resources.stamp"
        ],
        inputs = @[
          "src/index.js",
          "src/subwindow.js",
          "public/ui.js",
          "server_index.js",
          "index.html",
          "subwindow.html",
          "src/helpers.js",
          "build/reprobuild/frontend-public-resources.stamp"
        ])

      var codetracerInputs = @["build/reprobuild/frontend.stamp"]
      var codetracerEntries = @["build/reprobuild/frontend.stamp"]

      if fileExists("src/config/default_layout.json"):
        fs.copyFile(
          actionId = "config-default-layout-json",
          source = "src/config/default_layout.json",
          output = "config/default_layout.json")
        codetracerInputs.add("config/default_layout.json")
        codetracerEntries.add("config/default_layout.json")

      if fileExists("src/config/default_config.yaml"):
        fs.copyFile(
          actionId = "config-default-config-yaml",
          source = "src/config/default_config.yaml",
          output = "config/default_config.yaml")
        codetracerInputs.add("config/default_config.yaml")
        codetracerEntries.add("config/default_config.yaml")

      let hasFrontendInputs =
        fileExists("src/frontend/ui_js.nim") and
        fileExists("src/frontend/index.nim") and
        fileExists("src/frontend/subwindow.nim") and
        fileExists("src/frontend/index.html") and
        fileExists("src/frontend/subwindow.html") and
        fileExists("helpers.js")
      let hasDbBackendRecordInput = fileExists("src/ct/db_backend_record.nim")
      let hasCtInput = fileExists("src/ct/codetracer.nim")

      if fileExists("src/ct/db_backend_record.nim"):
        ctNative(
          actionName = "db-backend-record",
          nimcachePath = "/tmp/ct-nim-cache/db_backend_record_codetracer_binary",
          outputPath = "src/bin/db-backend-record",
          sourcePath = "src/ct/db_backend_record.nim")
        codetracerInputs.add("src/bin/db-backend-record")
        codetracerEntries.add("src/bin/db-backend-record")

      if fileExists("src/ct/codetracer.nim"):
        ctNative(
          actionName = "ct",
          nimcachePath = "/tmp/ct-nim-cache/codetracer_codetracer_binary",
          outputPath = "src/bin/ct",
          sourcePath = "src/ct/codetracer.nim")
        codetracerInputs.add("src/bin/ct")
        codetracerEntries.add("src/bin/ct")

      if hasFrontendInputs and hasDbBackendRecordInput and hasCtInput:
        let codetracer = fs.stamp(
          actionId = "codetracer",
          output = "build/reprobuild/codetracer.stamp",
          title = "CodeTracer selected app aggregate",
          entries = codetracerEntries,
          inputs = codetracerInputs)
        defaultBuildAction(codetracer)

      gcc(
        actionId = "c-sudoku-object-tup",
        source = "test-programs/c_sudoku_solver/main.c",
        output = "build/c/main.tup.o",
        pic = true,
        debug3 = true,
        compileOnly = true,
        deps = @[buildCDir.id])

      gcc(
        actionId = "c-sudoku-object-with-generated-header",
        source = "test-programs/c_sudoku_solver/main.c",
        output = "build/c/main.with-header.o",
        pic = true,
        debug3 = true,
        compileOnly = true,
        includes = @["build/generated/ct_config.h"],
        deps = @[buildCDir.id])
