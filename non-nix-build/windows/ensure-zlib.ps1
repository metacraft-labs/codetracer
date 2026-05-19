Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# zlib bootstrap for Windows DIY toolchain.
#
# Why source build:
#   Upstream zlib (https://zlib.net) does NOT publish prebuilt Windows binary
#   release archives for 1.3.x. The legacy `zlib131.zip` URL has been removed
#   and only the source tarball is mirrored. We therefore build `libz.a` from
#   the official source tarball hosted on GitHub releases using the canonical
#   MinGW Makefile (`win32/Makefile.gcc`) shipped inside the tarball.
#
#   Source archive URL:
#     https://github.com/madler/zlib/releases/download/v<version>/zlib-<version>.tar.gz
#   SHA256 for 1.3.1 is pinned in toolchain-versions.env as ZLIB_WIN_X64_SHA256.
#
# Layout produced (matches `src/Tuprules.tup`'s WINDOWS_ZLIB_DIR pin):
#   $Root/zlib/<version>/include/zlib.h
#   $Root/zlib/<version>/include/zconf.h
#   $Root/zlib/<version>/lib/libz.a
#
# Build prerequisites:
#   - gcc (from WinLibs MinGW UCRT) — installed earlier in env.ps1 bootstrap by
#     Ensure-Gcc. The path `$Root/gcc/<gcc_version>/bin` must already be on PATH
#     OR `mingw32-make.exe` and `gcc.exe` must be locatable by Get-Command.

function ConvertTo-ZlibFileArch {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "win64" }
    "arm64" { return "win-arm64" }
    default { throw "Unsupported zlib arch '$Arch'." }
  }
}

function Get-ZlibBuildTool {
  param([Parameter(Mandatory = $true)][string]$Name)

  $candidate = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -ne $candidate -and -not [string]::IsNullOrWhiteSpace($candidate.Source)) {
    return $candidate.Source
  }
  return ""
}

function Resolve-MinGWMakeExe {
  param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][hashtable]$Toolchain)

  # Prefer the just-bootstrapped WinLibs gcc/mingw32-make under $Root, since
  # Ensure-Gcc ran first and its bin dir may not yet be on PATH inside the
  # ensure-* invocation context.
  $gccVersion = $Toolchain["GCC_VERSION"]
  if (-not [string]::IsNullOrWhiteSpace($gccVersion)) {
    $gccBin = Join-Path $Root ("gcc/" + $gccVersion + "/bin")
    $candidate = Join-Path $gccBin "mingw32-make.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return @{ make = $candidate; binDir = $gccBin }
    }
  }

  $makeFromPath = Get-ZlibBuildTool -Name "mingw32-make"
  if (-not [string]::IsNullOrWhiteSpace($makeFromPath)) {
    return @{ make = $makeFromPath; binDir = (Split-Path -Parent $makeFromPath) }
  }

  # As a last resort fall back to plain `make` — works with MSYS2/Cygwin.
  $plainMake = Get-ZlibBuildTool -Name "make"
  if (-not [string]::IsNullOrWhiteSpace($plainMake)) {
    return @{ make = $plainMake; binDir = (Split-Path -Parent $plainMake) }
  }

  throw "Unable to find mingw32-make.exe (or make) on PATH or under '$Root/gcc/'. Cannot build zlib from source. Ensure Ensure-Gcc has run successfully first."
}

function Read-ZlibHeaderVersion {
  param([Parameter(Mandatory = $true)][string]$ZlibHeaderPath)

  if (-not (Test-Path -LiteralPath $ZlibHeaderPath -PathType Leaf)) {
    return ""
  }

  foreach ($line in (Get-Content -LiteralPath $ZlibHeaderPath -ErrorAction SilentlyContinue)) {
    if ($line -match '^\s*#\s*define\s+ZLIB_VERSION\s+"([^"]+)"') {
      return $Matches[1]
    }
  }
  return ""
}

function Ensure-Zlib {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["ZLIB_VERSION"]
  if ([string]::IsNullOrWhiteSpace($version)) {
    throw "ZLIB_VERSION is missing from toolchain-versions.env."
  }

  $archiveSha256Raw = $Toolchain["ZLIB_WIN_X64_SHA256"]
  if ([string]::IsNullOrWhiteSpace($archiveSha256Raw)) {
    throw "ZLIB_WIN_X64_SHA256 is missing from toolchain-versions.env."
  }
  $archiveSha256 = $archiveSha256Raw.Trim().ToLowerInvariant()
  if ($archiveSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
    throw "Invalid ZLIB_WIN_X64_SHA256 value '$archiveSha256Raw'."
  }

  $zlibVersionRoot = Join-Path $Root "zlib/$version"
  $includeDir = Join-Path $zlibVersionRoot "include"
  $libDir = Join-Path $zlibVersionRoot "lib"
  $zlibHeader = Join-Path $includeDir "zlib.h"
  $zconfHeader = Join-Path $includeDir "zconf.h"
  $libZA = Join-Path $libDir "libz.a"

  # Idempotency: skip if already installed at the right version with both the
  # header and the static archive in place.
  if (
    (Test-Path -LiteralPath $zlibHeader -PathType Leaf) -and
    (Test-Path -LiteralPath $zconfHeader -PathType Leaf) -and
    (Test-Path -LiteralPath $libZA -PathType Leaf)
  ) {
    $installedVersion = Read-ZlibHeaderVersion -ZlibHeaderPath $zlibHeader
    if ($installedVersion -eq $version) {
      Write-Host "zlib $version already installed at $zlibVersionRoot"
      return
    }
  }

  $assetName = "zlib-$version.tar.gz"
  $assetUrl = "https://github.com/madler/zlib/releases/download/v$version/$assetName"
  $tempArchive = Join-Path $env:TEMP "codetracer-$assetName"
  $stagingRoot = Join-Path $env:TEMP "codetracer-zlib-build-$version"

  $makeInfo = Resolve-MinGWMakeExe -Root $Root -Toolchain $Toolchain
  $makeExe = [string]$makeInfo.make
  $makeBinDir = [string]$makeInfo.binDir

  $tarExe = Get-WindowsTarExe

  New-Item -ItemType Directory -Force -Path $zlibVersionRoot | Out-Null
  Download-File -Url $assetUrl -OutFile $tempArchive
  try {
    Assert-FileSha256 -Path $tempArchive -Expected $archiveSha256

    Ensure-CleanDirectory -Path $stagingRoot
    # `tar -xzf <archive> -C <dest>` extracts to `<dest>/zlib-<version>/`.
    & $tarExe -xzf $tempArchive -C $stagingRoot | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to extract zlib source archive '$tempArchive'."
    }

    $sourceDir = Join-Path $stagingRoot "zlib-$version"
    if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
      $candidates = Get-ChildItem -LiteralPath $stagingRoot -Directory -ErrorAction SilentlyContinue
      if ($candidates.Count -eq 1) {
        $sourceDir = $candidates[0].FullName
      } else {
        throw "zlib source archive did not extract a single top-level directory at '$stagingRoot'."
      }
    }

    $win32Makefile = Join-Path $sourceDir "win32/Makefile.gcc"
    if (-not (Test-Path -LiteralPath $win32Makefile -PathType Leaf)) {
      throw "Expected zlib win32 GCC Makefile at '$win32Makefile' but it is missing."
    }

    # Build libz.a (static) and headers via the canonical mingw makefile.
    # Prepend the resolved mingw bin to PATH for the build subshell so that
    # `gcc`, `ar`, `ranlib` and `mingw32-make`'s recursive invocations resolve.
    $savedPath = [Environment]::GetEnvironmentVariable("PATH")
    try {
      if (-not [string]::IsNullOrWhiteSpace($makeBinDir)) {
        [Environment]::SetEnvironmentVariable("PATH", ($makeBinDir + ";" + $savedPath), "Process")
      }

      Push-Location -LiteralPath $sourceDir
      try {
        # The win32 makefile defaults are sufficient for libz.a; we explicitly
        # invoke the static target so we don't waste time building zlib1.dll.
        & $makeExe -f "win32/Makefile.gcc" libz.a | Out-Host
        if ($LASTEXITCODE -ne 0) {
          throw "zlib build failed (mingw32-make -f win32/Makefile.gcc libz.a)."
        }
      } finally {
        Pop-Location
      }
    } finally {
      [Environment]::SetEnvironmentVariable("PATH", $savedPath, "Process")
    }

    $builtLib = Join-Path $sourceDir "libz.a"
    $builtZlibHeader = Join-Path $sourceDir "zlib.h"
    $builtZconfHeader = Join-Path $sourceDir "zconf.h"
    foreach ($expected in @($builtLib, $builtZlibHeader, $builtZconfHeader)) {
      if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) {
        throw "zlib build did not produce expected artifact '$expected'."
      }
    }

    # Stage final layout: $Root/zlib/<version>/{include,lib}/...
    Ensure-CleanDirectory -Path $includeDir
    Ensure-CleanDirectory -Path $libDir
    Copy-Item -LiteralPath $builtZlibHeader -Destination $zlibHeader -Force
    Copy-Item -LiteralPath $builtZconfHeader -Destination $zconfHeader -Force
    Copy-Item -LiteralPath $builtLib -Destination $libZA -Force

    $installedVersion = Read-ZlibHeaderVersion -ZlibHeaderPath $zlibHeader
    if ($installedVersion -ne $version) {
      throw "zlib install verification failed. Expected ZLIB_VERSION '$version' but installed header reports '$installedVersion'."
    }
  } finally {
    Remove-Item -LiteralPath $tempArchive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Host "Installed zlib $version to $zlibVersionRoot"
}
