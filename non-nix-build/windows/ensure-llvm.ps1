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
  # name never existed - only the `LLVM-<ver>-win64.exe` installer uses
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
        # RELOCATABILITY: this arm used to JUNCTION `$extractDir` at the
        # system LLVM. The optimisation it buys is real -- a matching system
        # install saves a multi-hundred-megabyte download -- but a junction
        # bakes `C:\Program Files\LLVM` into the tree, and a tree that only
        # resolves on a machine that happens to have that exact install is
        # the definition of an entry that must not be published.
        #
        # It is a COPY now, so the arm keeps the saved download and produces
        # a self-contained tree. Note why the branch was converted at all:
        # provisioning runs on hosts with no system LLVM record zero reparse
        # points for this component, because this branch is never taken there.
        # That is a HOST-DEPENDENT observation and not a clearance -- a host
        # that does have a matching system LLVM would produce a different
        # result from the same code -- so the branch is converted rather than
        # left alone on the strength of a zero.
        $parentDir = Split-Path -Parent $llvmVersionRoot
        New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
        Ensure-CleanDirectory -Path $llvmVersionRoot
        Write-Host "Copying system LLVM $version from '$systemDir' into the install root; a junction there would not survive relocation."
        Copy-Item -LiteralPath $systemDir -Destination $extractDir -Recurse -Force
        $relative = Write-InstallPointer -Root $Root -Component "llvm" `
          -VersionRoot $llvmVersionRoot -InstallDir $extractDir -Metadata @{
            llvm_version = $version
            llvm_target = $llvmTarget
            install_arm = "system-copy"
            system_source = $systemDir
          }
        Write-Host "Installed LLVM $version (system-copy) at $extractDir (install-relative: $relative)"
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

  $installDir = $extractDir
  if (-not (Test-Path -LiteralPath $clangExe -PathType Leaf)) {
    # Try bin/clang.exe in any subdirectory.
    $fallback = Get-ChildItem -LiteralPath $llvmVersionRoot -Recurse -Filter "clang.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $fallback) {
      Write-Warning "clang.exe found at '$($fallback.FullName)' instead of expected '$clangExe'."
      # The pointer must name where clang ACTUALLY is, not where it was
      # expected to be: a pointer file that records the expectation rather
      # than the observation is worse than no pointer at all, because it
      # looks authoritative.
      $installDir = Split-Path -Parent (Split-Path -Parent $fallback.FullName)
    } else {
      throw "LLVM extraction did not produce '$clangExe'."
    }
  }

  $relative = Write-InstallPointer -Root $Root -Component "llvm" `
    -VersionRoot $llvmVersionRoot -InstallDir $installDir -Metadata @{
      llvm_version = $version
      llvm_target = $llvmTarget
      install_arm = "download"
    }

  Write-Host "Installed LLVM $version (download) to $installDir (install-relative: $relative)"
}
