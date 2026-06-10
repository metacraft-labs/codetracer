import std/os

import ../discovery
import m12_fallback_common

const
  JuliaFallbackProviderId* = "julia-fallback"
  JuliaFallbackVersion* = "m12"

proc juliaFileCommand(projectRoot, filePath: string): string {.gcsafe.} =
  "julia --project=" & shellQuote(projectRoot) & " " & shellQuote(filePath)

proc juliaProjectCommand(projectRoot: string): string {.gcsafe.} =
  juliaFileCommand(projectRoot, projectRoot / "test/runtests.jl")

proc juliaSpec*(): M12FallbackSpec =
  M12FallbackSpec(
    providerId: JuliaFallbackProviderId,
    language: "julia",
    framework: "Test stdlib fallback",
    displayName: "Julia Test fixture fallback",
    version: JuliaFallbackVersion,
    fileExtensions: @[".jl"],
    projectMarkers: @["m12-julia.fixture", "Project.toml"],
    ignoredDirs: @[".git", ".julia"],
    runTool: "julia",
    nixPackages: @["julia"],
    canRecordFile: false,
    fileCommand: juliaFileCommand,
    projectCommand: juliaProjectCommand,
    entryPointDetail: "M12 treats one Julia test file as the runnable fixture entry point",
    limitations: "Julia M12 runs file-level fixtures. Native recording is not advertised because the Julia runner did not produce a successful M12 trace in local validation. Julia Test has no stable built-in machine-readable single-test selector, so single-test actions are hidden.")

proc newJuliaFallbackM1Provider*(): M1Provider =
  newM12FallbackProvider(juliaSpec())

proc newJuliaFallbackProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newJuliaFallbackM1Provider()])
