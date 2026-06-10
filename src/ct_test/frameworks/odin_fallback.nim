import std/os

import ../discovery
import m12_fallback_common

const
  OdinFallbackProviderId* = "odin-fallback"
  OdinFallbackVersion* = "m12"

proc odinFileCommand(projectRoot, filePath: string): string {.gcsafe.} =
  "odin run " & shellQuote(projectRoot) & " -debug"

proc odinProjectCommand(projectRoot: string): string {.gcsafe.} =
  odinFileCommand(projectRoot, projectRoot / "main.odin")

proc odinSpec*(): M12FallbackSpec =
  M12FallbackSpec(
    providerId: OdinFallbackProviderId,
    language: "odin",
    framework: "fixture fallback",
    displayName: "Odin fixture fallback",
    version: OdinFallbackVersion,
    fileExtensions: @[".odin"],
    projectMarkers: @["m12-odin.fixture"],
    ignoredDirs: @[".git"],
    runTool: "odin",
    nixPackages: @["odin"],
    canRecordFile: true,
    fileCommand: odinFileCommand,
    projectCommand: odinProjectCommand,
    entryPointDetail: "M12 treats the containing Odin package as the runnable fixture entry point",
    limitations: "Odin M12 runs the fixture package. Odin has no standard test listing protocol here, so single-test actions are not advertised.")

proc newOdinFallbackM1Provider*(): M1Provider =
  newM12FallbackProvider(odinSpec())

proc newOdinFallbackProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newOdinFallbackM1Provider()])
