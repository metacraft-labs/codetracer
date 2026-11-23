Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-MsvcLinkerPath {
  <#
    .SYNOPSIS
      Decide whether a resolved `link.exe` is MSVC's, and say how it was decided.

    .DESCRIPTION
      Returns a hashtable @{ isMsvc = <bool>; reason = <string> }.

      TWO independent tests, because the interesting case is the one where the
      first is unavailable:

        1. `MsvcPathAdditions` lists the directories vcvarsall contributed
           (published by `export-msvc-env.ps1:181-183`). A `link.exe` resolved
           from one of them is MSVC's.
        2. Failing that, MSVC's `link.exe` sits in the same directory as
           `cl.exe`. GNU coreutils' `link.exe` -- which MSYS2 and Git-Bash both
           ship, and which takes exactly two operands -- does not, and neither
           ships the other. This test needs nothing from export-msvc-env.ps1.

      (2) is load-bearing rather than a nicety. `export-msvc-env.ps1` `exit 0`s
      SILENTLY when vswhere or the VC tools are missing, so on a machine
      without Build Tools it publishes no MSVC_PATH_ADDITIONS at all -- which
      is the state the observed CI failures were actually in. Relying on (1)
      alone would give up on precisely the runs this check exists to diagnose.

      It is a path/filesystem test rather than a `--version` probe on purpose:
      MSVC's link.exe rejects `--version` with a non-zero exit, and under
      `$ErrorActionPreference = 'Stop'` on pwsh 7.4+ a non-zero native exit is
      itself terminating, so probing would trade one opaque failure for
      another.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$LinkExePath,
    [AllowNull()][AllowEmptyString()][string]$MsvcPathAdditions
  )

  $linkDir = (Split-Path -Parent $LinkExePath).TrimEnd('\').TrimEnd('/')

  if (-not [string]::IsNullOrWhiteSpace($MsvcPathAdditions)) {
    $msvcDirs = @($MsvcPathAdditions -split ";" |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.Trim().TrimEnd('\').TrimEnd('/') })
    if ($msvcDirs -contains $linkDir) {
      return @{ isMsvc = $true; reason = "it is in an MSVC_PATH_ADDITIONS directory" }
    }
  }

  if (Test-Path -LiteralPath (Join-Path $linkDir "cl.exe") -PathType Leaf) {
    return @{ isMsvc = $true; reason = "cl.exe sits beside it in '$linkDir'" }
  }

  return @{
    isMsvc = $false
    reason = "it is in neither an MSVC_PATH_ADDITIONS directory nor a directory containing cl.exe"
  }
}

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

  # nargo_cli links codetracer_trace_writer_nim, whose build.rs compiles the
  # Nim trace writer from `.codetracer-deps/codetracer-trace-format-nim` (noir's
  # .cargo/config.toml names it). A cargo git checkout has no such siblings, and
  # noir's own scripts/fetch-trace-format-nim.sh provisions them at its pinned
  # revisions. Without it the build stopped at "Nim FFI entry point not found"
  # (run 44900586259, origin-DAP Windows, noir f09f4597). It is a bash script,
  # run with Git for Windows' bash: the bash on PATH can be the WSL launcher.
  $fetchScript = Join-Path $sourceDir "scripts/fetch-trace-format-nim.sh"
  if (Test-Path -LiteralPath $fetchScript -PathType Leaf) {
    $gitBash = Join-Path (Split-Path -Parent (Split-Path -Parent $gitCommand.Source)) "bin/bash.exe"
    if (-not (Test-Path -LiteralPath $gitBash -PathType Leaf)) {
      $gitBash = Get-BashExe
    }
    # Without the WindowsApps directory on PATH: its `python3` is the
    # Microsoft Store alias, which `command -v` finds and which exits 49 when
    # run, and the script's optional pin cross-check then ended it under
    # `set -e` before it wrote .codetracer-deps/nim.cfg (measured on
    # win-ci-bare-001). With no python3 the script skips that check.
    $savedPath = $env:PATH
    $env:PATH = (($env:PATH -split ';') | Where-Object { $_ -and ($_ -notmatch '\\WindowsApps\\?$') }) -join ';'
    Push-Location -LiteralPath $sourceDir
    try {
      & $gitBash "scripts/fetch-trace-format-nim.sh"
      if ($LASTEXITCODE -ne 0) {
        throw "noir's scripts/fetch-trace-format-nim.sh failed (exit $LASTEXITCODE) with '$gitBash'; nargo_cli's trace writer needs its .codetracer-deps/."
      }
    } finally {
      Pop-Location
      $env:PATH = $savedPath
    }
    foreach ($needed in @(".codetracer-deps/codetracer-trace-format-nim/src/codetracer_trace_writer_ffi.nim", ".codetracer-deps/nim.cfg")) {
      if (-not (Test-Path -LiteralPath (Join-Path $sourceDir $needed) -PathType Leaf)) {
        throw "noir's scripts/fetch-trace-format-nim.sh exited 0 but left no '$needed' under '$sourceDir'."
      }
    }

    # The trace writer's build script runs `nim` from PATH ("failed to run
    # `nim` -- the Nim compiler must be on PATH", run 44940608244). env.ps1
    # puts Nim on PATH only after every bootstrap step, so resolve the
    # directory the NIM step (which runs before this one) installed, the way
    # env.ps1 does, and put its bin first for the cargo build below.
    $nimVersionRoot = Join-Path $Root ("nim\" + $Toolchain["NIM_VERSION"])
    $nimDir = Resolve-InstallDirFromRelativePathFile -InstallRoot $Root -RelativePathFile (Join-Path $nimVersionRoot "nim.install.relative-path")
    if ([string]::IsNullOrWhiteSpace($nimDir)) {
      foreach ($candidate in @((Join-Path $nimVersionRoot ("prebuilt\nim-" + $Toolchain["NIM_VERSION"])), (Join-Path $nimVersionRoot ("nim-" + $Toolchain["NIM_VERSION"])))) {
        if (Test-Path -LiteralPath $candidate -PathType Container) { $nimDir = $candidate; break }
      }
    }
    $nimExe = if ($nimDir) { Join-Path $nimDir "bin/nim.exe" } else { "" }
    if (-not $nimExe -or -not (Test-Path -LiteralPath $nimExe -PathType Leaf)) {
      throw "nargo's trace writer needs nim.exe, and the NIM bootstrap step left none under '$nimVersionRoot'."
    }
    $env:PATH = "$(Split-Path -Parent $nimExe);$env:PATH"
    Write-Host "nargo bootstrap: the trace writer compiles with $nimExe"
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
  # PATH ORDER MATTERS HERE, and this block exists because getting it wrong is
  # one of the two ways the observed failure can arise.
  #
  # `nargo_cli` is an MSVC-target Rust build: rustc drives `link.exe` and
  # expects MSVC's linker. MSYS2 (like Git-Bash) also ships a `link.exe` --
  # GNU coreutils' `link(1)`, which makes a hard link and accepts exactly two
  # operands. When that one wins the PATH lookup, rustc's link line is read as
  # a coreutils invocation and every crate with a build script dies with
  #
  #     error: linking with `link.exe` failed: exit code: 1
  #       = note: link: extra operand '...build_script_build...rcgu.o'
  #               Try 'link --help' for more information.
  #
  # That message is what CI has actually been failing with here, and it aborts
  # at the `throw` below -- i.e. cargo failed -- NOT at the "did not produce a
  # nargo executable" throw further down. The class is recorded at
  # `codetracer-specs/Planned-Work/Windows-Test-Suite-Health.md:416-424`
  # ("the same `cargo test --lib` passes from PowerShell").
  #
  # NOTE what the message does and does not tell you. It proves a coreutils
  # `link` answered; it does NOT prove MSVC's linker was present and lost the
  # lookup, because `export-msvc-env.ps1` exits silently when Build Tools are
  # missing and so leaves no trace either way. Treat "shadowed" as one of two
  # live possibilities, not as the diagnosis.
  #
  # It is a DIFFERENT message from the one `ensure-just.ps1:37-39` and
  # `ensure-nextest.ps1:36-38` describe -- "linker `link.exe` NOT FOUND",
  # meaning no link.exe was found at all. Both occur on this bootstrap, in
  # different runs, and their signatures are mutually exclusive: a log shows
  # "extra operand" or "not found", never both.
  #
  # `export-msvc-env.ps1:149-158` deliberately emits its PATH with the MSVC
  # additions FIRST, "they must win over any older toolset already on PATH",
  # and publishes those additions separately as `MSVC_PATH_ADDITIONS`
  # (`:181-183`) "so a caller that would rather PREPEND than replace can do so
  # without re-deriving the delta". Prepending MSYS2's `mingw64/bin` -- which
  # this build genuinely needs for clang -- undoes that ordering, so the MSVC
  # additions are put back in front afterwards. clang is still resolved from
  # MSYS2 because the MSVC additions do not contain one.
  $env:Path = "$msysMingwBinDir;$($env:Path)"
  $msvcPathAdditions = [Environment]::GetEnvironmentVariable("MSVC_PATH_ADDITIONS")
  if (-not [string]::IsNullOrWhiteSpace($msvcPathAdditions)) {
    $env:Path = "$msvcPathAdditions;$($env:Path)"
  }

  # Belt and braces: pin the linker by absolute path so the build no longer
  # depends on PATH order at all. Cargo reads
  # `CARGO_TARGET_<TRIPLE>_LINKER` for the target triple and, for build
  # scripts and proc macros, the HOST triple -- which is the same
  # `x86_64-pc-windows-msvc` here, and build scripts are exactly where the
  # failure above surfaced (`proc-macro2`, `quote`).
  $resolvedLink = Get-Command link.exe -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($null -eq $resolvedLink) {
    throw "nargo bootstrap needs MSVC's link.exe on PATH but none was found. " +
          "export-msvc-env.ps1 should have supplied it; check that Visual Studio " +
          "Build Tools with the C++ workload are installed."
  }
  # Fail loudly and EARLY with a diagnosis, rather than ~10 min into a cargo
  # build with an opaque `link: extra operand` note. The check is a path
  # comparison rather than a `--version` probe on purpose: MSVC's link.exe
  # rejects `--version` with a non-zero exit, and under
  # `$ErrorActionPreference = 'Stop'` on pwsh 7.4+ a non-zero native exit is
  # itself terminating, so probing would trade one opaque failure for another.
  #
  # What the logs establish is that a GNU coreutils `link` answered rustc's
  # `link.exe` invocation. Whether it SHADOWED a present MSVC linker or
  # SUBSTITUTED for an absent one is NOT determinable from them, because
  # export-msvc-env.ps1 exits silently when MSVC is missing and so leaves no
  # trace of which case obtained. Both readings are handled: the PATH
  # reordering above restores MSVC-first order when MSVC is there, and
  # Test-MsvcLinkerPath fails fast below, naming the culprit, when it is not.
  $verdict = Test-MsvcLinkerPath -LinkExePath $resolvedLink.Source `
                                 -MsvcPathAdditions $msvcPathAdditions
  if (-not $verdict.isMsvc) {
    $additionsForMessage = if ([string]::IsNullOrWhiteSpace($msvcPathAdditions)) {
      "<empty -- export-msvc-env.ps1 published none, which is what it does when Build Tools are absent>"
    } else {
      $msvcPathAdditions
    }
    throw "The first 'link.exe' on PATH is '$($resolvedLink.Source)', and " +
          "$($verdict.reason), so it is not MSVC's linker " +
          "(MSVC_PATH_ADDITIONS=$additionsForMessage). MSYS2 and Git-Bash both ship " +
          "GNU coreutils' link(1) under that name, and an MSVC-target cargo build " +
          "fails with 'link: extra operand' when it wins the lookup. Either Visual " +
          "Studio Build Tools with the C++ workload are not installed on this " +
          "machine, or they are installed but lost the PATH lookup. " +
          "See Windows-Test-Suite-Health.md:416-424."
  }

  $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER = $resolvedLink.Source
  Write-Host "nargo bootstrap will link with $($resolvedLink.Source) ($($verdict.reason))"

  # BUILD FROM A SHORT PATH. The trace writer's build script has Nim compile
  # C through MSVC, and Nim hands cl.exe sources relative to a nimcache deep
  # in cargo's OUT_DIR, e.g. ..\..\..\..\..\..\nargo\cache\source\<rev>\noir\
  # .codetracer-deps\...\crossing_state.c. cl.exe is not long-path aware, so
  # once that cwd plus the relative path pass 260 characters, it fails with
  # "C1083: Cannot open source file". That happened in windows-nargo run
  # 44954823072 under C:\Users\runner\AppData\Local\codetracer\windows-diy.
  # `subst` maps a free drive letter to the source's parent for the build, so
  # both paths start at X:\noir. It needs no administrator rights and is
  # removed afterwards.
  $buildDir = $sourceDir
  $substDrive = $null
  $freeLetter = [char[]](90..68) | Where-Object { -not (Test-Path -LiteralPath "$($_):\") } | Select-Object -First 1
  if ($freeLetter) {
    & subst.exe "$($freeLetter):" $cacheRoot
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath "$($freeLetter):\noir")) {
      $substDrive = "$($freeLetter):"
      $buildDir = "$substDrive\noir"
      Write-Host "nargo bootstrap builds from $buildDir (subst of $cacheRoot), to keep cl.exe's paths under MAX_PATH"
    }
  }
  if (-not $substDrive) {
    Write-Host "::warning::nargo bootstrap could not map a short drive with subst; building from '$sourceDir', where cl.exe may hit MAX_PATH"
  }
  # The trace writer's build script puts its nimcache under the temp
  # directory (%TEMP%\ctnw\...), and Nim hands lib.exe its objects relative
  # to cargo's OUT_DIR. With the build on the subst drive and %TEMP% on C:,
  # that relative path crosses drives, which no relative path can, and the
  # link fails with "LNK1181: cannot open input file
  # '..\..\..\..\..\..\..\..\Temp\ctnw\...obj'" (windows-nargo run
  # 45134129306, a cold build). So the build's temp directory moves onto the
  # subst drive too, for the build only.
  $savedTemp = $env:TEMP
  $savedTmp = $env:TMP
  $buildTemp = $null
  if ($substDrive) {
    $buildTemp = "$substDrive\.nargo-build-tmp"
    New-Item -ItemType Directory -Force -Path $buildTemp | Out-Null
    $env:TEMP = $buildTemp
    $env:TMP = $buildTemp
  }
  Push-Location $buildDir
  try {
    & $rustupExe toolchain install nightly --profile minimal
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to install nightly toolchain required for nargo bootstrap."
    }
    & $cargoExe +nightly build --release -p nargo_cli --bin nargo
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to build nargo from '$buildDir'."
    }
  } finally {
    Pop-Location
    $env:TEMP = $savedTemp
    $env:TMP = $savedTmp
    if ($buildTemp) {
      Remove-Item -LiteralPath $buildTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($substDrive) {
      & subst.exe $substDrive /D | Out-Null
    }
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
