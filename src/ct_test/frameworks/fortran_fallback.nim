import std/os

import ../discovery
import m12_fallback_common

const
  FortranFallbackProviderId* = "fortran-fallback"
  FortranFallbackVersion* = "m12"

proc fortranFileCommand(projectRoot, filePath: string): string {.gcsafe.} =
  let exe = tempExecutable("ct-m12-fortran", filePath)
  "gfortran -g -O0 -o " & shellQuote(exe) & " " & shellQuote(filePath) &
    " && " & shellQuote(exe)

proc fortranProjectCommand(projectRoot: string): string {.gcsafe.} =
  fortranFileCommand(projectRoot, projectRoot / "tests/test_calculator.f90")

proc fortranSpec*(): M12FallbackSpec =
  M12FallbackSpec(
    providerId: FortranFallbackProviderId,
    language: "fortran",
    framework: "pFUnit fallback",
    displayName: "Fortran pFUnit fixture fallback",
    version: FortranFallbackVersion,
    fileExtensions: @[".f90", ".f95", ".f03", ".f08", ".for", ".f"],
    projectMarkers: @["m12-fortran.fixture"],
    ignoredDirs: @[".git"],
    runTool: "gfortran",
    nixPackages: @["gfortran"],
    canRecordFile: true,
    fileCommand: fortranFileCommand,
    projectCommand: fortranProjectCommand,
    entryPointDetail: "M12 treats one Fortran source file as the runnable fixture entry point",
    limitations: "Fortran M12 uses file-level gfortran execution. pFUnit discovery and selectors are not advertised because pFUnit is not assumed to be installed.")

proc newFortranFallbackM1Provider*(): M1Provider =
  newM12FallbackProvider(fortranSpec())

proc newFortranFallbackProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newFortranFallbackM1Provider()])
