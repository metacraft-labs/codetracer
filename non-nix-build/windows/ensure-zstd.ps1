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

  # If there is a manual installation at C:\zstd with include/lib, adopt it.
  #
  # RELOCATABILITY: this arm used to JUNCTION `$extractDir` at `C:\zstd`. It is
  # a COPY now, for the same reason as the LLVM system arm -- a junction bakes
  # an absolute machine-global path into the tree, so the entry only works on
  # a host that has that exact directory. And as with LLVM, a provisioning run
  # that reports zero reparse points for ZSTD is reporting that the host had no
  # `C:\zstd`, i.e. that this branch was never taken -- a host-dependent
  # observation, not evidence that the branch is safe.
  if ((Test-Path -LiteralPath (Join-Path $manualZstdRoot "include") -PathType Container) -and
      (Test-Path -LiteralPath (Join-Path $manualZstdRoot "lib") -PathType Container)) {
    $parentDir = Split-Path -Parent $zstdVersionRoot
    New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
    Ensure-CleanDirectory -Path $zstdVersionRoot

    Write-Host "Copying manual zstd install from '$manualZstdRoot' into the install root; a junction there would not survive relocation."
    Copy-Item -LiteralPath $manualZstdRoot -Destination $extractDir -Recurse -Force

    # A C:\zstd adopted for its include/ and lib/ is a library install
    # (CMake/vcpkg layout), which keeps zstd.exe under bin\ or not at all.
    # Consumers look for it at the root: ensure-clingo.ps1 unpacks clingo's
    # .tar.zst with it, and on win-ci-bare-001 every run failed there with
    # "zstd.exe not found at ...\zstd-v1.5.6-win64\zstd.exe" while this arm
    # reported ZSTD ok. It also made the up-to-date check above miss, so each
    # run re-copied. Take bin\'s exe (with its DLLs), else the pinned release's.
    if (-not (Test-Path -LiteralPath $zstdExe -PathType Leaf)) {
      $binDir = Join-Path $extractDir "bin"
      if (Test-Path -LiteralPath (Join-Path $binDir "zstd.exe") -PathType Leaf) {
        Write-Host "The manual zstd install keeps zstd.exe under bin\; copying it (and its DLLs) to $extractDir."
        Get-ChildItem -LiteralPath $binDir -File |
          Where-Object { $_.Extension -in @(".exe", ".dll") } |
          Copy-Item -Destination $extractDir -Force
      } else {
        Write-Host "The manual zstd install has no zstd.exe; taking it from the pinned zstd $version release."
        $tempZip = Join-Path $env:TEMP $asset
        $tempDir = Join-Path $env:TEMP ("zstd-exe-" + [guid]::NewGuid().ToString("N"))
        Download-File -Url "https://github.com/facebook/zstd/releases/download/v$version/$asset" -OutFile $tempZip
        try {
          $expected = $Toolchain["ZSTD_WIN_X64_SHA256"]
          if ([string]::IsNullOrWhiteSpace($expected)) {
            throw "ZSTD_WIN_X64_SHA256 is not set in toolchain-versions.env; refusing to install an unverified zstd."
          }
          Assert-FileSha256 -Path $tempZip -Expected $expected
          Expand-Archive -Path $tempZip -DestinationPath $tempDir -Force
          $releaseExe = Get-ChildItem -LiteralPath $tempDir -Recurse -File -Filter "zstd.exe" | Select-Object -First 1
          if ($null -eq $releaseExe) {
            throw "The zstd $version release archive '$asset' contains no zstd.exe."
          }
          Copy-Item -LiteralPath $releaseExe.FullName -Destination $zstdExe -Force
        } finally {
          Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
          Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
      }
      if (-not (Test-Path -LiteralPath $zstdExe -PathType Leaf)) {
        throw "zstd $version (manual-copy from '$manualZstdRoot') left no zstd.exe at '$zstdExe'."
      }
    }
    $relative = Write-InstallPointer -Root $Root -Component "zstd" `
      -VersionRoot $zstdVersionRoot -InstallDir $extractDir -Metadata @{
        zstd_version = $version
        zstd_arch = $zstdArch
        install_arm = "manual-copy"
        manual_source = $manualZstdRoot
      }
    Write-Host "Installed zstd $version (manual-copy) at $extractDir (install-relative: $relative)"
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

  $relative = Write-InstallPointer -Root $Root -Component "zstd" `
    -VersionRoot $zstdVersionRoot -InstallDir $extractDir -Metadata @{
      zstd_version = $version
      zstd_arch = $zstdArch
      install_arm = "download"
    }

  Write-Host "Installed zstd $version (download) to $extractDir (install-relative: $relative)"
}
