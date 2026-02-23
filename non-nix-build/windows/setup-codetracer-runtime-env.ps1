[CmdletBinding()]
param(
  [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $windowsDir = Split-Path -Parent $PSCommandPath
  $nonNixBuildDir = Split-Path -Parent $windowsDir
  $RepoRoot = Split-Path -Parent $nonNixBuildDir
}

$resolvedRepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$buildDebugDir = Join-Path $resolvedRepoRoot "src\build-debug"
$buildDebugBinDir = Join-Path $buildDebugDir "bin"
$buildDebugPublicDir = Join-Path $buildDebugDir "public"
$buildDebugConfigDir = Join-Path $buildDebugDir "config"
$repoPublicDir = Join-Path $resolvedRepoRoot "src\public"
$repoConfigDir = Join-Path $resolvedRepoRoot "src\config"
$repoNodeModulesBinDir = Join-Path $resolvedRepoRoot "node_modules\.bin"
$ctPathsPath = Join-Path $resolvedRepoRoot "ct_paths.json"

function Resolve-CtagsExe {
  $explicit = [Environment]::GetEnvironmentVariable("CODETRACER_CTAGS_EXE_PATH")
  if (-not [string]::IsNullOrWhiteSpace($explicit) -and (Test-Path -LiteralPath $explicit -PathType Leaf)) {
    return $explicit
  }

  $fromPath = Get-Command ctags -ErrorAction SilentlyContinue
  if ($null -ne $fromPath -and -not [string]::IsNullOrWhiteSpace($fromPath.Source)) {
    return $fromPath.Source
  }

  $localAppData = [Environment]::GetEnvironmentVariable("LOCALAPPDATA")
  if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
    $wingetRoot = Join-Path $localAppData "Microsoft\WinGet\Packages"
    if (Test-Path -LiteralPath $wingetRoot -PathType Container) {
      $candidate = Get-ChildItem -LiteralPath $wingetRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "UniversalCtags.Ctags_*" } |
        ForEach-Object { Join-Path $_.FullName "ctags.exe" } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        return $candidate
      }
    }
  }

  return ""
}

if (-not (Test-Path -LiteralPath $ctPathsPath -PathType Leaf)) {
  Set-Content -LiteralPath $ctPathsPath -Value '{"PYTHONPATH":"","LD_LIBRARY_PATH":""}' -Encoding utf8
}

# `ct host` serves static assets from `<build-debug>/public` in non-Nix mode.
# Ensure the folder exists by linking it to `src/public` when missing.
if ((-not (Test-Path -LiteralPath $buildDebugPublicDir)) -and (Test-Path -LiteralPath $repoPublicDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $buildDebugDir | Out-Null
  try {
    New-Item -ItemType Junction -Path $buildDebugPublicDir -Target $repoPublicDir | Out-Null
  } catch {
    Copy-Item -Recurse -Force -LiteralPath $repoPublicDir -Destination $buildDebugPublicDir
  }
}

# `ct` runtime expects `<build-debug>/config/default_config.yaml` in non-Nix mode.
if ((-not (Test-Path -LiteralPath $buildDebugConfigDir)) -and (Test-Path -LiteralPath $repoConfigDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $buildDebugDir | Out-Null
  try {
    New-Item -ItemType Junction -Path $buildDebugConfigDir -Target $repoConfigDir | Out-Null
  } catch {
    Copy-Item -Recurse -Force -LiteralPath $repoConfigDir -Destination $buildDebugConfigDir
  }
}

if (Test-Path -LiteralPath $repoConfigDir -PathType Container) {
  New-Item -ItemType Directory -Force -Path $buildDebugConfigDir | Out-Null
  foreach ($filename in @("default_config.yaml", "default_layout.json")) {
    $src = Join-Path $repoConfigDir $filename
    $dst = Join-Path $buildDebugConfigDir $filename
    if ((Test-Path -LiteralPath $src -PathType Leaf) -and (-not (Test-Path -LiteralPath $dst -PathType Leaf))) {
      Copy-Item -LiteralPath $src -Destination $dst -Force
    }
  }
}

[Environment]::SetEnvironmentVariable("CODETRACER_REPO_ROOT_PATH", $resolvedRepoRoot, "Process")
[Environment]::SetEnvironmentVariable("NIX_CODETRACER_EXE_DIR", $buildDebugDir, "Process")
[Environment]::SetEnvironmentVariable("LINKS_PATH_DIR", $buildDebugDir, "Process")
[Environment]::SetEnvironmentVariable("CODETRACER_LINKS_PATH", $buildDebugDir, "Process")
[Environment]::SetEnvironmentVariable("CODETRACER_DEV_TOOLS", "0", "Process")
[Environment]::SetEnvironmentVariable("CODETRACER_LOG_LEVEL", "INFO", "Process")
[Environment]::SetEnvironmentVariable("PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS", "1", "Process")

if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("CODETRACER_CT_PATHS"))) {
  [Environment]::SetEnvironmentVariable("CODETRACER_CT_PATHS", $ctPathsPath, "Process")
}

if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("CODETRACER_E2E_CT_PATH"))) {
  $ctExeCandidate = Join-Path $buildDebugBinDir "ct.exe"
  $ctPosixCandidate = Join-Path $buildDebugBinDir "ct"
  if (Test-Path -LiteralPath $ctExeCandidate -PathType Leaf) {
    [Environment]::SetEnvironmentVariable("CODETRACER_E2E_CT_PATH", $ctExeCandidate, "Process")
  } elseif (Test-Path -LiteralPath $ctPosixCandidate -PathType Leaf) {
    [Environment]::SetEnvironmentVariable("CODETRACER_E2E_CT_PATH", $ctPosixCandidate, "Process")
  }
}

$ctagsExe = Resolve-CtagsExe
if (-not [string]::IsNullOrWhiteSpace($ctagsExe)) {
  [Environment]::SetEnvironmentVariable("CODETRACER_CTAGS_EXE_PATH", $ctagsExe, "Process")
}

$currentPath = [Environment]::GetEnvironmentVariable("PATH")
$prefix = @()
if (Test-Path -LiteralPath $buildDebugBinDir -PathType Container) {
  $prefix += $buildDebugBinDir
}
if (Test-Path -LiteralPath $repoNodeModulesBinDir -PathType Container) {
  $prefix += $repoNodeModulesBinDir
}
if ($prefix.Count -gt 0) {
  [Environment]::SetEnvironmentVariable("PATH", (($prefix -join ";") + ";" + $currentPath), "Process")
}
