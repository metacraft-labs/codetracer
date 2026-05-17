import std/[algorithm, os, osproc, strutils]

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

proc copyScript(input, output: string): string =
  let outputDir = splitPath(output).head
  result = "set -eu\n"
  if outputDir.len > 0:
    result.add(
      "for i in 1 2 3; do mkdir -p " & quoteShell(outputDir) &
        " && break; sleep 0.05; done\n")
    result.add("test -d " & quoteShell(outputDir) & "\n")
  result.add("cp " & quoteShell(input) & " " & quoteShell(output) & "\n")

proc stampScript(path, title: string; entries: openArray[string]): string =
  result = "set -eu\nmkdir -p " & quoteShell(splitPath(path).head) & "\n"
  result.add("{\n")
  result.add("printf '%s\\n' " & quoteShell(title) & "\n")
  for entry in entries:
    result.add("printf '%s\\n' " & quoteShell(entry) & "\n")
  result.add("} > " & quoteShell(path) & "\n")

const
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
    "nim >=1.6 <2.0"
    "nim-js >=2"
    "node >=20"
    "gcc >=1"
    "sh >=1"

  build:
      let headerScript =
        "set -eu\n" &
        "out=" & quoteShell("build/generated/ct_config.h") & "\n" &
        "mkdir -p \"$(dirname \"$out\")\" build/c\n" &
        "cat > \"$out\" <<'EOF'\n" &
        "#ifndef REPROBUILD_CT_SUBSET_CONFIG_H\n" &
        "#define REPROBUILD_CT_SUBSET_CONFIG_H\n" &
        "#define REPROBUILD_CT_SUBSET_GENERATED 1\n" &
        "#endif\n" &
        "EOF\n"

      sh(
        actionId = "generate-config-header",
        command = headerScript,
        extraOutputs = @["build/generated/ct_config.h"])

      nimJs.js(
        actionId = "nim-js-ipc-registry-test",
        defines = CommonNimDefines & RendererDefines,
        mm = "refc",
        hintsOff = true,
        warningsOff = true,
        disabledHints = DisabledNimHints,
        disabledWarnings = DisabledCaseTransitionWarning,
        debugInfo = true,
        debugInfoOn = true,
        lineDirOn = true,
        stacktraceOn = true,
        linetraceOn = true,
        hotCodeReloadingOn = true,
        output = "tests/ipc_registry_test.js",
        paths = CodeTracerNimPaths,
        source = "src/frontend/tests/ipc_registry_test.nim",
        extraInputs = @[
          "src/frontend/index/ipc_registry.nim",
          "src/frontend/lib/jslib.nim"
        ],
        dependencyPolicy = automaticMonitorPolicy())

      nimJs.js(
        actionId = "frontend-ui-js",
        defines = CommonNimDefines & RendererDefines,
        mm = "refc",
        hintsOff = true,
        warningsOff = true,
        disabledHints = DisabledNimHints,
        disabledWarnings = DisabledCaseTransitionWarning,
        debugInfo = true,
        debugInfoOn = true,
        lineDirOn = true,
        stacktraceOn = true,
        linetraceOn = true,
        hotCodeReloadingOn = true,
        output = "ui.js",
        paths = CodeTracerNimPaths,
        source = "src/frontend/ui_js.nim",
        dependencyPolicy = automaticMonitorPolicy())

      sh(
        actionId = "frontend-public-ui-js",
        command = "mkdir -p public && cp ui.js public/ui.js",
        extraInputs = @["ui.js"],
        extraOutputs = @["public/ui.js"])

      nimJs.js(
        actionId = "frontend-index-js",
        defines = CommonNimDefines & @["ctIndex", "nodejs"],
        mm = "refc",
        hintsOff = true,
        warningsOff = true,
        disabledHints = DisabledNimHints,
        disabledWarnings = DisabledCaseTransitionWarning,
        debugInfo = true,
        lineDirOn = true,
        stacktraceOn = true,
        linetraceOn = true,
        sourcemapOn = true,
        output = "index.js",
        extraOutputs = @["index.js.map"],
        paths = CodeTracerNimPaths,
        source = "src/frontend/index.nim",
        dependencyPolicy = automaticMonitorPolicy())

      sh(
        actionId = "frontend-src-index-js",
        command = "cp index.js src/index.js",
        extraInputs = @["index.js"],
        extraOutputs = @["src/index.js"])

      nimJs.js(
        actionId = "frontend-server-index-js",
        defines = CommonNimDefines & @["ctIndex", "server", "nodejs"],
        mm = "refc",
        hintsOff = true,
        warningsOff = true,
        disabledHints = DisabledNimHints,
        disabledWarnings = DisabledCaseTransitionWarning,
        debugInfo = true,
        lineDirOn = true,
        stacktraceOn = true,
        linetraceOn = true,
        sourcemapOn = true,
        output = "server_index.js",
        extraOutputs = @["server_index.js.map"],
        paths = CodeTracerNimPaths,
        source = "src/frontend/index.nim",
        dependencyPolicy = automaticMonitorPolicy())

      nimJs.js(
        actionId = "frontend-subwindow-js",
        defines = CommonNimDefines & RendererDefines,
        mm = "refc",
        hintsOff = true,
        warningsOff = true,
        disabledHints = DisabledNimHints,
        disabledWarnings = DisabledCaseTransitionWarning,
        debugInfo = true,
        debugInfoOn = true,
        lineDirOn = true,
        stacktraceOn = true,
        linetraceOn = true,
        hotCodeReloadingOn = true,
        sourcemapOn = true,
        output = "subwindow.js",
        extraOutputs = @["subwindow.js.map"],
        paths = CodeTracerNimPaths,
        source = "src/frontend/subwindow.nim",
        dependencyPolicy = automaticMonitorPolicy())

      sh(
        actionId = "frontend-src-subwindow-js",
        command = "mkdir -p src && cp subwindow.js src/subwindow.js",
        extraInputs = @["subwindow.js"],
        extraOutputs = @["src/subwindow.js"])

      sh(
        actionId = "frontend-index-html",
        command = "cp src/frontend/index.html index.html",
        extraInputs = @["src/frontend/index.html"],
        extraOutputs = @["index.html"])

      sh(
        actionId = "frontend-subwindow-html",
        command = "cp src/frontend/subwindow.html subwindow.html",
        extraInputs = @["src/frontend/subwindow.html"],
        extraOutputs = @["subwindow.html"])

      sh(
        actionId = "frontend-src-helpers-js",
        command = "mkdir -p src && cp helpers.js src/helpers.js",
        extraInputs = @["helpers.js"],
        extraOutputs = @["src/helpers.js"])

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
        sh(
          actionId = actionId,
          command = copyScript(normalizedRelPath(sourcePath), output),
          extraInputs = @[normalizedRelPath(sourcePath)],
          extraOutputs = @[output])

      sh(
        actionId = "frontend-public-resources",
        command = stampScript("build/reprobuild/frontend-public-resources.stamp",
          "CodeTracer frontend public resource tree",
          publicResourceOutputs),
        extraInputs = publicResourceOutputs,
        extraOutputs = @["build/reprobuild/frontend-public-resources.stamp"])

      sh(
        actionId = "frontend",
        command =
          "mkdir -p build/reprobuild && " &
          "{ " &
          "printf '%s\n' 'CodeTracer frontend aggregate'; " &
          "printf '%s\n' 'src/index.js'; " &
          "printf '%s\n' 'src/subwindow.js'; " &
          "printf '%s\n' 'public/ui.js'; " &
          "printf '%s\n' 'server_index.js'; " &
          "printf '%s\n' 'index.html'; " &
          "printf '%s\n' 'subwindow.html'; " &
          "printf '%s\n' 'src/helpers.js'; " &
          "printf '%s\n' 'build/reprobuild/frontend-public-resources.stamp'; " &
          "} > build/reprobuild/frontend.stamp",
        extraInputs = @[
          "src/index.js",
          "src/subwindow.js",
          "public/ui.js",
          "server_index.js",
          "index.html",
          "subwindow.html",
          "src/helpers.js",
          "build/reprobuild/frontend-public-resources.stamp"
        ],
        extraOutputs = @["build/reprobuild/frontend.stamp"])

      var codetracerInputs = @["build/reprobuild/frontend.stamp"]
      var codetracerEntries = @["build/reprobuild/frontend.stamp"]

      if fileExists("src/config/default_layout.json"):
        sh(
          actionId = "config-default-layout-json",
          command = copyScript("src/config/default_layout.json",
            "config/default_layout.json"),
          extraInputs = @["src/config/default_layout.json"],
          extraOutputs = @["config/default_layout.json"])
        codetracerInputs.add("config/default_layout.json")
        codetracerEntries.add("config/default_layout.json")

      if fileExists("src/config/default_config.yaml"):
        sh(
          actionId = "config-default-config-yaml",
          command = copyScript("src/config/default_config.yaml",
            "config/default_config.yaml"),
          extraInputs = @["src/config/default_config.yaml"],
          extraOutputs = @["config/default_config.yaml"])
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
        nim.c(
          actionId = "db-backend-record",
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
          nimcache = "/tmp/ct-nim-cache/db_backend_record_codetracer_binary",
          output = "src/bin/db-backend-record",
          source = "src/ct/db_backend_record.nim",
          dependencyPolicy = automaticMonitorPolicy())
        codetracerInputs.add("src/bin/db-backend-record")
        codetracerEntries.add("src/bin/db-backend-record")

      if fileExists("src/ct/codetracer.nim"):
        nim.c(
          actionId = "ct",
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
          nimcache = "/tmp/ct-nim-cache/codetracer_codetracer_binary",
          output = "src/bin/ct",
          source = "src/ct/codetracer.nim",
          dependencyPolicy = automaticMonitorPolicy())
        codetracerInputs.add("src/bin/ct")
        codetracerEntries.add("src/bin/ct")

      if hasFrontendInputs and hasDbBackendRecordInput and hasCtInput:
        sh(
          actionId = "codetracer",
          command = stampScript("build/reprobuild/codetracer.stamp",
            "CodeTracer selected app aggregate", codetracerEntries),
          extraInputs = codetracerInputs,
          extraOutputs = @["build/reprobuild/codetracer.stamp"])
        defaultBuildAction("codetracer")

      gcc(
        actionId = "c-sudoku-object-tup",
        source = "test-programs/c_sudoku_solver/main.c",
        output = "build/c/main.tup.o",
        pic = true,
        debug3 = true,
        compileOnly = true,
        dependencyPolicy = automaticMonitorPolicy())

      gcc(
        actionId = "c-sudoku-object-with-generated-header",
        source = "test-programs/c_sudoku_solver/main.c",
        output = "build/c/main.with-header.o",
        pic = true,
        debug3 = true,
        compileOnly = true,
        includes = @["build/generated/ct_config.h"],
        dependencyPolicy = automaticMonitorPolicy())
