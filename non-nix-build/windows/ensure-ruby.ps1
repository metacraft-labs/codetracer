Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Ruby, for the Ruby recorder's tests (the origin-DAP Ruby suite records with
# codetracer-ruby-recorder, whose native extension the test harness builds
# from the sibling checkout with `just build-extension`).
#
# Two pieces, both pinned by SHA-256 in toolchain-versions.env:
#
#   * The RubyInstaller2 archive for RUBY_VERSION (rubyinstaller-<release>-x64.7z,
#     the same Ruby the Nix path uses). RubyInstaller is a MinGW-UCRT build
#     (`x64-mingw-ucrt`), so the extension builds for Rust's
#     x86_64-pc-windows-gnu target and links with the pinned WinLibs UCRT gcc
#     (Ensure-Gcc), the same C runtime this Ruby was built against. The archive
#     is relocatable and needs no installer. Its digest is the GitHub release
#     asset's own (`gh api .../releases/tags/RubyInstaller-<release>`, the
#     asset's `digest`).
#
#     Not MSYS2's mingw-w64-x86_64-ruby, which the Ruby recorder's own env.ps1
#     installs: that one is installed with `pacman -Syu`, so its version follows
#     the rolling repository (it was Ruby 4.0.9 on 2026-11-12, against a
#     declared 3.4), and nothing pins it.
#
#   * libclang, which rb-sys runs through bindgen to generate the Ruby C API
#     bindings. It is extracted from the official LLVM release archive for
#     LLVM_VERSION, the archive Ensure-Llvm installs whole: only
#     bin/libclang.dll and its resource headers (lib/clang/<major>/include,
#     which bindgen needs for stddef.h, mm_malloc.h and the rest), about 100 MB
#     of a 939 MB archive. libclang finds the MinGW headers through the gcc on
#     PATH. LLVM publishes no SHA-256 for the archive; LLVM_WIN_X64_SHA256 was
#     taken from a download whose detached signature (the release's .sig)
#     verified under Hans Wennborg's LLVM release key, fingerprint
#     B6C8F98282B944E3B0D5C2530FC3042E345AD05D.
function ConvertTo-RubyInstallerArch {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "x64" }
    default { throw "Ruby is pinned for x64 only (RUBYINSTALLER_WIN_X64_SHA256); no pin for '$Arch'." }
  }
}

function Get-RubyInstallLayout {
  # The paths Ensure-Ruby installs to, and env.ps1 reads back.
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $release = $Toolchain["RUBYINSTALLER_RELEASE"]
  $llvmVersion = $Toolchain["LLVM_VERSION"]
  $rubyRoot = Join-Path $Root "ruby"
  $rubyDir = Join-Path (Join-Path $rubyRoot $release) "rubyinstaller-$release-x64"
  $libclangDir = Join-Path $rubyRoot "libclang-$llvmVersion"
  return [pscustomobject]@{
    RubyDir = $rubyDir
    RubyBinDir = Join-Path $rubyDir "bin"
    LibclangDir = $libclangDir
    LibclangBinDir = Join-Path $libclangDir "bin"
  }
}

function Ensure-Ruby {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["RUBY_VERSION"]
  $release = $Toolchain["RUBYINSTALLER_RELEASE"]
  $expectedRubySha = $Toolchain["RUBYINSTALLER_WIN_X64_SHA256"]
  $llvmVersion = $Toolchain["LLVM_VERSION"]
  $expectedLlvmSha = $Toolchain["LLVM_WIN_X64_SHA256"]
  foreach ($pin in @(
      @{ Name = "RUBYINSTALLER_WIN_X64_SHA256"; Value = $expectedRubySha },
      @{ Name = "LLVM_WIN_X64_SHA256"; Value = $expectedLlvmSha })) {
    if ([string]::IsNullOrWhiteSpace($pin.Value) -or $pin.Value -notmatch '^[A-Fa-f0-9]{64}$') {
      throw "Missing or invalid $($pin.Name) in toolchain-versions.env."
    }
  }
  if (-not $release.StartsWith("$version-")) {
    throw "RUBYINSTALLER_RELEASE '$release' is not a RubyInstaller release of RUBY_VERSION '$version'."
  }

  $rubyArch = ConvertTo-RubyInstallerArch -Arch $Arch
  $layout = Get-RubyInstallLayout -Root $Root -Toolchain $Toolchain
  $rubyVersionRoot = Split-Path -Parent $layout.RubyDir
  $rubyExe = Join-Path $layout.RubyBinDir "ruby.exe"

  # --- Ruby ------------------------------------------------------------------
  $haveRuby = $false
  if (Test-Path -LiteralPath $rubyExe -PathType Leaf) {
    $installed = ""
    try { $installed = (& $rubyExe -e "print RUBY_VERSION" 2>$null) } catch {}
    if ($installed -eq $version) {
      Write-Host "Ruby $version already installed at $($layout.RubyDir)"
      $haveRuby = $true
    }
  }

  if (-not $haveRuby) {
    $asset = "rubyinstaller-$release-$rubyArch.7z"
    $downloadUrl = "https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-$release/$asset"
    $tempArchive = Join-Path $env:TEMP "codetracer-$asset"
    Write-Host "Downloading Ruby $version (RubyInstaller $release) from $downloadUrl ..."
    Download-File -Url $downloadUrl -OutFile $tempArchive
    try {
      Assert-FileSha256 -Path $tempArchive -Expected $expectedRubySha
      New-Item -ItemType Directory -Force -Path $rubyVersionRoot | Out-Null
      Ensure-CleanDirectory -Path $rubyVersionRoot
      $sevenZipExe = Get-SevenZipExe -Root $Root -Toolchain $Toolchain
      & $sevenZipExe x $tempArchive "-o$rubyVersionRoot" -y | Out-Host
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract the Ruby archive '$tempArchive'."
      }
    } finally {
      Remove-Item -LiteralPath $tempArchive -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $rubyExe -PathType Leaf)) {
      throw "Ruby extraction did not produce '$rubyExe'."
    }
    $installed = (& $rubyExe -e "print RUBY_VERSION")
    if ($installed -ne $version) {
      throw "The pinned RubyInstaller archive reports Ruby '$installed', not RUBY_VERSION '$version'."
    }
    Write-Host "Installed Ruby $version to $($layout.RubyDir)"
  }

  # --- libclang ----------------------------------------------------------------
  # The marker names the archive the files came from, so a changed pin
  # replaces them rather than being taken as satisfied by an older extraction.
  $llvmMajor = ($llvmVersion -split '\.')[0]
  $libclangDll = Join-Path $layout.LibclangBinDir "libclang.dll"
  $resourceHeader = Join-Path $layout.LibclangDir "lib/clang/$llvmMajor/include/stddef.h"
  $marker = Join-Path $layout.LibclangDir "libclang.source-sha256"
  if ((Test-Path -LiteralPath $libclangDll -PathType Leaf) -and
      (Test-Path -LiteralPath $resourceHeader -PathType Leaf) -and
      (Test-Path -LiteralPath $marker -PathType Leaf) -and
      ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $expectedLlvmSha.ToLowerInvariant())) {
    Write-Host "libclang $llvmVersion already installed at $($layout.LibclangDir)"
    return
  }

  $stem = "clang+llvm-$llvmVersion-x86_64-pc-windows-msvc"
  $asset = "$stem.tar.xz"
  $downloadUrl = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$llvmVersion/$asset"
  $tempArchive = Join-Path $env:TEMP "codetracer-$asset"
  $scratch = Join-Path (Join-Path $Root "ruby") ("libclang-extract-" + [Guid]::NewGuid().ToString('N'))
  Write-Host "Downloading LLVM $llvmVersion for libclang from $downloadUrl ..."
  Download-File -Url $downloadUrl -OutFile $tempArchive
  try {
    Assert-FileSha256 -Path $tempArchive -Expected $expectedLlvmSha
    Ensure-CleanDirectory -Path $scratch
    $tarExe = Get-WindowsTarExe
    & $tarExe -xJf $tempArchive -C $scratch "$stem/bin/libclang.dll" "$stem/lib/clang/$llvmMajor/include" | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to extract libclang from '$tempArchive'."
    }
    $extracted = Join-Path $scratch $stem
    if (-not (Test-Path -LiteralPath (Join-Path $extracted "bin/libclang.dll") -PathType Leaf)) {
      throw "LLVM archive '$asset' did not contain $stem/bin/libclang.dll."
    }
    if (Test-Path -LiteralPath $layout.LibclangDir) {
      Remove-Item -LiteralPath $layout.LibclangDir -Recurse -Force
    }
    Move-Item -LiteralPath $extracted -Destination $layout.LibclangDir
    Set-Content -LiteralPath $marker -Value $expectedLlvmSha.ToLowerInvariant() -Encoding ASCII
  } finally {
    Remove-Item -LiteralPath $tempArchive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  }

  if (-not (Test-Path -LiteralPath $resourceHeader -PathType Leaf)) {
    throw "libclang extraction did not produce '$resourceHeader'."
  }
  Write-Host "Installed libclang $llvmVersion to $($layout.LibclangDir)"
}
