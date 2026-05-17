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

package codeTracer:
  uses:
    "nim >=1.6 <2.0"
    "node >=20"
    "gcc >=1"
    "sh >=1"

  executable nimTool:
    name "nim"
    cli:
      subcmd "-d:asyncBackend=asyncdispatch":
        pos args, seq[string], position = 0

  executable shTool:
    name "sh"
    cli:
      subcmd "-c":
        pos args, seq[string], position = 0

  executable gccTool:
    name "gcc"
    cli:
      subcmd "-fPIC":
        pos args, seq[string], position = 0

    build:
      let headerScript =
        "set -eu\n" &
        "out=$1\n" &
        "mkdir -p \"$(dirname \"$out\")\" build/c\n" &
        "cat > \"$out\" <<'EOF'\n" &
        "#ifndef REPROBUILD_CT_SUBSET_CONFIG_H\n" &
        "#define REPROBUILD_CT_SUBSET_CONFIG_H\n" &
        "#define REPROBUILD_CT_SUBSET_GENERATED 1\n" &
        "#endif\n" &
        "EOF\n"

      discard buildAction("generate-config-header",
        codeTracer.executable("sh").subcmd_2d_c(
          args = @[headerScript, "sh", "build/generated/ct_config.h"]),
        outputs = @["build/generated/ct_config.h"])

      discard buildAction("nim-js-ipc-registry-test",
        codeTracer.executable("nim").
          subcmd_2d_d_3a_asyncBackend_3d_asyncdispatch(
          args = @[
            "-d:chronicles_sinks=json",
            "-d:chronicles_line_numbers=true",
            "-d:chronicles_timestamps=UnixTime",
            "-d:ssl",
            "--mm:refc",
            "-d:nimNoLentIterators",
            "--hints:off",
            "--warnings:off",
            "--hint[Processing]:off",
            "--hint[Conf]:off",
            "--hint[CC]:off",
            "--hint[Pattern]:off",
            "--hint[XDeclaredButNotUsed]:off",
            "--hint[XCannotRaiseY]:off",
            "--warning[CaseTransition]:off",
            "-d:debug",
            "--debugInfo",
            "--lineDir:on",
            "--stacktrace:on",
            "--linetrace:on",
            "-d:chronicles_enabled=off",
            "-d:ctRenderer",
            "--debugInfo:on",
            "--lineDir:on",
            "--hints:off",
            "--warnings:off",
            "--hotCodeReloading:on",
            "--out:tests/ipc_registry_test.js",
            "--path:libs/NimYAML",
            "--path:libs/asynctools",
            "--path:libs/karax/karax",
            "--path:libs/nim",
            "--path:libs/nim-chronicles/",
            "--path:libs/nim-faststreams",
            "--path:libs/nim-json-serialization",
            "--path:libs/nim-prompt",
            "--path:libs/nim-serialization",
            "--path:libs/nim-stew",
            "--path:libs/nim-unicodedb/src",
            "--path:libs/poly",
            "--path:libs/quicktest",
            "--path:libs/asynctools",
            "--path:libs/chronos",
            "--path:libs/parsetoml/src",
            "--path:libs/nim-result",
            "--path:libs/nim-confutils",
            "--path:libs/nimcrypto",
            "--path:libs/zip",
            "--path:libs/jsony/src",
            "--path:libs/nim-uuid4/src",
            "js",
            "src/frontend/tests/ipc_registry_test.nim"
          ]),
        inputs = @[
          "src/frontend/tests/ipc_registry_test.nim",
          "src/frontend/index/ipc_registry.nim",
          "src/frontend/lib/jslib.nim"
        ],
        outputs = @["tests/ipc_registry_test.js"],
        dependencyPolicy = automaticMonitorPolicy())

      discard buildAction("frontend-ui-js",
        codeTracer.executable("nim").
          subcmd_2d_d_3a_asyncBackend_3d_asyncdispatch(
          args = @[
            "-d:chronicles_sinks=json",
            "-d:chronicles_line_numbers=true",
            "-d:chronicles_timestamps=UnixTime",
            "-d:ssl",
            "--mm:refc",
            "-d:nimNoLentIterators",
            "--hints:off",
            "--warnings:off",
            "--hint[Processing]:off",
            "--hint[Conf]:off",
            "--hint[CC]:off",
            "--hint[Pattern]:off",
            "--hint[XDeclaredButNotUsed]:off",
            "--hint[XCannotRaiseY]:off",
            "--warning[CaseTransition]:off",
            "-d:debug",
            "--debugInfo",
            "--lineDir:on",
            "--stacktrace:on",
            "--linetrace:on",
            "-d:chronicles_enabled=off",
            "-d:ctRenderer",
            "--debugInfo:on",
            "--lineDir:on",
            "--hints:off",
            "--warnings:off",
            "--hotCodeReloading:on",
            "--out:ui.js",
            "--path:libs/NimYAML",
            "--path:libs/asynctools",
            "--path:libs/karax/karax",
            "--path:libs/nim",
            "--path:libs/nim-chronicles/",
            "--path:libs/nim-faststreams",
            "--path:libs/nim-json-serialization",
            "--path:libs/nim-prompt",
            "--path:libs/nim-serialization",
            "--path:libs/nim-stew",
            "--path:libs/nim-unicodedb/src",
            "--path:libs/poly",
            "--path:libs/quicktest",
            "--path:libs/asynctools",
            "--path:libs/chronos",
            "--path:libs/parsetoml/src",
            "--path:libs/nim-result",
            "--path:libs/nim-confutils",
            "--path:libs/nimcrypto",
            "--path:libs/zip",
            "--path:libs/jsony/src",
            "--path:libs/nim-uuid4/src",
            "js",
            "src/frontend/ui_js.nim"
          ]),
        inputs = @["src/frontend/ui_js.nim"],
        outputs = @["ui.js"],
        dependencyPolicy = automaticMonitorPolicy())

      discard buildAction("frontend-public-ui-js",
        codeTracer.executable("sh").subcmd_2d_c(
          args = @["mkdir -p public && cp ui.js public/ui.js"]),
        deps = @["frontend-ui-js"],
        inputs = @["ui.js"],
        outputs = @["public/ui.js"])

      discard buildAction("frontend-index-js",
        codeTracer.executable("nim").
          subcmd_2d_d_3a_asyncBackend_3d_asyncdispatch(
          args = @[
            "-d:chronicles_sinks=json",
            "-d:chronicles_line_numbers=true",
            "-d:chronicles_timestamps=UnixTime",
            "-d:ssl",
            "--mm:refc",
            "-d:nimNoLentIterators",
            "--hints:off",
            "--warnings:off",
            "--hint[Processing]:off",
            "--hint[Conf]:off",
            "--hint[CC]:off",
            "--hint[Pattern]:off",
            "--hint[XDeclaredButNotUsed]:off",
            "--hint[XCannotRaiseY]:off",
            "--warning[CaseTransition]:off",
            "-d:debug",
            "--debugInfo",
            "--lineDir:on",
            "--stacktrace:on",
            "--linetrace:on",
            "-d:ctIndex",
            "-d:nodejs",
            "--sourcemap:on",
            "--out:index.js",
            "--path:libs/NimYAML",
            "--path:libs/asynctools",
            "--path:libs/karax/karax",
            "--path:libs/nim",
            "--path:libs/nim-chronicles/",
            "--path:libs/nim-faststreams",
            "--path:libs/nim-json-serialization",
            "--path:libs/nim-prompt",
            "--path:libs/nim-serialization",
            "--path:libs/nim-stew",
            "--path:libs/nim-unicodedb/src",
            "--path:libs/poly",
            "--path:libs/quicktest",
            "--path:libs/asynctools",
            "--path:libs/chronos",
            "--path:libs/parsetoml/src",
            "--path:libs/nim-result",
            "--path:libs/nim-confutils",
            "--path:libs/nimcrypto",
            "--path:libs/zip",
            "--path:libs/jsony/src",
            "--path:libs/nim-uuid4/src",
            "js",
            "src/frontend/index.nim"
          ]),
        inputs = @["src/frontend/index.nim"],
        outputs = @["index.js", "index.js.map"],
        dependencyPolicy = automaticMonitorPolicy())

      discard buildAction("frontend-src-index-js",
        codeTracer.executable("sh").subcmd_2d_c(
          args = @["cp index.js src/index.js"]),
        deps = @["frontend-index-js"],
        inputs = @["index.js"],
        outputs = @["src/index.js"])

      discard buildAction("frontend-server-index-js",
        codeTracer.executable("nim").
          subcmd_2d_d_3a_asyncBackend_3d_asyncdispatch(
          args = @[
            "-d:chronicles_sinks=json",
            "-d:chronicles_line_numbers=true",
            "-d:chronicles_timestamps=UnixTime",
            "-d:ssl",
            "--mm:refc",
            "-d:nimNoLentIterators",
            "--hints:off",
            "--warnings:off",
            "--hint[Processing]:off",
            "--hint[Conf]:off",
            "--hint[CC]:off",
            "--hint[Pattern]:off",
            "--hint[XDeclaredButNotUsed]:off",
            "--hint[XCannotRaiseY]:off",
            "--warning[CaseTransition]:off",
            "-d:debug",
            "--debugInfo",
            "--lineDir:on",
            "--stacktrace:on",
            "--linetrace:on",
            "-d:ctIndex",
            "-d:server",
            "-d:nodejs",
            "--sourcemap:on",
            "--out:server_index.js",
            "--path:libs/NimYAML",
            "--path:libs/asynctools",
            "--path:libs/karax/karax",
            "--path:libs/nim",
            "--path:libs/nim-chronicles/",
            "--path:libs/nim-faststreams",
            "--path:libs/nim-json-serialization",
            "--path:libs/nim-prompt",
            "--path:libs/nim-serialization",
            "--path:libs/nim-stew",
            "--path:libs/nim-unicodedb/src",
            "--path:libs/poly",
            "--path:libs/quicktest",
            "--path:libs/asynctools",
            "--path:libs/chronos",
            "--path:libs/parsetoml/src",
            "--path:libs/nim-result",
            "--path:libs/nim-confutils",
            "--path:libs/nimcrypto",
            "--path:libs/zip",
            "--path:libs/jsony/src",
            "--path:libs/nim-uuid4/src",
            "js",
            "src/frontend/index.nim"
          ]),
        inputs = @["src/frontend/index.nim"],
        outputs = @["server_index.js", "server_index.js.map"],
        dependencyPolicy = automaticMonitorPolicy())

      discard buildAction("frontend-subwindow-js",
        codeTracer.executable("nim").
          subcmd_2d_d_3a_asyncBackend_3d_asyncdispatch(
          args = @[
            "-d:chronicles_sinks=json",
            "-d:chronicles_line_numbers=true",
            "-d:chronicles_timestamps=UnixTime",
            "-d:ssl",
            "--mm:refc",
            "-d:nimNoLentIterators",
            "--hints:off",
            "--warnings:off",
            "--hint[Processing]:off",
            "--hint[Conf]:off",
            "--hint[CC]:off",
            "--hint[Pattern]:off",
            "--hint[XDeclaredButNotUsed]:off",
            "--hint[XCannotRaiseY]:off",
            "--warning[CaseTransition]:off",
            "-d:debug",
            "--debugInfo",
            "--lineDir:on",
            "--stacktrace:on",
            "--linetrace:on",
            "-d:chronicles_enabled=off",
            "-d:ctRenderer",
            "--debugInfo:on",
            "--lineDir:on",
            "--hotCodeReloading:on",
            "--sourcemap:on",
            "--out:subwindow.js",
            "--path:libs/NimYAML",
            "--path:libs/asynctools",
            "--path:libs/karax/karax",
            "--path:libs/nim",
            "--path:libs/nim-chronicles/",
            "--path:libs/nim-faststreams",
            "--path:libs/nim-json-serialization",
            "--path:libs/nim-prompt",
            "--path:libs/nim-serialization",
            "--path:libs/nim-stew",
            "--path:libs/nim-unicodedb/src",
            "--path:libs/poly",
            "--path:libs/quicktest",
            "--path:libs/asynctools",
            "--path:libs/chronos",
            "--path:libs/parsetoml/src",
            "--path:libs/nim-result",
            "--path:libs/nim-confutils",
            "--path:libs/nimcrypto",
            "--path:libs/zip",
            "--path:libs/jsony/src",
            "--path:libs/nim-uuid4/src",
            "js",
            "src/frontend/subwindow.nim"
          ]),
        inputs = @["src/frontend/subwindow.nim"],
        outputs = @["subwindow.js", "subwindow.js.map"],
        dependencyPolicy = automaticMonitorPolicy())

      discard buildAction("frontend-src-subwindow-js",
        codeTracer.executable("sh").subcmd_2d_c(
          args = @["mkdir -p src && cp subwindow.js src/subwindow.js"]),
        deps = @["frontend-subwindow-js"],
        inputs = @["subwindow.js"],
        outputs = @["src/subwindow.js"])

      discard buildAction("frontend-index-html",
        codeTracer.executable("sh").subcmd_2d_c(
          args = @["cp src/frontend/index.html index.html"]),
        inputs = @["src/frontend/index.html"],
        outputs = @["index.html"])

      discard buildAction("frontend-subwindow-html",
        codeTracer.executable("sh").subcmd_2d_c(
          args = @["cp src/frontend/subwindow.html subwindow.html"]),
        inputs = @["src/frontend/subwindow.html"],
        outputs = @["subwindow.html"])

      discard buildAction("frontend-src-helpers-js",
        codeTracer.executable("sh").subcmd_2d_c(
          args = @["mkdir -p src && cp helpers.js src/helpers.js"]),
        inputs = @["helpers.js"],
        outputs = @["src/helpers.js"])

      # Coarse generated-copy resource semantics for the current src/public
      # tree. This intentionally enumerates regular files only and is not a
      # full model of Tup !tup_preserve, symlink behavior, removal cleanup, or
      # platform-specific resource installation semantics.
      let publicTree = collectPublicResourceTree(PublicResourceRoot)
      for dirPath in publicTree.dirs:
        providerDirectoryInput(normalizedRelPath(dirPath))
      var publicResourceDeps: seq[string] = @[]
      var publicResourceOutputs: seq[string] = @[]
      for sourcePath in publicTree.files:
        let relative = normalizedRelPath(relativePath(sourcePath,
          PublicResourceRoot))
        let actionId = publicResourceActionId(relative)
        let output = publicResourceOutput(sourcePath)
        publicResourceDeps.add(actionId)
        publicResourceOutputs.add(output)
        discard buildAction(actionId,
          codeTracer.executable("sh").subcmd_2d_c(
            args = @[copyScript(normalizedRelPath(sourcePath), output)]),
          inputs = @[normalizedRelPath(sourcePath)],
          outputs = @[output])

      discard buildAction("frontend-public-resources",
        codeTracer.executable("sh").subcmd_2d_c(
          args = @[stampScript("build/reprobuild/frontend-public-resources.stamp",
            "CodeTracer frontend public resource tree",
            publicResourceOutputs)]),
        deps = publicResourceDeps,
        inputs = publicResourceOutputs,
        outputs = @["build/reprobuild/frontend-public-resources.stamp"])

      discard buildAction("frontend",
        codeTracer.executable("sh").subcmd_2d_c(
          args = @[
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
            "} > build/reprobuild/frontend.stamp"
          ]),
        deps = @[
          "frontend-src-index-js",
          "frontend-src-subwindow-js",
          "frontend-public-ui-js",
          "frontend-server-index-js",
          "frontend-index-html",
          "frontend-subwindow-html",
          "frontend-src-helpers-js",
          "frontend-public-resources"
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
        ],
        outputs = @["build/reprobuild/frontend.stamp"])

      if fileExists("src/ct/db_backend_record.nim"):
        discard buildAction("db-backend-record",
          codeTracer.executable("nim").
            subcmd_2d_d_3a_asyncBackend_3d_asyncdispatch(
            args = @[
              "-d:chronicles_sinks=json",
              "-d:chronicles_line_numbers=true",
              "-d:chronicles_timestamps=UnixTime",
              "-d:ssl",
              "--mm:refc",
              "-d:nimNoLentIterators",
              "--hints:off",
              "--warnings:off",
              "--hint[Processing]:off",
              "--hint[Conf]:off",
              "--hint[CC]:off",
              "--hint[Pattern]:off",
              "--hint[XDeclaredButNotUsed]:off",
              "--hint[XCannotRaiseY]:off",
              "--warning[CaseTransition]:off",
              "-d:debug",
              "--debugInfo",
              "--lineDir:on",
              "--stacktrace:on",
              "--linetrace:on",
              "-d:testing",
              "--boundChecks:on",
              "--stacktrace:on",
              "--linetrace:on",
              "--warnings:on",
              "--hints:on",
              "-d:ctEntrypoint",
              "-d:withTup",
              "-d:useOpenssl3",
              "-d:ssl",
              "--dynlibOverride:libcrypto",
              "--dynlibOverride:libssl",
              "--dynlibOverride:sqlite3",
              "--dynlibOverride:pcre",
              "--dynlibOverride:libzip",
              "--passL:-lssl",
              "--passL:-lcrypto",
              "--passL:-lsqlite3",
              "--passL:-lpcre",
              "--passL:-lzip",
              "--nimcache:/tmp/ct-nim-cache/db_backend_record_codetracer_binary",
              "--out:src/bin/db-backend-record",
              "c",
              "src/ct/db_backend_record.nim"
            ]),
          inputs = @["src/ct/db_backend_record.nim"],
          outputs = @["src/bin/db-backend-record"],
          dependencyPolicy = automaticMonitorPolicy())

      discard buildAction("c-sudoku-object-tup",
        codeTracer.executable("gcc").subcmd_2d_fPIC(
          args = @[
            "-g3",
            "-c",
            "-o",
            "build/c/main.tup.o",
            "test-programs/c_sudoku_solver/main.c"
          ]),
        inputs = @["test-programs/c_sudoku_solver/main.c"],
        outputs = @["build/c/main.tup.o"],
        dependencyPolicy = automaticMonitorPolicy())

      discard buildAction("c-sudoku-object-with-generated-header",
        codeTracer.executable("gcc").subcmd_2d_fPIC(
          args = @[
            "-g3",
            "-c",
            "-include",
            "build/generated/ct_config.h",
            "-o",
            "build/c/main.with-header.o",
            "test-programs/c_sudoku_solver/main.c"
          ]),
        deps = @["generate-config-header"],
        inputs = @[
          "test-programs/c_sudoku_solver/main.c",
          "build/generated/ct_config.h"
        ],
        outputs = @["build/c/main.with-header.o"],
        dependencyPolicy = automaticMonitorPolicy())
