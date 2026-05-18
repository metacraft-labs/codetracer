import std/os

import repro_dsl_stdlib

const PublicResourceRoot = "src/public"

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
  StylusCssEntryPoints = @[
    "default_white_theme",
    "default_dark_theme_electron",
    "default_dark_theme_extension",
    "loader",
    "subwindow"
  ]

package codeTracer:
  usesImportPath "reprobuild/packages"
  uses:
    "nim >=1.6 <3.0"
    "node >=20"
    "gcc >=1"
    "stylus >=0"

  build:
    template ctNimJs(definesValue: seq[string];
                     outputPath, sourcePath: string;
                     extraInputsValue: openArray[string] = [];
                     extraOutputsValue: openArray[string] = [];
                     debugInfoOnValue = false;
                     sourcemapOnValue = false;
                     hotCodeReloadingOnValue = false): BuildActionDef =
      nim.js(
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

    template ctNative(outputPath, sourcePath, nimcachePath: string):
        BuildActionDef =
      nim.c(
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

    template ctStylus(name: string): BuildActionDef =
      stylus(
        source = "src/frontend/styles/" & name & ".styl",
        output = "src/frontend/styles/" & name & ".css")

    let generatedConfigHeader = fs.writeText(
      output = "build/generated/ct_config.h",
      text = CtConfigHeader)
    target("generate-config-header", generatedConfigHeader)

    let buildCDir = fs.ensureDir(path = "build/c")
    target("build-c-dir", buildCDir)

    let ipcRegistryTest = ctNimJs(
      definesValue = CommonNimDefines & RendererDefines,
      outputPath = "tests/ipc_registry_test.js",
      sourcePath = "src/frontend/tests/ipc_registry_test.nim",
      extraInputsValue = @[
        "src/frontend/index/ipc_registry.nim",
        "src/frontend/lib/jslib.nim"
      ],
      debugInfoOnValue = true,
      hotCodeReloadingOnValue = true)
    target("nim-js-ipc-registry-test", ipcRegistryTest)

    let frontendUiJs = ctNimJs(
      definesValue = CommonNimDefines & RendererDefines,
      outputPath = "ui.js",
      sourcePath = "src/frontend/ui_js.nim",
      debugInfoOnValue = true,
      hotCodeReloadingOnValue = true)
    target("frontend-ui-js", frontendUiJs)

    let frontendPublicUiJs = fs.copyFile(
      source = "ui.js",
      output = "public/ui.js")
    target("frontend-public-ui-js", frontendPublicUiJs)

    let frontendIndexJs = ctNimJs(
      definesValue = CommonNimDefines & @["ctIndex", "nodejs"],
      outputPath = "index.js",
      extraOutputsValue = @["index.js.map"],
      sourcePath = "src/frontend/index.nim",
      sourcemapOnValue = true)
    target("frontend-index-js", frontendIndexJs)

    let frontendSrcIndexJs = fs.copyFile(
      source = "index.js",
      output = "src/index.js")
    target("frontend-src-index-js", frontendSrcIndexJs)

    let frontendServerIndexJs = ctNimJs(
      definesValue = CommonNimDefines & @["ctIndex", "server", "nodejs"],
      outputPath = "server_index.js",
      extraOutputsValue = @["server_index.js.map"],
      sourcePath = "src/frontend/index.nim",
      sourcemapOnValue = true)
    target("frontend-server-index-js", frontendServerIndexJs)

    let frontendSubwindowJs = ctNimJs(
      definesValue = CommonNimDefines & RendererDefines,
      outputPath = "subwindow.js",
      extraOutputsValue = @["subwindow.js.map"],
      sourcePath = "src/frontend/subwindow.nim",
      debugInfoOnValue = true,
      sourcemapOnValue = true,
      hotCodeReloadingOnValue = true)
    target("frontend-subwindow-js", frontendSubwindowJs)

    let frontendSrcSubwindowJs = fs.copyFile(
      source = "subwindow.js",
      output = "src/subwindow.js")
    target("frontend-src-subwindow-js", frontendSrcSubwindowJs)

    let frontendIndexHtml = fs.copyFile(
      source = "src/frontend/index.html",
      output = "index.html")
    target("frontend-index-html", frontendIndexHtml)

    let frontendSubwindowHtml = fs.copyFile(
      source = "src/frontend/subwindow.html",
      output = "subwindow.html")
    target("frontend-subwindow-html", frontendSubwindowHtml)

    let frontendHelpersJs = fs.copyFile(
      source = "helpers.js",
      output = "src/helpers.js")
    target("frontend-src-helpers-js", frontendHelpersJs)

    var styleActions: seq[BuildActionDef] = @[]
    for name in StylusCssEntryPoints:
      styleActions.add(ctStylus(name))
    let defaultDarkThemeCss = fs.copyFile(
      source = "src/frontend/styles/default_dark_theme_extension.css",
      output = "src/frontend/styles/default_dark_theme.css")
    styleActions.add(defaultDarkThemeCss)
    let frontendStyles = aggregate("frontend-styles", actions = styleActions)

    let publicResources = fs.preserveTree(
      sourceRoot = PublicResourceRoot,
      outputRoot = "public")
    target("frontend-public-resources", publicResources)

    let frontend = aggregate("frontend",
      actions = @[
        frontendUiJs,
        frontendPublicUiJs,
        frontendIndexJs,
        frontendSrcIndexJs,
        frontendServerIndexJs,
        frontendSubwindowJs,
        frontendSrcSubwindowJs,
        frontendIndexHtml,
        frontendSubwindowHtml,
        frontendHelpersJs,
        publicResources
      ],
      targets = @[frontendStyles])

    var codetracerActions: seq[BuildActionDef] = @[]

    if fileExists("src/config/default_layout.json"):
      let defaultLayout = fs.copyFile(
        source = "src/config/default_layout.json",
        output = "config/default_layout.json")
      target("config-default-layout-json", defaultLayout)
      codetracerActions.add(defaultLayout)

    if fileExists("src/config/default_config.yaml"):
      let defaultConfig = fs.copyFile(
        source = "src/config/default_config.yaml",
        output = "config/default_config.yaml")
      target("config-default-config-yaml", defaultConfig)
      codetracerActions.add(defaultConfig)

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
      let dbBackendRecord = ctNative(
        nimcachePath = "/tmp/ct-nim-cache/db_backend_record_codetracer_binary",
        outputPath = "src/bin/db-backend-record",
        sourcePath = "src/ct/db_backend_record.nim")
      target("db-backend-record", dbBackendRecord)
      codetracerActions.add(dbBackendRecord)

    if fileExists("src/ct/codetracer.nim"):
      let ct = ctNative(
        nimcachePath = "/tmp/ct-nim-cache/codetracer_codetracer_binary",
        outputPath = "src/bin/ct",
        sourcePath = "src/ct/codetracer.nim")
      target("ct", ct)
      codetracerActions.add(ct)

    if hasFrontendInputs and hasDbBackendRecordInput and hasCtInput:
      let codetracer = aggregate("codetracer",
        actions = codetracerActions,
        targets = @[frontend])
      defaultBuildAction(codetracer)

    let cSudokuObjectTup = gcc(
      source = "test-programs/c_sudoku_solver/main.c",
      output = "build/c/main.tup.o",
      pic = true,
      debug3 = true,
      compileOnly = true,
      after = @[buildCDir])
    target("c-sudoku-object-tup", cSudokuObjectTup)

    let cSudokuObjectWithGeneratedHeader = gcc(
      source = "test-programs/c_sudoku_solver/main.c",
      output = "build/c/main.with-header.o",
      pic = true,
      debug3 = true,
      compileOnly = true,
      includes = @["build/generated/ct_config.h"],
      after = @[buildCDir])
    target("c-sudoku-object-with-generated-header",
      cSudokuObjectWithGeneratedHeader)
