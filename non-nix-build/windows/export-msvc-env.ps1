[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
if ([string]::IsNullOrWhiteSpace($programFilesX86)) {
  exit 0
}

$vswhere = Join-Path $programFilesX86 "Microsoft Visual Studio/Installer/vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
  exit 0
}

$arch = ((Get-CimInstance Win32_ComputerSystem).SystemType).ToLowerInvariant()
$isArm64 = $arch.Contains("arm64")
$requires = if ($isArm64) { "Microsoft.VisualStudio.Component.VC.Tools.ARM64" } else { "Microsoft.VisualStudio.Component.VC.Tools.x86.x64" }

$installPath = (& $vswhere -latest -products * -requires $requires -property installationPath 2>$null | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($installPath) -and $requires -ne "Microsoft.VisualStudio.Component.VC.Tools.x86.x64") {
  $installPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1)
}
if ([string]::IsNullOrWhiteSpace($installPath)) {
  exit 0
}

$targetArch = if ($isArm64) { "arm64" } else { "x64" }
$hostCandidates = if ($isArm64) { @("Hostarm64", "Hostx64", "Hostx86") } else { @("Hostx64", "Hostarm64", "Hostx86") }
$msvcToolsRoot = $null
foreach ($hostCandidate in $hostCandidates) {
  $candidateGlob = Join-Path $installPath "VC/Tools/MSVC/*/bin/$hostCandidate/$targetArch/cl.exe"
  $candidate = Get-ChildItem -Path $candidateGlob -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
  if ($null -ne $candidate) {
    [Console]::WriteLine("MSVC_BIN_DIR=$(Split-Path -Parent $candidate.FullName)")
    $msvcToolsRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $candidate.FullName)))
    break
  }
}

$vcvarsall = Join-Path $installPath "VC/Auxiliary/Build/vcvarsall.bat"
if (-not (Test-Path -LiteralPath $vcvarsall -PathType Leaf)) {
  exit 0
}

$vcArch = if ($isArm64) { "arm64" } else { "amd64" }

# Hand `cmd.exe` a MINIMAL PATH, and splice the caller's real PATH back on
# afterwards in PowerShell.
#
# Why: `cmd.exe` cannot carry an environment variable longer than 8191
# characters, and this script's whole job is to round-trip the environment
# through it. A developer PATH above that limit produces two *silent* wrong
# answers, both measured on this host (parent PATH padded in 1 KB steps,
# canary entry appended, `vcvarsall amd64 && set` captured each time):
#
#     parent PATH 1901 ->  PATH emitted 3369, canary present     (correct)
#     parent PATH 4025 ->  PATH emitted 5493, canary present     (correct)
#     parent PATH 7031 ->  "The input line is too long."  NO output at all
#     parent PATH 8021 ->  "The input line is too long."  NO output at all
#     parent PATH 8219 ->  PATH emitted 1241, canary LOST        (amputated)
#
# The middle band is the nastier of the two: `cmd` fails before `set` runs, so
# INCLUDE / LIB / LIBPATH / VCToolsInstallDir are all absent and the caller
# gets a shell with `cl.exe` reachable but no MSVC or Windows SDK headers and
# libraries -- the exact symptom recorded in
# codetracer-specs/Planned-Work/Windows-Test-Suite-Health.md:104-108, where it
# read as product link defects. In the upper band `env.ps1` ASSIGNS the
# 1241-character remnant as the process PATH, destroying every tool the
# developer had; the observed consequence was `scripts/build-once.sh` dying
# with "Error: repro is required for codetracer reprobuild builds on windows"
# while `repro.exe` sat on the inherited PATH all along.
#
# vcvarsall only needs the system directories (cmd built-ins, reg.exe,
# where.exe), so a minimal PATH costs nothing and keeps the child's
# environment far below the limit regardless of what the caller carries.
$callerPath = [Environment]::GetEnvironmentVariable("PATH")
$systemRoot = [Environment]::GetEnvironmentVariable("SystemRoot")
if ([string]::IsNullOrWhiteSpace($systemRoot)) { $systemRoot = "C:\Windows" }
$minimalPath = @(
  (Join-Path $systemRoot "system32"),
  $systemRoot,
  (Join-Path $systemRoot "System32\Wbem"),
  (Join-Path $systemRoot "System32\WindowsPowerShell\v1.0")
) -join ";"

$lines = $null
try {
  $env:PATH = $minimalPath
  $lines = & cmd.exe /d /s /c "`"$vcvarsall`" $vcArch >nul && set"
  $cmdExit = $LASTEXITCODE
} finally {
  $env:PATH = $callerPath
}
if ($cmdExit -ne 0) {
  exit 0
}

$capturedEnv = @{}
foreach ($line in $lines) {
  if ($line -match "^(PATH|INCLUDE|LIB|LIBPATH|VCToolsInstallDir|VCToolsVersion|VCINSTALLDIR|WindowsSdkDir|WindowsSDKVersion|UCRTVersion|UniversalCRTSdkDir)=(.*)$") {
    $capturedEnv[$matches[1]] = $matches[2]
  }
}

function Prepend-SemicolonValue {
  param(
    [string]$Current,
    [string]$ValueToPrepend
  )

  if ([string]::IsNullOrWhiteSpace($ValueToPrepend)) {
    return $Current
  }

  $existing = @()
  if (-not [string]::IsNullOrWhiteSpace($Current)) {
    $existing = $Current -split ";"
  }

  foreach ($entry in $existing) {
    if ($entry -ieq $ValueToPrepend) {
      return $Current
    }
  }

  if ([string]::IsNullOrWhiteSpace($Current)) {
    return $ValueToPrepend
  }
  return "$ValueToPrepend;$Current"
}

if (-not [string]::IsNullOrWhiteSpace($msvcToolsRoot)) {
  $vcInclude = Join-Path $msvcToolsRoot "include"
  $vcLib = Join-Path $msvcToolsRoot "lib/$targetArch"
  if (Test-Path -LiteralPath $vcInclude -PathType Container) {
    $capturedEnv["INCLUDE"] = Prepend-SemicolonValue -Current $capturedEnv["INCLUDE"] -ValueToPrepend $vcInclude
  }
  if (Test-Path -LiteralPath $vcLib -PathType Container) {
    $capturedEnv["LIB"] = Prepend-SemicolonValue -Current $capturedEnv["LIB"] -ValueToPrepend $vcLib
    $capturedEnv["LIBPATH"] = Prepend-SemicolonValue -Current $capturedEnv["LIBPATH"] -ValueToPrepend $vcLib
  }
  if (-not $capturedEnv.ContainsKey("VCToolsInstallDir")) {
    $capturedEnv["VCToolsInstallDir"] = "$msvcToolsRoot\"
  }
}

# Splice the caller's PATH back on.
#
# The captured PATH is `<what vcvarsall added>;<$minimalPath>` because that is
# all the child was given. Callers -- `env.ps1:1337-1342` in particular -- take
# the emitted `PATH=` line and ASSIGN it to the process, so emitting the child's
# PATH verbatim would silently drop everything the caller had. Re-join here, on
# the PowerShell side, where no 8191-character limit applies: the vcvarsall
# additions first (they must win over any older toolset already on PATH),
# then the caller's own PATH with those additions filtered out so re-sourcing
# `env.ps1` does not grow PATH without bound.
if ($capturedEnv.ContainsKey("PATH")) {
  $minimalSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]($minimalPath -split ";"), [StringComparer]::OrdinalIgnoreCase)

  $additions = @()
  $additionSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in ($capturedEnv["PATH"] -split ";")) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    $trimmed = $entry.TrimEnd('\')
    if ($minimalSet.Contains($entry) -or $minimalSet.Contains($trimmed)) { continue }
    if (-not $additionSet.Add($trimmed)) { continue }
    $additions += $entry
  }

  $tail = @()
  foreach ($entry in ($callerPath -split ";")) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    if ($additionSet.Contains($entry.TrimEnd('\'))) { continue }
    $tail += $entry
  }

  $capturedEnv["PATH"] = (($additions + $tail) -join ";")
  # Also publish the additions on their own, so a caller that would rather
  # PREPEND than replace can do so without re-deriving the delta.
  $capturedEnv["MSVC_PATH_ADDITIONS"] = ($additions -join ";")
}

foreach ($key in @("PATH", "MSVC_PATH_ADDITIONS", "INCLUDE", "LIB", "LIBPATH", "VCToolsInstallDir", "VCToolsVersion", "VCINSTALLDIR", "WindowsSdkDir", "WindowsSDKVersion", "UCRTVersion", "UniversalCRTSdkDir")) {
  if ($capturedEnv.ContainsKey($key)) {
    [Console]::WriteLine("$key=$($capturedEnv[$key])")
  }
}
