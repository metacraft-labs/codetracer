Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Gcc {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["GCC_VERSION"]
  $gccRoot = Join-Path $Root "gcc/$version"
  $gccBinDir = Join-Path $gccRoot "bin"
  $gccExe = Join-Path $gccBinDir "gcc.exe"

  if (Test-Path -LiteralPath $gccExe -PathType Leaf) {
    $currentVersion = ""
    try {
      $versionOutput = & $gccExe --version 2>&1 | Select-Object -First 1
      if ($versionOutput -match '([0-9]+\.[0-9]+\.[0-9]+)') {
        $currentVersion = $Matches[1]
      }
    } catch {}

    if ($currentVersion -eq $version) {
      Write-Host "gcc $version already installed at $gccRoot"
      return
    }
  }

  # Locate the WinLibs installation from winget.
  $winlibsPackageDir = ""
  $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
  if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
    $wingetRoot = Join-Path $localAppData "Microsoft\WinGet\Packages"
    if (Test-Path -LiteralPath $wingetRoot -PathType Container) {
      $candidate = Get-ChildItem -LiteralPath $wingetRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "BrechtSanders.WinLibs.POSIX.UCRT*" } |
        Select-Object -First 1
      if ($null -ne $candidate) {
        $mingw64 = Join-Path $candidate.FullName "mingw64"
        if (Test-Path -LiteralPath $mingw64 -PathType Container) {
          $winlibsPackageDir = $mingw64
        }
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($winlibsPackageDir)) {
    # Winget-free fallback: fetch the pinned WinLibs UCRT build directly from its
    # GitHub release, verify its SHA256, and extract it into the DIY cache. This
    # is the path CI / self-hosted runners take, where winget is not installed
    # (env.ps1 provisions Node/uv/TTD the same download-and-verify way). winget
    # below stays as a last resort for interactive dev boxes that pin neither.
    $winlibsUrl = $Toolchain["WINLIBS_GCC_URL"]
    $winlibsSha = $Toolchain["WINLIBS_GCC_SHA256"]
    if (-not [string]::IsNullOrWhiteSpace($winlibsUrl) -and
        -not [string]::IsNullOrWhiteSpace($winlibsSha)) {
      $normalizedSha = $winlibsSha.Trim().ToLowerInvariant()
      if ($normalizedSha -notmatch '^[0-9a-f]{64}$') {
        throw "WINLIBS_GCC_SHA256 must be a 64-character hexadecimal SHA256."
      }
      # The archive's top-level directory is `mingw64/`, so it extracts to
      # $stageRoot/mingw64; the junction below points $gccRoot at that dir.
      $stageRoot = Join-Path $Root "gcc/winlibs-$version"
      $stagedMingw64 = Join-Path $stageRoot "mingw64"
      $stagedGcc = Join-Path $stagedMingw64 "bin/gcc.exe"
      if (-not (Test-Path -LiteralPath $stagedGcc -PathType Leaf)) {
        Write-Host "Downloading WinLibs (GCC $version) from $winlibsUrl ..."
        $tempZip = Join-Path $env:TEMP "codetracer-winlibs-$normalizedSha.zip"
        Download-File -Url $winlibsUrl -OutFile $tempZip
        try {
          Assert-FileSha256 -Path $tempZip -Expected $normalizedSha
          Ensure-CleanDirectory -Path $stageRoot
          # bsdtar (System32 tar.exe) unpacks the .zip faster than Expand-Archive
          # and without its MAX_PATH limits on WinLibs' deep mingw64 tree — the
          # same extractor ensure-llvm / ensure-zlib use. Top-level dir: mingw64/.
          $tarExe = Get-WindowsTarExe
          & $tarExe -xf $tempZip -C $stageRoot
          if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract WinLibs archive '$tempZip' with '$tarExe' (exit $LASTEXITCODE)."
          }
        }
        finally {
          Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        }
      }
      if (Test-Path -LiteralPath $stagedGcc -PathType Leaf) {
        $winlibsPackageDir = $stagedMingw64
        Write-Host "Installed WinLibs (GCC $version) at $stagedMingw64"
      }
      else {
        throw "WinLibs archive extracted to '$stageRoot' but gcc.exe not found at '$stagedGcc'."
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($winlibsPackageDir)) {
    # Try installing via winget.
    $wingetCommand = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -eq $wingetCommand) {
      throw "WinLibs GCC is not installed and winget is not available. Install WinLibs manually or via: winget install BrechtSanders.WinLibs.POSIX.UCRT"
    }

    Write-Host "Installing WinLibs (GCC $version) via winget..."
    & winget install BrechtSanders.WinLibs.POSIX.UCRT --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to install WinLibs via winget."
    }

    $candidate = Get-ChildItem -LiteralPath (Join-Path $localAppData "Microsoft\WinGet\Packages") -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like "BrechtSanders.WinLibs.POSIX.UCRT*" } |
      Select-Object -First 1
    if ($null -ne $candidate) {
      $mingw64 = Join-Path $candidate.FullName "mingw64"
      if (Test-Path -LiteralPath $mingw64 -PathType Container) {
        $winlibsPackageDir = $mingw64
      }
    }

    if ([string]::IsNullOrWhiteSpace($winlibsPackageDir)) {
      throw "WinLibs winget install completed but could not locate the mingw64 directory."
    }
  }

  # Create a junction from the managed install root to the WinLibs directory.
  $parentDir = Split-Path -Parent $gccRoot
  New-Item -ItemType Directory -Force -Path $parentDir | Out-Null

  if (Test-Path -LiteralPath $gccRoot) {
    Remove-Item -LiteralPath $gccRoot -Recurse -Force
  }
  New-Item -ItemType Junction -Path $gccRoot -Target $winlibsPackageDir | Out-Null

  $gccExeCheck = Join-Path $gccBinDir "gcc.exe"
  if (-not (Test-Path -LiteralPath $gccExeCheck -PathType Leaf)) {
    throw "WinLibs junction created at '$gccRoot' but gcc.exe not found at '$gccExeCheck'."
  }

  Write-Host "Installed GCC $version (WinLibs) at $gccRoot"
}
