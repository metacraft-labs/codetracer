Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# sccache, the Rust compiler cache the Windows origin-DAP jobs put in front of
# rustc (RUSTC_WRAPPER) so db-backend's test build is warm on a runner that
# starts clean: it took 37 minutes cold on win-ci-vm-001 (run 45718096371).
# The official prebuilt binary, pinned by SCCACHE_WIN_X64_SHA256, into
# CARGO_HOME\bin beside just and cargo-nextest, which env.ps1 puts on PATH.
function Ensure-Sccache {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["SCCACHE_VERSION"]
  $expectedSha = $Toolchain["SCCACHE_WIN_X64_SHA256"]
  if ([string]::IsNullOrWhiteSpace($expectedSha) -or $expectedSha -notmatch '^[A-Fa-f0-9]{64}$') {
    throw "Missing or invalid SCCACHE_WIN_X64_SHA256 in toolchain-versions.env."
  }

  $binDir = Join-Path (Join-Path $Root "cargo") "bin"
  $sccacheExe = Join-Path $binDir "sccache.exe"

  if (Test-Path -LiteralPath $sccacheExe -PathType Leaf) {
    $currentVersion = ""
    try {
      $versionOutput = & $sccacheExe --version 2>&1
      if ("$versionOutput" -match '([0-9]+(?:\.[0-9]+)+)') {
        $currentVersion = $Matches[1]
      }
    } catch {}

    if ($currentVersion -eq $version) {
      Write-Host "sccache $version already installed at $sccacheExe"
      return
    }
  }

  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  $stem = "sccache-v$version-x86_64-pc-windows-msvc"
  $asset = "$stem.zip"
  $downloadUrl = "https://github.com/mozilla/sccache/releases/download/v$version/$asset"
  $tempZip = Join-Path $env:TEMP "codetracer-$asset"
  $extractDir = Join-Path $env:TEMP ("codetracer-sccache-" + [Guid]::NewGuid().ToString('N'))

  Write-Host "Downloading sccache $version from $downloadUrl ..."
  Download-File -Url $downloadUrl -OutFile $tempZip
  try {
    Assert-FileSha256 -Path $tempZip -Expected $expectedSha
    Ensure-CleanDirectory -Path $extractDir
    Expand-Archive -LiteralPath $tempZip -DestinationPath $extractDir -Force
    $extractedExe = Join-Path (Join-Path $extractDir $stem) "sccache.exe"
    if (-not (Test-Path -LiteralPath $extractedExe -PathType Leaf)) {
      throw "sccache archive '$asset' did not contain $stem\sccache.exe."
    }
    Copy-Item -LiteralPath $extractedExe -Destination $sccacheExe -Force
  } finally {
    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  if (-not (Test-Path -LiteralPath $sccacheExe -PathType Leaf)) {
    throw "sccache installation did not produce '$sccacheExe'."
  }

  Write-Host "Installed sccache $version to $sccacheExe"
}
