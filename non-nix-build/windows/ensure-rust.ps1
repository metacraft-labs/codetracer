Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-RustTarget {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "x86_64-pc-windows-msvc" }
    "arm64" { return "aarch64-pc-windows-msvc" }
    default { throw "Unsupported Rust target arch '$Arch'." }
  }
}

function Ensure-Rust {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $rustToolchain = $Toolchain["RUST_TOOLCHAIN_VERSION"]
  $rustupVersion = $Toolchain["RUSTUP_VERSION"]
  $rustTarget = ConvertTo-RustTarget -Arch $Arch
  $rustupHome = Join-Path $Root "rustup"
  $cargoHome = Join-Path $Root "cargo"
  $rustcExe = Join-Path $cargoHome "bin/rustc.exe"
  $rustupExe = Join-Path $cargoHome "bin/rustup.exe"

  function Ensure-RustComponents {
    param(
      [Parameter(Mandatory = $true)][string]$RustupExe,
      [Parameter(Mandatory = $true)][string]$Toolchain
    )

    if (-not (Test-Path -LiteralPath $RustupExe -PathType Leaf)) {
      throw "Rustup executable missing at '$RustupExe'."
    }

    & $RustupExe component add clippy --toolchain $Toolchain | Out-Null
  }

  if (Test-Path $rustcExe) {
    $current = (& $rustcExe --version)
    if ($current.StartsWith("rustc $rustToolchain ")) {
      Write-Host "Rust $rustToolchain already installed at $cargoHome"
      $env:RUSTUP_HOME = $rustupHome
      $env:CARGO_HOME = $cargoHome
      Ensure-RustComponents -RustupExe $rustupExe -Toolchain $rustToolchain
      return
    }
  }

  New-Item -ItemType Directory -Force -Path $rustupHome | Out-Null
  New-Item -ItemType Directory -Force -Path $cargoHome | Out-Null

  $baseUrl = "https://static.rust-lang.org/rustup/archive/$rustupVersion/$rustTarget"
  $exeUrl = "$baseUrl/rustup-init.exe"
  $shaUrl = "$baseUrl/rustup-init.exe.sha256"
  $tempExe = Join-Path $env:TEMP "rustup-init-$rustupVersion-$rustTarget.exe"

  Download-File -Url $exeUrl -OutFile $tempExe
  $shaText = Download-String -Url $shaUrl
  $expected = Get-ExpectedSha256 -ShaSource $shaText -AssetName "rustup-init.exe"
  Assert-FileSha256 -Path $tempExe -Expected $expected

  $env:RUSTUP_HOME = $rustupHome
  $env:CARGO_HOME = $cargoHome

  & $tempExe -y --default-toolchain $rustToolchain --profile minimal --no-modify-path
  Remove-Item -LiteralPath $tempExe -Force

  if (-not (Test-Path $rustcExe)) {
    throw "Rust bootstrap did not produce '$rustcExe'."
  }

  $installed = (& $rustcExe --version)
  if (-not $installed.StartsWith("rustc $rustToolchain ")) {
    throw "Rust bootstrap produced unexpected version: $installed"
  }

  Ensure-RustComponents -RustupExe $rustupExe -Toolchain $rustToolchain
  Write-Host "Installed Rust toolchain $rustToolchain with rustup $rustupVersion"
}
