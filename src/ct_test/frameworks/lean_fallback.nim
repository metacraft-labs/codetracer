import std/os

import ../discovery
import m12_fallback_common

const
  LeanFallbackProviderId* = "lean-fallback"
  LeanFallbackVersion* = "m12"

proc leanFileCommand(projectRoot, filePath: string): string {.gcsafe.} =
  "lean --run " & shellQuote(filePath)

proc leanProjectCommand(projectRoot: string): string {.gcsafe.} =
  leanFileCommand(projectRoot, projectRoot / "Main.lean")

proc leanSpec*(): M12FallbackSpec =
  M12FallbackSpec(
    providerId: LeanFallbackProviderId,
    language: "lean",
    framework: "fixture fallback",
    displayName: "Lean fixture fallback",
    version: LeanFallbackVersion,
    fileExtensions: @[".lean"],
    projectMarkers: @["m12-lean.fixture", "lakefile.lean", "lakefile.toml"],
    ignoredDirs: @[".git", ".lake", "build"],
    runTool: "lean",
    nixPackages: @["lean4"],
    canRecordFile: true,
    fileCommand: leanFileCommand,
    projectCommand: leanProjectCommand,
    entryPointDetail: "M12 treats one Lean file with `main` as the runnable fixture entry point",
    limitations: "Lean M12 records the Lean runner process around a file-level fixture. The trace is useful for runner-level execution, not theorem tactic stepping.")

proc newLeanFallbackM1Provider*(): M1Provider =
  newM12FallbackProvider(leanSpec())

proc newLeanFallbackProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newLeanFallbackM1Provider()])
