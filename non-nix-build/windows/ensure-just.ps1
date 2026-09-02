Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Just {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["JUST_VERSION"]
  $expectedSha = $Toolchain["JUST_WIN_X64_SHA256"]
  if ([string]::IsNullOrWhiteSpace($expectedSha) -or $expectedSha -notmatch '^[A-Fa-f0-9]{64}$') {
    throw "Missing or invalid JUST_WIN_X64_SHA256 in toolchain-versions.env."
  }

  $cargoHome = Join-Path $Root "cargo"
  $binDir = Join-Path $cargoHome "bin"
  $justExe = Join-Path $binDir "just.exe"

  if (Test-Path -LiteralPath $justExe -PathType Leaf) {
    $currentVersion = ""
    try {
      $versionOutput = & $justExe --version 2>&1
      if ($versionOutput -match '([0-9]+(?:\.[0-9]+)*)') {
        $currentVersion = $Matches[1]
      }
    } catch {}

    if ($currentVersion -eq $version) {
      Write-Host "just $version already installed at $justExe"
      return
    }
  }

  # Install the official prebuilt Windows binary rather than building from
  # source. `cargo install just` compiles proc-macro2/quote/etc., which need
  # the MSVC linker (link.exe) -- but env.ps1 does not put MSVC on PATH until
  # AFTER this toolchain-bootstrap phase, so a source build fails here with
  # "linker `link.exe` not found". The prebuilt archive is already pinned by
  # JUST_WIN_X64_SHA256 (ci/ensure-origin-dap-windows-toolchain.ps1 consumes
  # the same pin), so this mirrors the Ensure-Gcc / Ensure-Ldc direct-download
  # pattern and removes the MSVC dependency from this phase entirely.
  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  $asset = "just-$version-x86_64-pc-windows-msvc.zip"
  $downloadUrl = "https://github.com/casey/just/releases/download/$version/$asset"
  $tempZip = Join-Path $env:TEMP "codetracer-$asset"
  $extractDir = Join-Path $env:TEMP ("codetracer-just-" + [Guid]::NewGuid().ToString('N'))

  Write-Host "Downloading just $version from $downloadUrl ..."
  Download-File -Url $downloadUrl -OutFile $tempZip
  try {
    Assert-FileSha256 -Path $tempZip -Expected $expectedSha
    Ensure-CleanDirectory -Path $extractDir
    Expand-Archive -LiteralPath $tempZip -DestinationPath $extractDir -Force
    $extractedExe = Join-Path $extractDir "just.exe"
    if (-not (Test-Path -LiteralPath $extractedExe -PathType Leaf)) {
      throw "just archive '$asset' did not contain just.exe."
    }
    Copy-Item -LiteralPath $extractedExe -Destination $justExe -Force
  } finally {
    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  if (-not (Test-Path -LiteralPath $justExe -PathType Leaf)) {
    throw "just installation did not produce '$justExe'."
  }

  Write-Host "Installed just $version to $justExe"
}
