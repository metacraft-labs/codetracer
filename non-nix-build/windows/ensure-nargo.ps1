Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Nargo {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain,
    [Parameter(Mandatory = $true)][string]$RepoRoot
  )

  $cargoHome = Join-Path $Root "cargo"
  $rustupHome = Join-Path $Root "rustup"
  $cargoExe = Join-Path $cargoHome "bin/cargo.exe"
  if (-not (Test-Path -LiteralPath $cargoExe -PathType Leaf)) {
    throw "Nargo bootstrap requires '$cargoExe'. Run Rust bootstrap first."
  }

  $env:CARGO_HOME = $cargoHome
  $env:RUSTUP_HOME = $rustupHome

  $gitCommand = Get-Command git -ErrorAction SilentlyContinue
  if ($null -eq $gitCommand -or [string]::IsNullOrWhiteSpace($gitCommand.Source)) {
    throw "git is required for nargo source bootstrap but was not found on PATH."
  }
  $rustupExe = Join-Path $cargoHome "bin/rustup.exe"
  if (-not (Test-Path -LiteralPath $rustupExe -PathType Leaf)) {
    throw "Nargo bootstrap requires '$rustupExe'. Run Rust bootstrap first."
  }

  $flakeLockPath = Join-Path $RepoRoot "flake.lock"
  $noir = Get-FlakeLockedGithubNode -FlakeLockPath $flakeLockPath -NodeName "noir"

  $nargoRoot = Join-Path $Root "nargo"
  $cacheRoot = Join-Path $nargoRoot "cache/source/$($noir.rev)"
  $sourceDir = Join-Path $cacheRoot "noir"
  $installDir = Join-Path $nargoRoot "cache/source/$($noir.rev)/install"
  $nargoExe = Join-Path $installDir "nargo.exe"
  $installPathFile = Join-Path $nargoRoot "nargo.install.relative-path"
  $installMetaFile = Join-Path $nargoRoot "nargo.install.meta"

  $expectedMetadata = @{
    source = "github"
    owner = $noir.owner
    repo = $noir.repo
    revision = $noir.rev
    repository = $noir.url
    rust_toolchain = "nightly"
  }

  if ((Test-Path -LiteralPath $nargoExe -PathType Leaf) -and (Test-Path -LiteralPath $installMetaFile -PathType Leaf)) {
    $existingMeta = Read-KeyValueFile -Path $installMetaFile
    if (Test-KeyValueFileMatches -Expected $expectedMetadata -Actual $existingMeta) {
      $relativeInstallDir = ConvertTo-InstallRelativePath -AbsolutePath $installDir -Root $Root
      Set-Content -LiteralPath $installPathFile -Value $relativeInstallDir -Encoding ASCII
      Write-Host "nargo source cache hit at $installDir"
      return
    }
  }

  Ensure-CleanDirectory -Path $cacheRoot
  New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $installDir | Out-Null

  & $gitCommand.Source -c core.longpaths=true clone $noir.url $sourceDir
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to clone Noir repository '$($noir.url)'."
  }

  & $gitCommand.Source -c core.longpaths=true -C $sourceDir checkout $noir.rev
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to checkout Noir revision '$($noir.rev)'."
  }

  $nargoCargoTomlPath = Join-Path $sourceDir "tooling/nargo_cli/Cargo.toml"
  if (-not (Test-Path -LiteralPath $nargoCargoTomlPath -PathType Leaf)) {
    throw "Expected nargo_cli Cargo.toml at '$nargoCargoTomlPath'."
  }
  $nargoCargoTomlContent = Get-Content -LiteralPath $nargoCargoTomlPath -Raw -Encoding UTF8
  if ($nargoCargoTomlContent -match '(?m)^termion\s*=\s*"3\.0\.0"\s*$') {
    $patchedNargoCargoTomlContent = [regex]::Replace(
      $nargoCargoTomlContent,
      '(?m)^termion\s*=\s*"3\.0\.0"\s*$',
      ''
    )
    Set-Content -LiteralPath $nargoCargoTomlPath -Value $patchedNargoCargoTomlContent -Encoding UTF8
  }

  $compileCmdPath = Join-Path $sourceDir "tooling/nargo_cli/src/cli/compile_cmd.rs"
  if (-not (Test-Path -LiteralPath $compileCmdPath -PathType Leaf)) {
    throw "Expected nargo_cli compile command source at '$compileCmdPath'."
  }
  $compileCmdContent = Get-Content -LiteralPath $compileCmdPath -Raw -Encoding UTF8
  $compileCmdPatched = $compileCmdContent.
    Replace('write!(screen, "{}", termion::cursor::Save).unwrap();', 'write!(screen, "\x1b[s").unwrap();').
    Replace('write!(screen, "{}{}", termion::cursor::Restore, termion::clear::AfterCursor).unwrap();', 'write!(screen, "{}{}", "\x1b[u", "\x1b[J").unwrap();')
  Set-Content -LiteralPath $compileCmdPath -Value $compileCmdPatched -Encoding UTF8

  $msys2 = Ensure-TupMsys2BuildPrereqs -Root $Root -Toolchain $Toolchain
  $msysBashExe = [string]$msys2.bashExe
  $msysMingwBinDir = Join-Path ([string]$msys2.root) "mingw64/bin"
  $clangExe = Join-Path $msysMingwBinDir "clang.exe"
  if (-not (Test-Path -LiteralPath $clangExe -PathType Leaf)) {
    & $msysBashExe -lc "set -euo pipefail; pacman -Sy --noconfirm --needed mingw-w64-x86_64-clang"
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to install MSYS2 clang prerequisite for nargo bootstrap."
    }
  }

  $windowsDir = Join-Path $RepoRoot "non-nix-build/windows"
  $msvcExportScript = Join-Path $windowsDir "export-msvc-env.ps1"
  if (Test-Path -LiteralPath $msvcExportScript -PathType Leaf) {
    $msvcEnvLines = & pwsh -NoProfile -ExecutionPolicy Bypass -File $msvcExportScript
    foreach ($line in $msvcEnvLines) {
      if ([string]::IsNullOrWhiteSpace($line) -or ($line -notmatch "=")) {
        continue
      }
      $separatorIndex = $line.IndexOf("=")
      if ($separatorIndex -lt 1) {
        continue
      }
      $name = $line.Substring(0, $separatorIndex)
      $value = $line.Substring($separatorIndex + 1)
      Set-Item -Path "Env:$name" -Value $value
    }
  }
  $env:Path = "$msysMingwBinDir;$($env:Path)"

  Push-Location $sourceDir
  try {
    & $rustupExe toolchain install nightly --profile minimal
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to install nightly toolchain required for nargo bootstrap."
    }
    & $cargoExe +nightly build --release -p nargo_cli --bin nargo
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to build nargo from '$sourceDir'."
    }
  } finally {
    Pop-Location
  }

  $builtNargoCandidates = @(
    (Join-Path $sourceDir "target/release/nargo.exe"),
    (Join-Path $sourceDir "target/release/nargo")
  )
  $builtNargo = $builtNargoCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if ([string]::IsNullOrWhiteSpace($builtNargo)) {
    throw "Noir build did not produce a nargo executable in target/release."
  }

  Copy-Item -LiteralPath $builtNargo -Destination $nargoExe -Force

  $relativeInstallDir = ConvertTo-InstallRelativePath -AbsolutePath $installDir -Root $Root
  Write-KeyValueFile -Path $installMetaFile -Values $expectedMetadata
  Set-Content -LiteralPath $installPathFile -Value $relativeInstallDir -Encoding ASCII

  Write-Host "Installed nargo from flake.lock noir revision $($noir.rev) to $installDir"
}
