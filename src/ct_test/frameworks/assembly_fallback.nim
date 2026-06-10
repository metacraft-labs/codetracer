import std/os

import ../discovery
import m12_fallback_common

const
  AssemblyFallbackProviderId* = "assembly-fallback"
  AssemblyFallbackVersion* = "m12"

proc assemblyFileCommand(projectRoot, filePath: string): string {.gcsafe.} =
  let exe = tempExecutable("ct-m12-asm", filePath)
  "gcc -g -no-pie -x assembler-with-cpp -o " & shellQuote(exe) & " " &
    shellQuote(filePath) & " && " & shellQuote(exe)

proc assemblyProjectCommand(projectRoot: string): string {.gcsafe.} =
  assemblyFileCommand(projectRoot, projectRoot / "hello.S")

proc assemblySpec*(): M12FallbackSpec =
  M12FallbackSpec(
    providerId: AssemblyFallbackProviderId,
    language: "assembly",
    framework: "executable fallback",
    displayName: "Assembly executable fallback",
    version: AssemblyFallbackVersion,
    fileExtensions: @[".s", ".S", ".asm"],
    projectMarkers: @["m12-assembly.fixture"],
    ignoredDirs: @[".git"],
    runTool: "gcc",
    nixPackages: @["gcc"],
    canRecordFile: true,
    fileCommand: assemblyFileCommand,
    projectCommand: assemblyProjectCommand,
    entryPointDetail: "M12 treats one assembly source as a native executable fixture entry point",
    limitations: "Assembly M12 compiles and runs one executable-level fixture. There is no framework selector support, so single-test actions are hidden.")

proc newAssemblyFallbackM1Provider*(): M1Provider =
  newM12FallbackProvider(assemblySpec())

proc newAssemblyFallbackProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newAssemblyFallbackM1Provider()])
