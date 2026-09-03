Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Nextest {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["CARGO_NEXTEST_VERSION"]
  $expectedSha = $Toolchain["CARGO_NEXTEST_WIN_X64_SHA256"]
  if ([string]::IsNullOrWhiteSpace($expectedSha) -or $expectedSha -notmatch '^[A-Fa-f0-9]{64}$') {
    throw "Missing or invalid CARGO_NEXTEST_WIN_X64_SHA256 in toolchain-versions.env."
  }

  $cargoHome = Join-Path $Root "cargo"
  $binDir = Join-Path $cargoHome "bin"
  $nextestExe = Join-Path $binDir "cargo-nextest.exe"

  if (Test-Path -LiteralPath $nextestExe -PathType Leaf) {
    $currentVersion = ""
    try {
      $versionOutput = & $nextestExe nextest --version 2>&1
      if ($versionOutput -match '([0-9]+(?:\.[0-9]+)*)') {
        $currentVersion = $Matches[1]
      }
    } catch {}

    if ($currentVersion -eq $version) {
      Write-Host "cargo-nextest $version already installed at $nextestExe"
      return
    }
  }

  # Install the official prebuilt Windows binary rather than building from
  # source. `cargo install cargo-nextest` needs the MSVC linker (link.exe),
  # which env.ps1 does not put on PATH until AFTER this toolchain-bootstrap
  # phase, so a source build fails here with "linker `link.exe` not found".
  # The prebuilt archive is SHA-pinned by CARGO_NEXTEST_WIN_X64_SHA256; this
  # mirrors the Ensure-Just / Ensure-Gcc direct-download pattern and removes
  # the MSVC dependency from this phase entirely.
  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  $asset = "cargo-nextest-$version-x86_64-pc-windows-msvc.zip"
  $downloadUrl = "https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-$version/$asset"
  $tempZip = Join-Path $env:TEMP "codetracer-$asset"
  $extractDir = Join-Path $env:TEMP ("codetracer-nextest-" + [Guid]::NewGuid().ToString('N'))

  Write-Host "Downloading cargo-nextest $version from $downloadUrl ..."
  Download-File -Url $downloadUrl -OutFile $tempZip
  try {
    Assert-FileSha256 -Path $tempZip -Expected $expectedSha
    Ensure-CleanDirectory -Path $extractDir
    Expand-Archive -LiteralPath $tempZip -DestinationPath $extractDir -Force
    $extractedExe = Join-Path $extractDir "cargo-nextest.exe"
    if (-not (Test-Path -LiteralPath $extractedExe -PathType Leaf)) {
      throw "cargo-nextest archive '$asset' did not contain cargo-nextest.exe."
    }
    Copy-Item -LiteralPath $extractedExe -Destination $nextestExe -Force
  } finally {
    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  if (-not (Test-Path -LiteralPath $nextestExe -PathType Leaf)) {
    throw "cargo-nextest installation did not produce '$nextestExe'."
  }

  Write-Host "Installed cargo-nextest $version to $nextestExe"
}
