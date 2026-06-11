Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# clingo (Answer Set Programming solver) bootstrap for Windows DIY toolchain.
#
# Why we need it:
#   reprobuild's `repro` binary dlopens `clingo.dll` at runtime via
#   `libs/repro_solver/src/repro_solver/clingo_bindings.nim`. The same dlopen
#   also happens inside the `extract_runner.exe` helper that `repro`
#   compiles and spawns to load project-interface artifacts (the codetracer
#   build's interface-extraction step). Without clingo.dll on the DLL search
#   path, every `repro build` invocation on Windows fails immediately with
#   "could not load: clingo.dll".
#
# Why we use the conda-forge package:
#   potassco/clingo's GitHub releases do NOT publish prebuilt Windows binary
#   archives — only source tarballs (requires cmake/ninja/msvc to build).
#   The PyPI clingo wheel statically links the C library into
#   `_clingo.cp312-win_amd64.pyd` and does NOT ship a standalone clingo.dll,
#   so it cannot be re-used by Nim's runtime dlopen. The conda-forge
#   `clingo` package on the other hand bundles the native `Library/bin/
#   clingo.dll` alongside the CLI (`clingo.exe`, `clasp.exe`, `gringo.exe`).
#   The bundled clingo.dll is a plain C library, ABI-stable across the
#   Python ABIs the conda variants target (the `pyXXX` suffix only affects
#   the bundled `_clingo.cpython-XXX.pyd`, which we ignore).
#
# Package format:
#   conda-forge `.conda` packages are ZIP archives containing two
#   `.tar.zst` payloads:
#     * info-<pkg>-<ver>-<build>.tar.zst   — metadata
#     * pkg-<pkg>-<ver>-<build>.tar.zst    — files
#   We unzip with PowerShell's Expand-Archive, decompress the `pkg-`
#   payload with zstd (provisioned by ensure-zstd.ps1, on PATH by this
#   point in env.ps1 phase 1), then untar with the Windows-bundled
#   tar.exe at `$env:WINDIR\System32\tar.exe`.
#
# Layout produced:
#   $Root/clingo/<version>/bin/clingo.dll
#   $Root/clingo/<version>/bin/clingo.exe   (and the other CLI tools)
#
# The bin dir is added to PATH by env.ps1 so both the repro daemon and the
# spawned extract_runner.exe resolve the DLL via the standard Win32 loader
# search.

function Get-WindowsSystem32TarExe {
  $candidate = Join-Path $env:WINDIR "System32\tar.exe"
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    return $candidate
  }
  throw "Windows-bundled tar.exe not found at '$candidate'. ensure-clingo.ps1 requires Windows 10+ which ships bsdtar in System32."
}

function Resolve-ZstdExe {
  param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Arch, [Parameter(Mandatory = $true)][hashtable]$Toolchain)

  $zstdArch = ConvertTo-ZstdFileArch -Arch $Arch
  $zstdDir = Join-Path $Root ("zstd\" + $Toolchain["ZSTD_VERSION"] + "\zstd-v" + $Toolchain["ZSTD_VERSION"] + "-" + $zstdArch)
  $candidate = Join-Path $zstdDir "zstd.exe"
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    return $candidate
  }
  $fromPath = Get-Command zstd.exe -ErrorAction SilentlyContinue
  if ($null -ne $fromPath -and -not [string]::IsNullOrWhiteSpace($fromPath.Source)) {
    return $fromPath.Source
  }
  throw "zstd.exe not found at '$candidate' nor on PATH. ensure-clingo.ps1 must run after ensure-zstd.ps1."
}

function Ensure-Clingo {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  if ($Arch -ne "x64") {
    Write-Warning "ensure-clingo.ps1: conda-forge clingo Windows packages are x64-only. Skipping on '$Arch'."
    return
  }

  $version = $Toolchain["CLINGO_VERSION"]
  if ([string]::IsNullOrWhiteSpace($version)) {
    throw "CLINGO_VERSION is missing from toolchain-versions.env."
  }

  $expectedSha = $Toolchain["CLINGO_WIN_X64_CONDA_SHA256"]
  if ([string]::IsNullOrWhiteSpace($expectedSha)) {
    throw "CLINGO_WIN_X64_CONDA_SHA256 is missing from toolchain-versions.env."
  }
  $expectedSha = $expectedSha.Trim().ToLowerInvariant()
  if ($expectedSha -notmatch '^[A-Fa-f0-9]{64}$') {
    throw "Invalid CLINGO_WIN_X64_CONDA_SHA256 value '$($Toolchain["CLINGO_WIN_X64_CONDA_SHA256"])'."
  }

  $condaUrl = $Toolchain["CLINGO_WIN_X64_CONDA_URL"]
  if ([string]::IsNullOrWhiteSpace($condaUrl)) {
    throw "CLINGO_WIN_X64_CONDA_URL is missing from toolchain-versions.env."
  }

  $clingoVersionRoot = Join-Path $Root "clingo/$version"
  $binDir = Join-Path $clingoVersionRoot "bin"
  $clingoDll = Join-Path $binDir "clingo.dll"

  if (Test-Path -LiteralPath $clingoDll -PathType Leaf) {
    Write-Host "clingo $version already installed at $clingoVersionRoot"
    return
  }

  $tempConda = Join-Path $env:TEMP "codetracer-clingo-$version.conda"
  $stagingRoot = Join-Path $env:TEMP "codetracer-clingo-extract-$version"

  $tarExe = Get-WindowsSystem32TarExe
  $zstdExe = Resolve-ZstdExe -Root $Root -Arch $Arch -Toolchain $Toolchain

  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  Download-File -Url $condaUrl -OutFile $tempConda
  try {
    Assert-FileSha256 -Path $tempConda -Expected $expectedSha

    Ensure-CleanDirectory -Path $stagingRoot
    # `.conda` files are ZIP archives. Rename to .zip so Expand-Archive
    # accepts the extension; PowerShell's expander doesn't sniff content.
    $tempZip = [System.IO.Path]::ChangeExtension($tempConda, ".zip")
    Copy-Item -LiteralPath $tempConda -Destination $tempZip -Force
    try {
      Expand-Archive -LiteralPath $tempZip -DestinationPath $stagingRoot -Force
    } finally {
      Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
    }

    # The package payload lives in `pkg-clingo-<ver>-<build>.tar.zst`.
    $payloadZst = Get-ChildItem -LiteralPath $stagingRoot -Filter "pkg-clingo-*.tar.zst" -File | Select-Object -First 1
    if ($null -eq $payloadZst) {
      throw "conda package did not contain expected pkg-clingo-*.tar.zst payload under '$stagingRoot'."
    }

    $payloadTar = [System.IO.Path]::ChangeExtension($payloadZst.FullName, ".tar")
    & $zstdExe -d -f -o $payloadTar $payloadZst.FullName | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to decompress conda payload with zstd: '$($payloadZst.FullName)'."
    }

    # Windows-bundled bsdtar refuses bare drive-letter destination paths
    # (it interprets `C:` / `D:` as a remote host spec like rsync). Untar
    # into a relative scratch dir from the staging cwd to dodge that.
    $untarDir = Join-Path $stagingRoot "files"
    Ensure-CleanDirectory -Path $untarDir
    Push-Location -LiteralPath $stagingRoot
    try {
      & $tarExe -xf $payloadTar -C "files" | Out-Host
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to untar conda payload '$payloadTar'."
      }
    } finally {
      Pop-Location
    }

    # conda-forge clingo layout (Windows): Library\bin\{clingo.dll,
    # clingo.exe, clasp.exe, gringo.exe, lpconvert.exe, reify.exe}.
    # Copy every .dll and .exe to our bin dir; the CLI tools are useful
    # operator-facing diagnostics and the DLL is what repro needs.
    $stagedBin = Join-Path $untarDir "Library\bin"
    if (-not (Test-Path -LiteralPath $stagedBin -PathType Container)) {
      throw "conda package did not contain expected 'Library/bin/' directory at '$stagedBin'."
    }

    $copied = 0
    foreach ($pattern in @("*.dll", "*.exe")) {
      foreach ($file in Get-ChildItem -LiteralPath $stagedBin -Filter $pattern -File -ErrorAction SilentlyContinue) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $binDir $file.Name) -Force
        $copied++
      }
    }
    if (-not (Test-Path -LiteralPath $clingoDll -PathType Leaf)) {
      throw "conda package extraction did not produce '$clingoDll' (copied $copied file(s))."
    }
  } finally {
    Remove-Item -LiteralPath $tempConda -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Host "Installed clingo $version to $clingoVersionRoot"
}
