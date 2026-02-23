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
$lines = & cmd.exe /d /s /c "`"$vcvarsall`" $vcArch >nul && set"
if ($LASTEXITCODE -ne 0) {
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

foreach ($key in @("PATH", "INCLUDE", "LIB", "LIBPATH", "VCToolsInstallDir", "VCToolsVersion", "VCINSTALLDIR", "WindowsSdkDir", "WindowsSDKVersion", "UCRTVersion", "UniversalCRTSdkDir")) {
  if ($capturedEnv.ContainsKey($key)) {
    [Console]::WriteLine("$key=$($capturedEnv[$key])")
  }
}
