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
$buildDebugDir = Join-Path $resolvedRepoRoot "src\build-debug-repro"
$buildDebugBinDir = Join-Path $buildDebugDir "bin"
$repoNodeModulesBinDir = Join-Path $resolvedRepoRoot "node_modules\.bin"

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

# `ct host` serves static assets from `<build>/public`, and `ct` reads
# `<build>/config/default_config.yaml`, in non-Nix mode. The build publishes both
# (repro.nim: `frontend-public-resources`, `config-default-config-yaml`,
# `config-default-layout-json`) and scripts/require-runtime-assets.sh fails a
# build that does not, so this helper lays out nothing: a link or a copy made
# here, before the build, would land in the tree the build owns.

[Environment]::SetEnvironmentVariable("CODETRACER_REPO_ROOT_PATH", $resolvedRepoRoot, "Process")
[Environment]::SetEnvironmentVariable("CODETRACER_BUILD_DIR", $buildDebugDir, "Process")
[Environment]::SetEnvironmentVariable("CODETRACER_DEV_TOOLS", "0", "Process")
[Environment]::SetEnvironmentVariable("CODETRACER_LOG_LEVEL", "INFO", "Process")
[Environment]::SetEnvironmentVariable("PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS", "1", "Process")

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

# ---------------------------------------------------------------------------
# Per-language recorder toolchains.
#
# The GUI Playwright suite records real Ruby/Elixir/Erlang programs. On
# Windows these toolchains are not on the default PATH, so `ct record`
# (Ruby) and the codetracer-beam-recorder fixture script (Elixir/Erlang)
# cannot find their interpreters. We discover the toolchains that the
# Windows DIY bootstrap installed (MSYS2 MinGW Ruby, scoop-managed Elixir
# and Erlang) and put their bin directories on PATH plus, for Ruby, set
# CODETRACER_RUBY_EXE_PATH so `src/common/paths.nim` resolves it directly.
# ---------------------------------------------------------------------------
$languageToolchainBins = @()

# Ruby: prefer the MSYS2 MinGW build installed by the DIY bootstrap.
$rubyExe = [Environment]::GetEnvironmentVariable("CODETRACER_RUBY_EXE_PATH")
if ([string]::IsNullOrWhiteSpace($rubyExe) -or (-not (Test-Path -LiteralPath $rubyExe -PathType Leaf))) {
  $rubyExe = $null
  # The DIY bootstrap installs an MSYS2 MinGW Ruby under the install root
  # (the same MSYS2 tree used for the mingw toolchain).
  $installRoot = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_INSTALL_ROOT")
  if (-not [string]::IsNullOrWhiteSpace($installRoot)) {
    $candidate = Join-Path $installRoot "msys2\msys64\mingw64\bin\ruby.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $rubyExe = $candidate
    }
  }
  if ($null -eq $rubyExe) {
    $fromPath = Get-Command ruby -ErrorAction SilentlyContinue
    if ($null -ne $fromPath -and -not [string]::IsNullOrWhiteSpace($fromPath.Source)) {
      $rubyExe = $fromPath.Source
    }
  }
}
if (-not [string]::IsNullOrWhiteSpace($rubyExe) -and (Test-Path -LiteralPath $rubyExe -PathType Leaf)) {
  [Environment]::SetEnvironmentVariable("CODETRACER_RUBY_EXE_PATH", $rubyExe, "Process")
  $languageToolchainBins += (Split-Path -Parent $rubyExe)
}

# Pure-Ruby recorder script (codetracer-ruby-recorder sibling repo). The
# recorder is a bare Ruby script invoked as `ruby <script>`, so it cannot
# be discovered through findExe; export its absolute path explicitly.
$rubyRecorder = [Environment]::GetEnvironmentVariable("CODETRACER_RUBY_RECORDER_PATH")
if ([string]::IsNullOrWhiteSpace($rubyRecorder) -or (-not (Test-Path -LiteralPath $rubyRecorder -PathType Leaf))) {
  $rubyRecorderCandidate = Join-Path (Split-Path -Parent $resolvedRepoRoot) `
    "codetracer-ruby-recorder\gems\codetracer-pure-ruby-recorder\bin\codetracer-pure-ruby-recorder"
  if (Test-Path -LiteralPath $rubyRecorderCandidate -PathType Leaf) {
    [Environment]::SetEnvironmentVariable("CODETRACER_RUBY_RECORDER_PATH", $rubyRecorderCandidate, "Process")
  }
}

# Elixir + Erlang: scoop installs them under scoop\apps\<name>\current.
foreach ($beam in @(
  @{ Name = "elixir";  Probe = "elixir.bat" },
  @{ Name = "erlang";  Probe = "erl.exe" }
)) {
  $scoopApp = Join-Path ([Environment]::GetEnvironmentVariable("USERPROFILE")) `
    ("scoop\apps\" + $beam.Name + "\current")
  foreach ($binDir in @($scoopApp, (Join-Path $scoopApp "bin"))) {
    if ((Test-Path -LiteralPath $binDir -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $binDir $beam.Probe) -PathType Leaf)) {
      $languageToolchainBins += $binDir
    }
  }
}

$currentPath = [Environment]::GetEnvironmentVariable("PATH")
$prefix = @()
if (Test-Path -LiteralPath $buildDebugBinDir -PathType Container) {
  $prefix += $buildDebugBinDir
}
if (Test-Path -LiteralPath $repoNodeModulesBinDir -PathType Container) {
  $prefix += $repoNodeModulesBinDir
}
foreach ($binDir in $languageToolchainBins) {
  if (-not ($prefix -contains $binDir)) {
    $prefix += $binDir
  }
}
if ($prefix.Count -gt 0) {
  [Environment]::SetEnvironmentVariable("PATH", (($prefix -join ";") + ";" + $currentPath), "Process")
}
