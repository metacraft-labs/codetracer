Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Nextest {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["CARGO_NEXTEST_VERSION"]
  $cargoHome = Join-Path $Root "cargo"
  $nextestExe = Join-Path $cargoHome "bin/cargo-nextest.exe"
  $cargoExe = Join-Path $cargoHome "bin/cargo.exe"

  if (-not (Test-Path -LiteralPath $cargoExe -PathType Leaf)) {
    Write-Warning "Ensure-Nextest: cargo not found at '$cargoExe'. Skipping (install Rust first)."
    return
  }

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

  Write-Host "Installing cargo-nextest $version via cargo..."
  $env:CARGO_HOME = $cargoHome
  & $cargoExe install cargo-nextest --version $version --locked
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to install cargo-nextest $version via cargo."
  }

  if (-not (Test-Path -LiteralPath $nextestExe -PathType Leaf)) {
    throw "cargo install cargo-nextest did not produce '$nextestExe'."
  }

  Write-Host "Installed cargo-nextest $version to $nextestExe"
}
