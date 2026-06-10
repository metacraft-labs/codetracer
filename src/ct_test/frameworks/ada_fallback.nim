import std/os

import ../discovery
import m12_fallback_common

const
  AdaFallbackProviderId* = "ada-fallback"
  AdaFallbackVersion* = "m12"

proc adaFileCommand(projectRoot, filePath: string): string {.gcsafe.} =
  let
    parsed = splitFile(filePath)
    exe = tempExecutable("ct-m12-ada", filePath)
    buildDir = exe & "-build"
    buildFile = buildDir / (parsed.name & parsed.ext)
  "rm -rf " & shellQuote(buildDir) & " && mkdir -p " &
    shellQuote(buildDir) & " && cp " & shellQuote(filePath) & " " &
    shellQuote(buildFile) & " && cd " & shellQuote(buildDir) &
    " && gnatmake -g -o " & shellQuote(exe) & " " &
    shellQuote(buildFile) & " && " & shellQuote(exe)

proc adaProjectCommand(projectRoot: string): string {.gcsafe.} =
  adaFileCommand(projectRoot, projectRoot / "tests/test_calculator.adb")

proc adaSpec*(): M12FallbackSpec =
  M12FallbackSpec(
    providerId: AdaFallbackProviderId,
    language: "ada",
    framework: "AUnit fallback",
    displayName: "Ada AUnit fixture fallback",
    version: AdaFallbackVersion,
    fileExtensions: @[".adb", ".ads"],
    projectMarkers: @["m12-ada.fixture"],
    ignoredDirs: @[".git", "obj"],
    runTool: "gnatmake",
    nixPackages: @["gnat"],
    canRecordFile: true,
    fileCommand: adaFileCommand,
    projectCommand: adaProjectCommand,
    entryPointDetail: "M12 treats one Ada body as the runnable fixture entry point",
    limitations: "Ada M12 uses file-level gnatmake execution. AUnit suite/test selectors are not advertised until a project-aware AUnit adapter is available.")

proc newAdaFallbackM1Provider*(): M1Provider =
  newM12FallbackProvider(adaSpec())

proc newAdaFallbackProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newAdaFallbackM1Provider()])
