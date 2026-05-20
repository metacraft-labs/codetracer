Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-LlvmFileArch {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "x86_64-pc-windows-msvc" }
    "arm64" { return "aarch64-pc-windows-msvc" }
    default { throw "Unsupported LLVM arch '$Arch'." }
  }
}

function Ensure-Llvm {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["LLVM_VERSION"]
  $llvmTarget = ConvertTo-LlvmFileArch -Arch $Arch
  # Upstream publishes the Windows toolchain tarball as
  # `clang+llvm-<ver>-<target>.tar.xz` (the `LLVM-<ver>-<target>.tar.xz`
  # name never existed — only the `LLVM-<ver>-win64.exe` installer uses
  # the `LLVM-` prefix). The archive's top-level directory matches the
  # asset stem, so $extractDir must use the same `clang+llvm-` prefix.
  $asset = "clang+llvm-$version-$llvmTarget.tar.xz"
  $llvmVersionRoot = Join-Path $Root "llvm/$version"
  $extractDir = Join-Path $llvmVersionRoot "clang+llvm-$version-$llvmTarget"
  $clangExe = Join-Path $extractDir "bin/clang.exe"

  # Also check for a system LLVM installed via winget or standard paths.
  $systemLlvmCandidates = @(
    (Join-Path ${env:ProgramFiles} "LLVM"),
    (Join-Path ${env:ProgramFiles(x86)} "LLVM")
  )

  if (Test-Path -LiteralPath $clangExe -PathType Leaf) {
    $currentVersion = ""
    try {
      $versionOutput = & $clangExe --version 2>&1 | Select-Object -First 1
      if ($versionOutput -match '([0-9]+\.[0-9]+\.[0-9]+)') {
        $currentVersion = $Matches[1]
      }
    } catch {}

    if ($currentVersion -eq $version) {
      Write-Host "LLVM $version already installed at $extractDir"
      return
    }
  }

  # Check for a system-wide LLVM installation at the correct version.
  foreach ($systemDir in $systemLlvmCandidates) {
    $systemClang = Join-Path $systemDir "bin/clang.exe"
    if (Test-Path -LiteralPath $systemClang -PathType Leaf) {
      $currentVersion = ""
      try {
        $versionOutput = & $systemClang --version 2>&1 | Select-Object -First 1
        if ($versionOutput -match '([0-9]+\.[0-9]+\.[0-9]+)') {
          $currentVersion = $Matches[1]
        }
      } catch {}

      if ($currentVersion -eq $version) {
        $parentDir = Split-Path -Parent $llvmVersionRoot
        New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
        if (Test-Path -LiteralPath $llvmVersionRoot) {
          Remove-Item -LiteralPath $llvmVersionRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $llvmVersionRoot | Out-Null
        if (Test-Path -LiteralPath $extractDir) {
          Remove-Item -LiteralPath $extractDir -Recurse -Force
        }
        New-Item -ItemType Junction -Path $extractDir -Target $systemDir | Out-Null
        Write-Host "LLVM $version linked from system install at $systemDir to $extractDir"
        return
      }
    }
  }

  # Download from GitHub releases.
  New-Item -ItemType Directory -Force -Path $llvmVersionRoot | Out-Null
  $baseUrl = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$version"
  $tarUrl = "$baseUrl/$asset"

  $tempTar = Join-Path $env:TEMP $asset
  Download-File -Url $tarUrl -OutFile $tempTar

  try {
    Ensure-CleanDirectory -Path $llvmVersionRoot
    $tarExe = Get-WindowsTarExe
    & $tarExe -xJf $tempTar -C $llvmVersionRoot | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to extract LLVM archive '$tempTar'."
    }
  } finally {
    Remove-Item -LiteralPath $tempTar -Force -ErrorAction SilentlyContinue
  }

  # The extracted directory might have a different name; find it.
  if (-not (Test-Path -LiteralPath $extractDir -PathType Container)) {
    $candidates = Get-ChildItem -LiteralPath $llvmVersionRoot -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like "LLVM*" -or $_.Name -like "llvm*" }
    if ($candidates.Count -eq 1 -and $candidates[0].Name -ne (Split-Path -Leaf $extractDir)) {
      Rename-Item -LiteralPath $candidates[0].FullName -NewName (Split-Path -Leaf $extractDir)
    }
  }

  if (-not (Test-Path -LiteralPath $clangExe -PathType Leaf)) {
    # Try bin/clang.exe in any subdirectory.
    $fallback = Get-ChildItem -LiteralPath $llvmVersionRoot -Recurse -Filter "clang.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $fallback) {
      Write-Warning "clang.exe found at '$($fallback.FullName)' instead of expected '$clangExe'."
    } else {
      throw "LLVM extraction did not produce '$clangExe'."
    }
  }

  Write-Host "Installed LLVM $version to $extractDir"
}
