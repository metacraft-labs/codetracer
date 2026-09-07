Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Gcc {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  # RELOCATABILITY: this component used to publish itself as an NTFS JUNCTION
  # at `<root>\gcc\<version>` pointing at the real tree, and it took that
  # junction UNCONDITIONALLY -- including on the download-and-verify path,
  # where the target was already inside the install root.
  #
  # That is the shape that does not survive being materialised somewhere else,
  # and it is easy to misjudge because the target LOOKED internal. A junction
  # stores an ABSOLUTE path, so `<root>\gcc\15.2.0 -> <root>\gcc\winlibs-15.2.0\mingw64`
  # still names the ORIGINAL root once the tree is archived and unpacked at a
  # new one: the link resolves to a directory that is not there, or worse, to
  # the publisher's directory on a machine where that path happens to exist.
  # Under publish-and-refill that is not an inconvenience, it is a cache entry
  # that misresolves silently for every job that later pulls it.
  #
  # The conversion is to stop creating the link at all. `<root>\gcc\<version>`
  # is now an ordinary directory holding the pointer file, and the tree lives
  # where it was extracted; `env.ps1` rehydrates the install directory from
  # `gcc.install.relative-path` against whatever root it finds itself at,
  # exactly as it already does for nim, capnp, tup and nargo.
  $version = $Toolchain["GCC_VERSION"]
  $gccVersionRoot = Join-Path $Root "gcc/$version"
  $pointerFile = Join-Path $gccVersionRoot "gcc.install.relative-path"

  # The fast path resolves through the pointer rather than through a fixed
  # `<root>\gcc\<version>\bin` path, because after the conversion that fixed
  # path is not where the compiler is.
  $existingDir = Resolve-InstallDirFromRelativePathFile -InstallRoot $Root -RelativePathFile $pointerFile
  if (-not [string]::IsNullOrWhiteSpace($existingDir)) {
    $existingGcc = Join-Path $existingDir "bin/gcc.exe"
    if (Test-Path -LiteralPath $existingGcc -PathType Leaf) {
      $currentVersion = ""
      try {
        $versionOutput = & $existingGcc --version 2>&1 | Select-Object -First 1
        if ($versionOutput -match '([0-9]+\.[0-9]+\.[0-9]+)') {
          $currentVersion = $Matches[1]
        }
      } catch {}

      if ($currentVersion -eq $version) {
        Write-Host "gcc $version already installed at $existingDir"
        return
      }
    }
  }

  # Locate the WinLibs installation from winget.
  $winlibsPackageDir = ""
  $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
  if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
    $wingetRoot = Join-Path $localAppData "Microsoft\WinGet\Packages"
    if (Test-Path -LiteralPath $wingetRoot -PathType Container) {
      $candidate = Get-ChildItem -LiteralPath $wingetRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "BrechtSanders.WinLibs.POSIX.UCRT*" } |
        Select-Object -First 1
      if ($null -ne $candidate) {
        $mingw64 = Join-Path $candidate.FullName "mingw64"
        if (Test-Path -LiteralPath $mingw64 -PathType Container) {
          $winlibsPackageDir = $mingw64
        }
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($winlibsPackageDir)) {
    # Winget-free fallback: fetch the pinned WinLibs UCRT build directly from its
    # GitHub release, verify its SHA256, and extract it into the DIY cache. This
    # is the path CI / self-hosted runners take, where winget is not installed
    # (env.ps1 provisions Node/uv/TTD the same download-and-verify way). winget
    # below stays as a last resort for interactive dev boxes that pin neither.
    $winlibsUrl = $Toolchain["WINLIBS_GCC_URL"]
    $winlibsSha = $Toolchain["WINLIBS_GCC_SHA256"]
    if (-not [string]::IsNullOrWhiteSpace($winlibsUrl) -and
        -not [string]::IsNullOrWhiteSpace($winlibsSha)) {
      $normalizedSha = $winlibsSha.Trim().ToLowerInvariant()
      if ($normalizedSha -notmatch '^[0-9a-f]{64}$') {
        throw "WINLIBS_GCC_SHA256 must be a 64-character hexadecimal SHA256."
      }
      # The archive's top-level directory is `mingw64/`, so it extracts to
      # $stageRoot/mingw64, which IS the install directory -- there is no
      # junction any more, and the pointer file below names this path
      # relative to the install root.
      $stageRoot = Join-Path $Root "gcc/winlibs-$version"
      $stagedMingw64 = Join-Path $stageRoot "mingw64"
      $stagedGcc = Join-Path $stagedMingw64 "bin/gcc.exe"
      if (-not (Test-Path -LiteralPath $stagedGcc -PathType Leaf)) {
        Write-Host "Downloading WinLibs (GCC $version) from $winlibsUrl ..."
        $tempZip = Join-Path $env:TEMP "codetracer-winlibs-$normalizedSha.zip"
        Download-File -Url $winlibsUrl -OutFile $tempZip
        try {
          Assert-FileSha256 -Path $tempZip -Expected $normalizedSha
          Ensure-CleanDirectory -Path $stageRoot
          # bsdtar (System32 tar.exe) unpacks the .zip faster than Expand-Archive
          # and without its MAX_PATH limits on WinLibs' deep mingw64 tree — the
          # same extractor ensure-llvm / ensure-zlib use. Top-level dir: mingw64/.
          $tarExe = Get-WindowsTarExe
          & $tarExe -xf $tempZip -C $stageRoot
          if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract WinLibs archive '$tempZip' with '$tarExe' (exit $LASTEXITCODE)."
          }
        }
        finally {
          Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        }
      }
      if (Test-Path -LiteralPath $stagedGcc -PathType Leaf) {
        $winlibsPackageDir = $stagedMingw64
        Write-Host "Installed WinLibs (GCC $version) at $stagedMingw64"
      }
      else {
        throw "WinLibs archive extracted to '$stageRoot' but gcc.exe not found at '$stagedGcc'."
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($winlibsPackageDir)) {
    # Try installing via winget.
    $wingetCommand = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -eq $wingetCommand) {
      throw "WinLibs GCC is not installed and winget is not available. Install WinLibs manually or via: winget install BrechtSanders.WinLibs.POSIX.UCRT"
    }

    Write-Host "Installing WinLibs (GCC $version) via winget..."
    & winget install BrechtSanders.WinLibs.POSIX.UCRT --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to install WinLibs via winget."
    }

    $candidate = Get-ChildItem -LiteralPath (Join-Path $localAppData "Microsoft\WinGet\Packages") -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like "BrechtSanders.WinLibs.POSIX.UCRT*" } |
      Select-Object -First 1
    if ($null -ne $candidate) {
      $mingw64 = Join-Path $candidate.FullName "mingw64"
      if (Test-Path -LiteralPath $mingw64 -PathType Container) {
        $winlibsPackageDir = $mingw64
      }
    }

    if ([string]::IsNullOrWhiteSpace($winlibsPackageDir)) {
      throw "WinLibs winget install completed but could not locate the mingw64 directory."
    }
  }

  # Bring the tree INSIDE the install root if it is not already there, then
  # record where it is with a root-relative pointer. No junction is created on
  # either arm.
  #
  # The download-and-verify arm -- the one CI takes -- already extracted into
  # `<root>\gcc\winlibs-<version>\mingw64`, so it costs nothing: the pointer
  # simply names the directory that is already there.
  #
  # The winget arm resolves to a tree under `%LOCALAPPDATA%\Microsoft\WinGet\Packages`,
  # which is outside the install root and cannot be pointed at relatively. It
  # is COPIED in rather than junctioned to. That is not free -- a WinLibs
  # mingw64 tree is on the order of a gigabyte -- and it is still the right
  # trade: a junction to a per-user winget directory produces a tree that
  # works only on the machine and user account that installed it, which is
  # exactly the entry that must never reach a shared cache. The arm is a
  # last-resort path for interactive developer boxes; CI never takes it.
  $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $normalizedPackageDir = [System.IO.Path]::GetFullPath($winlibsPackageDir)
  $rootPrefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar

  $installArm = "download-in-place"
  if (-not $normalizedPackageDir.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    $installArm = "winget-copy"
    $importedRoot = Join-Path $Root "gcc/winlibs-$version"
    $importedMingw64 = Join-Path $importedRoot "mingw64"
    Write-Host "Copying WinLibs (GCC $version) from '$winlibsPackageDir' into the install root; a junction there would not survive relocation."
    Ensure-CleanDirectory -Path $importedRoot
    Copy-Item -LiteralPath $winlibsPackageDir -Destination $importedMingw64 -Recurse -Force
    $winlibsPackageDir = $importedMingw64
  }

  $gccExeCheck = Join-Path $winlibsPackageDir "bin/gcc.exe"
  if (-not (Test-Path -LiteralPath $gccExeCheck -PathType Leaf)) {
    throw "WinLibs install directory '$winlibsPackageDir' does not contain gcc.exe at '$gccExeCheck'."
  }

  $relative = Write-InstallPointer -Root $Root -Component "gcc" `
    -VersionRoot $gccVersionRoot -InstallDir $winlibsPackageDir -Metadata @{
      gcc_version = $version
      install_arm = $installArm
      distribution = "winlibs-ucrt"
    }

  Write-Host "Installed GCC $version (WinLibs, $installArm) at $winlibsPackageDir (install-relative: $relative)"
}
