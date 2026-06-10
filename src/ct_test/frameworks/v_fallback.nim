import std/os

import ../discovery
import m12_fallback_common

const
  VFallbackProviderId* = "v-fallback"
  VFallbackVersion* = "m12"

proc vFileCommand(projectRoot, filePath: string): string {.gcsafe.} =
  "v run " & shellQuote(filePath)

proc vProjectCommand(projectRoot: string): string {.gcsafe.} =
  vFileCommand(projectRoot, projectRoot / "tests/test_calculator.v")

proc vSpec*(): M12FallbackSpec =
  M12FallbackSpec(
    providerId: VFallbackProviderId,
    language: "v",
    framework: "fixture fallback",
    displayName: "V fixture fallback",
    version: VFallbackVersion,
    fileExtensions: @[".v"],
    projectMarkers: @["m12-v.fixture"],
    ignoredDirs: @[".git"],
    runTool: "v",
    nixPackages: @["vlang"],
    canRecordFile: true,
    fileCommand: vFileCommand,
    projectCommand: vProjectCommand,
    entryPointDetail: "M12 treats one V source file as the runnable fixture entry point",
    limitations: "V M12 uses file-level `v run`. Framework-native test selectors are not advertised.")

proc newVFallbackM1Provider*(): M1Provider =
  newM12FallbackProvider(vSpec())

proc newVFallbackProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newVFallbackM1Provider()])
