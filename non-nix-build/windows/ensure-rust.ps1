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
  # Windows hosted runners occasionally hold a lock on the just-executed
  # rustup-init.exe for a few hundred ms after it exits (filesystem
  # close-handle race in the antivirus / loader path).  Retry the delete
  # with exponential backoff before giving up.
  $deleted = $false
  foreach ($wait in 0, 250, 500, 1000, 2000) {
    if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    try {
      Remove-Item -LiteralPath $tempExe -Force -ErrorAction Stop
      $deleted = $true
      break
    } catch {
      # File still locked; loop and retry.
    }
  }
  if (-not $deleted) {
    Write-Warning "Could not remove $tempExe after retries; leaving it for the runner cleanup."
  }

  if (-not (Test-Path $rustcExe)) {
    throw "Rust bootstrap did not produce '$rustcExe'."
  }

  $installed = (& $rustcExe --version)
  if (-not $installed.StartsWith("rustc $rustToolchain ")) {
    throw "Rust bootstrap produced unexpected version: $installed"
  }

  Ensure-RustComponents -RustupExe $rustupExe -Toolchain $rustToolchain

  # RELOCATABILITY. Rust carried the largest reparse-point count of any
  # component -- 13 -- and the check that produced that number was a bare
  # count, so for a long time nothing recorded what those 13 STORED. That
  # mattered once the audit became a hard failure: 13 junctions with absolute
  # targets would have been 13 violations and would have stopped every
  # Windows job.
  #
  # THEY ARE NOT VIOLATIONS, and the reason is upstream behaviour rather than
  # luck. rustup installs `cargo\bin\rustup.exe` as a real copy and links one
  # proxy per name in its `TOOLS` (10) and `DUP_TOOLS` (3) lists -- exactly 13
  # -- preferring a symlink and falling back to a hard link. Because link and
  # target share a directory, `utils::symlink_or_hardlink_file` takes its
  # same-directory branch and stores the BARE RELATIVE NAME `rustup.exe`
  # (rust-lang/rustup#4023 made proxies symlink-first in 1.28.0;
  # rust-lang/rustup#4226 made them relative in 1.28.1). So both branches
  # relocate: 13 relative in-tree links, or no reparse points at all.
  # `ci/test/windows-store-relocation.ps1` pins that shape through this same
  # audit, with negative controls in both violating directions.
  #
  # The SECOND relocatability defect is the one a reparse count cannot see at
  # all, and it is real: rustup records absolute directory paths as plain text
  # in `settings.toml`'s `[overrides]` table, and a tree can carry those with
  # zero reparse points. That is what the repair below is for.
  #
  # Both are handled here rather than left to a later consumer, because the
  # point of publish-and-refill is that the tree is archived immediately after
  # this function returns.
  $settingsRepair = Repair-RustupSettingsRelocatability -RustupHome $rustupHome
  if ($settingsRepair.changed) {
    Write-Host "Removed $($settingsRepair.removed_lines.Count) line(s) of absolute-path overrides from '$($settingsRepair.path)'."
  }

  $findings = @(Get-InstallTreeRelocatabilityFindings -Root $Root -Path $rustupHome -SkipContentScan |
    Where-Object { Test-RelocatabilityViolation -Finding $_ })
  if ($findings.Count -gt 0) {
    # Reported, not thrown, and on the analysis above this should now be
    # UNREACHABLE for the proxy links -- they classify as `reparse-inside-root`
    # and `Test-RelocatabilityViolation` filters them out before this line.
    # It is kept because nothing here creates those links: the layout under
    # `rustup\` is the vendor's, so a rustup that changed how it writes them
    # would change this tree without changing this repository, and the one
    # thing that must not happen is that such a change stays invisible.
    # `Assert-BootstrapRelocatability` is the gate that decides, and it now
    # fails the run for any component -- this one included.
    foreach ($finding in $findings) {
      Write-Warning "rustup tree relocatability: $($finding.kind) at '$($finding.path)' -> '$($finding.target)'"
    }
  }

  Write-Host "Installed Rust toolchain $rustToolchain with rustup $rustupVersion"
}
