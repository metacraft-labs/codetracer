Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Just {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["JUST_VERSION"]
  $cargoHome = Join-Path $Root "cargo"
  $justExe = Join-Path $cargoHome "bin/just.exe"
  $cargoExe = Join-Path $cargoHome "bin/cargo.exe"

  if (-not (Test-Path -LiteralPath $cargoExe -PathType Leaf)) {
    throw "Ensure-Just requires cargo at '$cargoExe'. Run Ensure-Rust first."
  }

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

  Write-Host "Installing just $version via cargo..."
  $env:CARGO_HOME = $cargoHome
  & $cargoExe install just --version $version --locked
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to install just $version via cargo."
  }

  if (-not (Test-Path -LiteralPath $justExe -PathType Leaf)) {
    throw "cargo install just did not produce '$justExe'."
  }

  Write-Host "Installed just $version to $justExe"
}
