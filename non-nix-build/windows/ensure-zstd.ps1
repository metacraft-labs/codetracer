Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-ZstdFileArch {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "win64" }
    "arm64" { return "win64" }
    default { throw "Unsupported zstd arch '$Arch'." }
  }
}

function Ensure-Zstd {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["ZSTD_VERSION"]
  $zstdArch = ConvertTo-ZstdFileArch -Arch $Arch
  $asset = "zstd-v$version-$zstdArch.zip"
  $zstdVersionRoot = Join-Path $Root "zstd/$version"
  $extractDir = Join-Path $zstdVersionRoot "zstd-v$version-$zstdArch"
  $zstdExe = Join-Path $extractDir "zstd.exe"
  $zstdIncludeDir = Join-Path $extractDir "include"
  $zstdLibDir = Join-Path $extractDir "lib"

  # Also check for a manually installed zstd at C:\zstd.
  $manualZstdRoot = "C:\zstd"

  if (Test-Path -LiteralPath $zstdExe -PathType Leaf) {
    $currentVersion = ""
    try {
      $versionOutput = & $zstdExe --version 2>&1
      if ($versionOutput -match 'v([0-9]+\.[0-9]+\.[0-9]+)') {
        $currentVersion = $Matches[1]
      }
    } catch {}

    if ($currentVersion -eq $version) {
      Write-Host "zstd $version already installed at $extractDir"
      return
    }
  }

  # If there is a manual installation at C:\zstd with include/lib, create a junction.
  if ((Test-Path -LiteralPath (Join-Path $manualZstdRoot "include") -PathType Container) -and
      (Test-Path -LiteralPath (Join-Path $manualZstdRoot "lib") -PathType Container)) {
    $parentDir = Split-Path -Parent $zstdVersionRoot
    New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
    if (Test-Path -LiteralPath $zstdVersionRoot) {
      Remove-Item -LiteralPath $zstdVersionRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $zstdVersionRoot | Out-Null

    if (Test-Path -LiteralPath $extractDir) {
      Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
    New-Item -ItemType Junction -Path $extractDir -Target $manualZstdRoot | Out-Null
    Write-Host "zstd $version linked from manual install at $manualZstdRoot to $extractDir"
    return
  }

  # Download from GitHub releases.
  New-Item -ItemType Directory -Force -Path $zstdVersionRoot | Out-Null
  $baseUrl = "https://github.com/facebook/zstd/releases/download/v$version"
  $zipUrl = "$baseUrl/$asset"

  $tempZip = Join-Path $env:TEMP $asset
  Download-File -Url $zipUrl -OutFile $tempZip

  try {
    # Verify against the SHA256 pinned in toolchain-versions.env. zstd releases
    # do NOT ship a per-asset checksums sidecar under a predictable name (the
    # old `zstd-v<ver>-release-notes-checksums.txt` URL 404s), so this code used
    # to warn-and-proceed with NO verification. The release asset itself is
    # immutable (fixed tag), so its digest is stable and belongs in the pin file
    # alongside every other Windows toolchain SHA. Hard-fail on mismatch.
    $expected = $Toolchain["ZSTD_WIN_X64_SHA256"]
    if ([string]::IsNullOrWhiteSpace($expected)) {
      throw "ZSTD_WIN_X64_SHA256 is not set in toolchain-versions.env; refusing to install an unverified zstd."
    }
    Assert-FileSha256 -Path $tempZip -Expected $expected

    Ensure-CleanDirectory -Path $zstdVersionRoot
    Expand-Archive -Path $tempZip -DestinationPath $zstdVersionRoot -Force
  } finally {
    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
  }

  # The zstd zip may or may not contain the exe directly in the expected dir.
  if (-not (Test-Path -LiteralPath $extractDir -PathType Container)) {
    # Try to find the extracted directory.
    $candidates = Get-ChildItem -LiteralPath $zstdVersionRoot -Directory -ErrorAction SilentlyContinue
    if ($candidates.Count -eq 1) {
      Rename-Item -LiteralPath $candidates[0].FullName -NewName (Split-Path -Leaf $extractDir)
    }
  }

  # Verify that at least the include and lib directories exist.
  if (-not (Test-Path -LiteralPath $zstdIncludeDir -PathType Container) -and
      -not (Test-Path -LiteralPath $zstdLibDir -PathType Container)) {
    Write-Warning "zstd extraction completed at '$zstdVersionRoot' but include/lib directories were not found at expected location '$extractDir'."
  }

  Write-Host "Installed zstd $version to $extractDir"
}
