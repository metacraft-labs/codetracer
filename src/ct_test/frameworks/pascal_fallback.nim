import std/os

import ../discovery
import m12_fallback_common

const
  PascalFallbackProviderId* = "pascal-fallback"
  PascalFallbackVersion* = "m12"

proc pascalFileCommand(projectRoot, filePath: string): string {.gcsafe.} =
  let
    exe = tempExecutable("ct-m12-pascal", filePath)
    buildDir = exe & "-build"
  "mkdir -p " & shellQuote(buildDir) & " && fpc -g -FU" &
    shellQuote(buildDir) & " -o" & shellQuote(exe) & " " &
    shellQuote(filePath) & " && " & shellQuote(exe)

proc pascalProjectCommand(projectRoot: string): string {.gcsafe.} =
  pascalFileCommand(projectRoot, projectRoot / "tests/test_calculator.pas")

proc pascalSpec*(): M12FallbackSpec =
  M12FallbackSpec(
    providerId: PascalFallbackProviderId,
    language: "pascal",
    framework: "FPCUnit fallback",
    displayName: "Pascal FPC fixture fallback",
    version: PascalFallbackVersion,
    fileExtensions: @[".pas", ".pp"],
    projectMarkers: @["m12-pascal.fixture"],
    ignoredDirs: @[".git"],
    runTool: "fpc",
    nixPackages: @["fpc"],
    canRecordFile: true,
    fileCommand: pascalFileCommand,
    projectCommand: pascalProjectCommand,
    entryPointDetail: "M12 treats one Pascal source file as the runnable fixture entry point",
    limitations: "Pascal M12 uses file-level FPC execution. FPCUnit selectors are not advertised until stable listing and single-test filtering are implemented.")

proc newPascalFallbackM1Provider*(): M1Provider =
  newM12FallbackProvider(pascalSpec())

proc newPascalFallbackProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newPascalFallbackM1Provider()])
