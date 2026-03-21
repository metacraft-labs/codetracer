Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-TupVersionLine {
  param([Parameter(Mandatory = $true)][string]$TupExe)

  $versionOutput = & $TupExe --version 2>&1
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    $renderedOutput = (($versionOutput | ForEach-Object { [string]$_ }) -join " | ").Trim()
    if ([string]::IsNullOrWhiteSpace($renderedOutput)) {
      $renderedOutput = "<no output>"
    }
    throw "Failed to run '$TupExe --version' (exit code: $exitCode). Output: $renderedOutput"
  }
  $firstLine = ($versionOutput | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($firstLine)) {
    throw "Unable to detect Tup version from '$TupExe'."
  }
  return ([string]$firstLine).Trim()
}

function Ensure-TupPrebuilt {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $prebuiltUrl = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_PREBUILT_URL")
  $prebuiltSha = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_PREBUILT_SHA256")
  if ([string]::IsNullOrWhiteSpace($prebuiltUrl)) {
    $prebuiltUrl = $Toolchain["TUP_PREBUILT_URL"]
  } else {
    $prebuiltUrl = $prebuiltUrl.Trim()
  }
  if ([string]::IsNullOrWhiteSpace($prebuiltSha)) {
    $prebuiltSha = $Toolchain["TUP_PREBUILT_SHA256"]
  } else {
    $prebuiltSha = $prebuiltSha.Trim()
  }
  if ([string]::IsNullOrWhiteSpace($prebuiltUrl) -or [string]::IsNullOrWhiteSpace($prebuiltSha)) {
    throw "Tup prebuilt mode requires TUP_WINDOWS_PREBUILT_URL and TUP_WINDOWS_PREBUILT_SHA256 (or matching toolchain defaults)."
  }

  $normalizedSha = $prebuiltSha.Trim().ToLowerInvariant()
  if ($normalizedSha -notmatch '^[A-Fa-f0-9]{64}$') {
    throw "TUP_WINDOWS_PREBUILT_SHA256 must be a 64-character hexadecimal SHA256."
  }

  $tupRoot = Join-Path $Root "tup"
  $prebuiltRoot = Join-Path $tupRoot "prebuilt/$normalizedSha"
  $installDir = Join-Path $prebuiltRoot "install"
  $tupExe = Join-Path $installDir "tup.exe"
  $metaFile = Join-Path $prebuiltRoot "tup.prebuilt.meta"
  $requestedVersion = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_PREBUILT_VERSION")
  if ([string]::IsNullOrWhiteSpace($requestedVersion)) {
    $requestedVersion = $Toolchain["TUP_PREBUILT_VERSION"]
  } else {
    $requestedVersion = $requestedVersion.Trim()
  }

  $expectedMetadata = @{
    tup_mode = "prebuilt"
    tup_prebuilt_url = $prebuiltUrl
    tup_prebuilt_sha256 = $normalizedSha
    tup_prebuilt_version = $requestedVersion
  }

  if ((Test-Path -LiteralPath $tupExe -PathType Leaf) -and (Test-Path -LiteralPath $metaFile -PathType Leaf)) {
    $installedMetadata = Read-KeyValueFile -Path $metaFile
    if (Test-KeyValueFileMatches -Expected $expectedMetadata -Actual $installedMetadata) {
      try {
        $null = Get-TupVersionLine -TupExe $tupExe
        Write-Host "Tup prebuilt cache hit at $installDir"
        return @{
          mode = "prebuilt"
          installDir = $installDir
          metadata = $expectedMetadata
        }
      } catch {
        Write-Warning "Cached Tup prebuilt install is invalid and will be reinstalled: $($_.Exception.Message)"
      }
    }
  }

  $uri = [System.Uri]$prebuiltUrl.Trim()
  $assetName = [System.IO.Path]::GetFileName($uri.LocalPath)
  if ([string]::IsNullOrWhiteSpace($assetName)) {
    throw "Could not derive Tup prebuilt asset name from URL '$prebuiltUrl'."
  }

  $tempAsset = Join-Path $env:TEMP "codetracer-tup-prebuilt-$normalizedSha-$assetName"
  Download-File -Url $prebuiltUrl -OutFile $tempAsset
  try {
    Assert-FileSha256 -Path $tempAsset -Expected $normalizedSha
    Ensure-CleanDirectory -Path $prebuiltRoot
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null

    $assetLower = $assetName.ToLowerInvariant()
    if ($assetLower.EndsWith(".zip")) {
      $expandedRoot = Join-Path $prebuiltRoot "expanded"
      Expand-Archive -Path $tempAsset -DestinationPath $expandedRoot -Force
      $candidate = Get-ChildItem -Path $expandedRoot -Filter "tup.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($null -eq $candidate) {
        throw "Tup prebuilt ZIP did not contain tup.exe."
      }
      $candidateRoot = Split-Path -Parent $candidate.FullName
      foreach ($entry in (Get-ChildItem -LiteralPath $candidateRoot -File)) {
        Copy-Item -LiteralPath $entry.FullName -Destination (Join-Path $installDir $entry.Name) -Force
      }
      Copy-Item -LiteralPath $candidate.FullName -Destination $tupExe -Force
    } elseif ($assetLower.EndsWith(".exe")) {
      Copy-Item -LiteralPath $tempAsset -Destination $tupExe -Force
    } else {
      throw "Unsupported Tup prebuilt asset '$assetName'. Only .zip and .exe are supported."
    }

    $null = Get-TupVersionLine -TupExe $tupExe
    Write-KeyValueFile -Path $metaFile -Values $expectedMetadata
  } finally {
    Remove-Item -LiteralPath $tempAsset -Force -ErrorAction SilentlyContinue
  }

  Write-Host "Installed Tup from prebuilt asset to $installDir"
  return @{
    mode = "prebuilt"
    installDir = $installDir
    metadata = $expectedMetadata
  }
}

function New-TupWindowsBootstrapScript {
  param([Parameter(Mandatory = $true)][string]$SourceDir)

  $scriptPath = Join-Path $SourceDir "codetracer-bootstrap-windows.sh"
  $scriptContent = @'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"

: "${CC:=x86_64-w64-mingw32-gcc}"
: "${AR:=x86_64-w64-mingw32-ar}"

COMMON_CFLAGS=(
  -Os
  -W
  -Wall
  -fno-common
  -D_FILE_OFFSET_BITS=64
  -I"$ROOT_DIR/src"
  -I"$BUILD_DIR"
  -include signal.h
  -include "$ROOT_DIR/src/compat/win32/mingw.h"
  -I"$ROOT_DIR/src/compat/win32"
  -D_GNU_SOURCE
  "-DS_ISLNK(a)=0"
  "-D__reserved="
  -DAT_REMOVEDIR=0x200
  -DUNICODE
  -D_UNICODE
)

LUA_CFLAGS=(
  -DLUA_COMPAT_ALL
  -DLUA_USE_MKSTEMP
  -w
)

WRAP_LDFLAGS=(
  -Wl,--wrap=open
  -Wl,--wrap=close
  -Wl,--wrap=tmpfile
  -Wl,--wrap=dup
  -Wl,--wrap=__mingw_vprintf
  -Wl,--wrap=__mingw_vfprintf
)

compile_object() {
  local src="$1"
  shift || true
  local rel="${src#$ROOT_DIR/}"
  local obj_name="${rel//\//_}"
  local obj_path="$BUILD_DIR/${obj_name%.c}.o"
  "$CC" "${COMMON_CFLAGS[@]}" "$@" -c "$src" -o "$obj_path"
}

mkdir -p "$BUILD_DIR"
rm -f "$BUILD_DIR"/*.o "$BUILD_DIR"/*.a "$BUILD_DIR"/lua "$BUILD_DIR"/tup.exe "$BUILD_DIR"/tup-dllinject.dll "$BUILD_DIR"/builtin.lua
rm -rf "$BUILD_DIR"/luabuiltin
mkdir -p "$BUILD_DIR/luabuiltin"

lua_objects=()
while IFS= read -r -d '' src; do
  compile_object "$src" "${LUA_CFLAGS[@]}"
  rel="${src#$ROOT_DIR/}"
  obj_name="${rel//\//_}"
  obj_path="$BUILD_DIR/${obj_name%.c}.o"
  lua_objects+=("$obj_path")
done < <(find "$ROOT_DIR/src/lua" -maxdepth 1 -type f -name '*.c' -print0 | sort -z)

lua_link_objects=()
tup_lua_objects=()
for obj in "${lua_objects[@]}"; do
  base="$(basename "$obj")"
  if [[ "$base" != "src_lua_lua.o" && "$base" != "src_lua_luac.o" ]]; then
    tup_lua_objects+=("$obj")
  fi
  if [[ "$base" != "src_lua_luac.o" ]]; then
    lua_link_objects+=("$obj")
  fi
done

"$CC" "${lua_link_objects[@]}" -o "$BUILD_DIR/lua" -lm
cp "$ROOT_DIR/src/luabuiltin/builtin.lua" "$BUILD_DIR/builtin.lua"
(
  cd "$BUILD_DIR"
  ./lua "$ROOT_DIR/src/luabuiltin/xxd.lua" builtin.lua luabuiltin/luabuiltin.h
)

dllinject_objects=()
while IFS= read -r -d '' src; do
  compile_object "$src" -Wno-missing-prototypes -DNDEBUG
  rel="${src#$ROOT_DIR/}"
  obj_name="${rel//\//_}"
  obj_path="$BUILD_DIR/${obj_name%.c}.o"
  dllinject_objects+=("$obj_path")
done < <(find "$ROOT_DIR/src/dllinject" -maxdepth 1 -type f -name '*.c' -print0 | sort -z)

"$CC" -shared -static-libgcc "${dllinject_objects[@]}" -lpsapi -o "$BUILD_DIR/tup-dllinject.dll"

tup_objects=()
add_tree_objects() {
  local dir="$1"
  local extra_args=("${@:2}")
  while IFS= read -r -d '' src; do
    compile_object "$src" "${extra_args[@]}"
    rel="${src#$ROOT_DIR/}"
    obj_name="${rel//\//_}"
    obj_path="$BUILD_DIR/${obj_name%.c}.o"
    tup_objects+=("$obj_path")
  done < <(find "$dir" -maxdepth 1 -type f -name '*.c' -print0 | sort -z)
}

add_tree_objects "$ROOT_DIR/src/tup"
compile_object "$ROOT_DIR/src/tup/monitor/null.c"
tup_objects+=("$BUILD_DIR/src_tup_monitor_null.o")
compile_object "$ROOT_DIR/src/tup/flock/lock_file.c"
tup_objects+=("$BUILD_DIR/src_tup_flock_lock_file.o")
compile_object "$ROOT_DIR/src/tup/server/windepfile.c"
tup_objects+=("$BUILD_DIR/src_tup_server_windepfile.o")
compile_object "$ROOT_DIR/src/tup/tup/main.c"
tup_objects+=("$BUILD_DIR/src_tup_tup_main.o")
add_tree_objects "$ROOT_DIR/src/inih" -Wno-cast-qual -DINI_ALLOW_MULTILINE=0
add_tree_objects "$ROOT_DIR/src/sqlite3" -w -DSQLITE_TEMP_STORE=2 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION

for compat_src in \
  "$ROOT_DIR/src/compat/dir_mutex.c" \
  "$ROOT_DIR/src/compat/fstatat.c" \
  "$ROOT_DIR/src/compat/mkdirat.c" \
  "$ROOT_DIR/src/compat/openat.c" \
  "$ROOT_DIR/src/compat/renameat.c" \
  "$ROOT_DIR/src/compat/unlinkat.c"; do
  compile_object "$compat_src"
  rel="${compat_src#$ROOT_DIR/}"
  obj_name="${rel//\//_}"
  tup_objects+=("$BUILD_DIR/${obj_name%.c}.o")
done

add_tree_objects "$ROOT_DIR/src/compat/win32"

version="$(git -C "$ROOT_DIR" describe --always --dirty 2>/dev/null || echo codetracer-bootstrap)"
printf 'const char *tup_version(void) {return "%s";}\n' "$version" | "$CC" -x c -c - -o "$BUILD_DIR/tup-version.o"

"$CC" -static-libgcc \
  "${tup_lua_objects[@]}" \
  "${tup_objects[@]}" \
  "$BUILD_DIR/tup-dllinject.dll" \
  "$BUILD_DIR/tup-version.o" \
  "${WRAP_LDFLAGS[@]}" \
  -o "$BUILD_DIR/tup.exe" \
  -lm \
  -lpthread

self_host_update_raw="${TUP_WINDOWS_SELF_HOST_UPDATE:-0}"
self_host_update="$(echo "$self_host_update_raw" | tr '[:upper:]' '[:lower:]')"
if [[ "$self_host_update" == "1" || "$self_host_update" == "true" || "$self_host_update" == "yes" || "$self_host_update" == "on" ]]; then
  if [[ ! -d "$ROOT_DIR/.tup" ]]; then
    "$BUILD_DIR/tup.exe" init
  fi
  "$BUILD_DIR/tup.exe" upd
else
  echo "Skipping Tup self-host init/upd during bootstrap (set TUP_WINDOWS_SELF_HOST_UPDATE=1 to enable for debugging)."
fi
'@

  Set-Content -LiteralPath $scriptPath -Value $scriptContent -Encoding ASCII
  return $scriptPath
}

function Apply-TupWindowsSourcePatches {
  param([Parameter(Mandatory = $true)][string]$SourceDir)

  $fstatatPath = Join-Path $SourceDir "src/compat/fstatat.c"
  if (-not (Test-Path -LiteralPath $fstatatPath -PathType Leaf)) {
    throw "Expected Tup source file '$fstatatPath' for Windows compatibility patching."
  }

  $originalContent = Get-Content -LiteralPath $fstatatPath -Raw -Encoding UTF8
  $stat64Pattern = [regex]'_stat64\(pathname,\s*buf\)'
  $matchCount = $stat64Pattern.Matches($originalContent).Count
  if ($matchCount -eq 0) {
    Write-Host "Tup transient patch: no _stat64(pathname, buf) callsites found in src/compat/fstatat.c; assuming upstream already carries a compatible Windows fix."
  } else {
    $patchedContent = $stat64Pattern.Replace($originalContent, 'stat(pathname, buf)')
    if ([string]::Equals($originalContent, $patchedContent, [System.StringComparison]::Ordinal)) {
      throw "Failed to apply transient Windows patch for Tup src/compat/fstatat.c."
    }

    Set-Content -LiteralPath $fstatatPath -Value $patchedContent -Encoding UTF8
    Write-Host "Applied transient Tup Windows source patch in src/compat/fstatat.c: replaced $matchCount _stat64(pathname, buf) callsite(s) with stat(pathname, buf)."
  }

  $lstatPath = Join-Path $SourceDir "src/compat/win32/lstat.c"
  if (-not (Test-Path -LiteralPath $lstatPath -PathType Leaf)) {
    throw "Expected Tup source file '$lstatPath' for Windows compatibility patching."
  }

  $originalLstatContent = Get-Content -LiteralPath $lstatPath -Raw -Encoding UTF8
  $wstat64Pattern = [regex]'_wstat64\(wpathname,\s*buf\)'
  $wstatPattern = [regex]'_wstat\(wpathname,\s*buf\)'
  $wstat64MatchCount = $wstat64Pattern.Matches($originalLstatContent).Count
  $wstatMatchCount = $wstatPattern.Matches($originalLstatContent).Count
  $totalLstatMatchCount = $wstat64MatchCount + $wstatMatchCount
  if ($totalLstatMatchCount -eq 0) {
    Write-Host "Tup transient patch: no _wstat64(wpathname, buf) or _wstat(wpathname, buf) callsites found in src/compat/win32/lstat.c; assuming upstream already carries a compatible Windows fix."
  } else {
    $patchedLstatContent = $wstat64Pattern.Replace($originalLstatContent, 'stat(pathname, buf)')
    $patchedLstatContent = $wstatPattern.Replace($patchedLstatContent, 'stat(pathname, buf)')
    if ([string]::Equals($originalLstatContent, $patchedLstatContent, [System.StringComparison]::Ordinal)) {
      throw "Failed to apply transient Windows patch for Tup src/compat/win32/lstat.c."
    }

    Set-Content -LiteralPath $lstatPath -Value $patchedLstatContent -Encoding UTF8
    Write-Host "Applied transient Tup Windows source patch in src/compat/win32/lstat.c: replaced $wstat64MatchCount _wstat64(wpathname, buf) and $wstatMatchCount _wstat(wpathname, buf) callsite(s) with stat(pathname, buf)."
  }

  $win32TupPath = Join-Path $SourceDir "win32.tup"
  if (-not (Test-Path -LiteralPath $win32TupPath -PathType Leaf)) {
    $win32TupContent = @'
# Transient bootstrap compatibility stub for Windows source mode.
# This is synthesized only in codetracer's temporary Tup source checkout.
# Intentionally empty: Tuprules.tup includes win32.tup for platform overrides.
'@
    Set-Content -LiteralPath $win32TupPath -Value $win32TupContent -Encoding ASCII
    Write-Host "Applied transient Tup Windows source patch: created minimal win32.tup include stub."
  } else {
    Write-Host "Tup transient patch: win32.tup already exists; leaving source file unchanged."
  }

  $serverTupfilePath = Join-Path $SourceDir "src/tup/server/Tupfile"
  if (-not (Test-Path -LiteralPath $serverTupfilePath -PathType Leaf)) {
    throw "Expected Tup source file '$serverTupfilePath' for Windows compatibility patching."
  }

  $originalServerTupfile = Get-Content -LiteralPath $serverTupfilePath -Raw -Encoding UTF8
  $serverFuseRulePattern = [regex]'(?m)^: foreach fuse_server\.c fuse_fs\.c master_fork\.c \|> !cc \|>\s*\r?\n?'
  $serverFuseRuleMatches = $serverFuseRulePattern.Matches($originalServerTupfile).Count
  if ($serverFuseRuleMatches -eq 0) {
    Write-Host "Tup transient patch: no fused server !cc rule found in src/tup/server/Tupfile; assuming upstream already carries a compatible Windows fix."
  } else {
    $patchedServerTupfile = $serverFuseRulePattern.Replace($originalServerTupfile, '')
    if ([string]::Equals($originalServerTupfile, $patchedServerTupfile, [System.StringComparison]::Ordinal)) {
      throw "Failed to apply transient Windows patch for Tup src/tup/server/Tupfile."
    }

    Set-Content -LiteralPath $serverTupfilePath -Value $patchedServerTupfile -Encoding UTF8
    Write-Host "Applied transient Tup Windows source patch in src/tup/server/Tupfile: removed $serverFuseRuleMatches fused server !cc rule(s) (fuse_server.c/fuse_fs.c/master_fork.c) while keeping windepfile.c on !mingwcc."
  }

  $flockTupfilePath = Join-Path $SourceDir "src/tup/flock/Tupfile"
  if (-not (Test-Path -LiteralPath $flockTupfilePath -PathType Leaf)) {
    throw "Expected Tup source file '$flockTupfilePath' for Windows compatibility patching."
  }

  $originalFlockTupfile = Get-Content -LiteralPath $flockTupfilePath -Raw -Encoding UTF8
  $flockFcntlRulePattern = [regex]'(?m)^: foreach fcntl\.c \|> !cc \|>\s*\r?\n?'
  $flockFcntlRuleMatches = $flockFcntlRulePattern.Matches($originalFlockTupfile).Count
  if ($flockFcntlRuleMatches -eq 0) {
    Write-Host "Tup transient patch: no fcntl !cc rule found in src/tup/flock/Tupfile; assuming upstream already carries a compatible Windows fix."
  } else {
    $patchedFlockTupfile = $flockFcntlRulePattern.Replace($originalFlockTupfile, '')
    if ([string]::Equals($originalFlockTupfile, $patchedFlockTupfile, [System.StringComparison]::Ordinal)) {
      throw "Failed to apply transient Windows patch for Tup src/tup/flock/Tupfile."
    }

    Set-Content -LiteralPath $flockTupfilePath -Value $patchedFlockTupfile -Encoding UTF8
    Write-Host "Applied transient Tup Windows source patch in src/tup/flock/Tupfile: removed $flockFcntlRuleMatches fcntl !cc rule(s) while keeping lock_file.c !mingwcc."
  }

  $rootTupfilePath = Join-Path $SourceDir "Tupfile"
  if (-not (Test-Path -LiteralPath $rootTupfilePath -PathType Leaf)) {
    throw "Expected Tup source file '$rootTupfilePath' for Windows compatibility patching."
  }

  $originalRootTupfile = Get-Content -LiteralPath $rootTupfilePath -Raw -Encoding UTF8
  $rootFcntlClientObjPattern = [regex]'(?m)^client_objs \+= src/tup/flock/fcntl\.o\s*\r?\n?'
  $rootFcntlClientObjMatches = $rootFcntlClientObjPattern.Matches($originalRootTupfile).Count
  if ($rootFcntlClientObjMatches -eq 0) {
    Write-Host "Tup transient patch: no src/tup/flock/fcntl.o client_objs entry found in root Tupfile; assuming upstream already carries a compatible Windows fix."
  } else {
    $patchedRootTupfile = $rootFcntlClientObjPattern.Replace($originalRootTupfile, '')
    if ([string]::Equals($originalRootTupfile, $patchedRootTupfile, [System.StringComparison]::Ordinal)) {
      throw "Failed to apply transient Windows patch for Tup root Tupfile client_objs."
    }

    Set-Content -LiteralPath $rootTupfilePath -Value $patchedRootTupfile -Encoding UTF8
    Write-Host "Applied transient Tup Windows source patch in Tupfile: removed $rootFcntlClientObjMatches src/tup/flock/fcntl.o client_objs entry(ies)."
  }
}

function Ensure-TupFromSource {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $tupRepo = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_SOURCE_REPO")
  if ([string]::IsNullOrWhiteSpace($tupRepo)) {
    $tupRepo = $Toolchain["TUP_SOURCE_REPO"]
  } else {
    $tupRepo = $tupRepo.Trim()
  }
  $tupRef = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_SOURCE_REF")
  if ([string]::IsNullOrWhiteSpace($tupRef)) {
    $tupRef = $Toolchain["TUP_SOURCE_REF"]
  } else {
    $tupRef = $tupRef.Trim()
  }
  $tupRevisionOverride = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_SOURCE_REVISION")
  $buildCommand = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_SOURCE_BUILD_COMMAND")
  if ([string]::IsNullOrWhiteSpace($buildCommand)) {
    $buildCommand = $Toolchain["TUP_SOURCE_BUILD_COMMAND"]
  } else {
    $buildCommand = $buildCommand.Trim()
  }
  $useCodetracerBootstrapScript = [string]::Equals($buildCommand, $Toolchain["TUP_SOURCE_BUILD_COMMAND"], [System.StringComparison]::Ordinal)
  $effectiveBuildCommandIdentity = if ($useCodetracerBootstrapScript) {
    "codetracer-bootstrap-windows.sh@v14"
  } else {
    "custom:$buildCommand"
  }

  $buildCommandBashEscaped = $buildCommand.Replace("'", "'\''")
  $tupRevision = if ([string]::IsNullOrWhiteSpace($tupRevisionOverride)) {
    Resolve-GitRefToRevision -Repository $tupRepo -RefName $tupRef
  } else {
    $tupRevisionOverride.Trim().ToLowerInvariant()
  }

  $gitCommand = Get-Command git -ErrorAction SilentlyContinue
  if ($null -eq $gitCommand -or [string]::IsNullOrWhiteSpace($gitCommand.Source)) {
    throw "git is required for Tup source bootstrap but was not found on PATH."
  }
  $msys2 = Ensure-TupMsys2BuildPrereqs -Root $Root -Toolchain $Toolchain
  $msysBashExe = [string]$msys2.bashExe
  $msysBinDir = Join-Path ([string]$msys2.root) "usr/bin"
  $msysMingwBinDir = Join-Path ([string]$msys2.root) "mingw64/bin"
  $msysMingw32BinDir = Join-Path ([string]$msys2.root) "mingw32/bin"
  $msysBinDirForBash = ConvertTo-BashPath -WindowsPath $msysBinDir
  $msysMingwBinDirForBash = ConvertTo-BashPath -WindowsPath $msysMingwBinDir
  $msysMingw32BinDirForBash = ConvertTo-BashPath -WindowsPath $msysMingw32BinDir

  $tupRoot = Join-Path $Root "tup"
  $sourceCacheRoot = Join-Path $tupRoot "cache/source"
  $cacheInputMetadata = @{
    tup_mode = "source"
    tup_source_repo = $tupRepo
    tup_source_ref = $tupRef
    tup_source_revision = $tupRevision
    tup_source_build_command = $buildCommand
    tup_source_effective_build_command = $effectiveBuildCommandIdentity
    tup_msys2_version = [string]$msys2.metadata.tup_msys2_version
    tup_msys2_packages = [string]$msys2.metadata.tup_msys2_packages
  }
  $cacheInputString = (($cacheInputMetadata.Keys | Sort-Object | ForEach-Object { "$_=$($cacheInputMetadata[$_])" }) -join "`n")
  $cacheKey = Get-Sha256HexForString -Value $cacheInputString
  $cacheRoot = Join-Path $sourceCacheRoot $cacheKey
  $installDir = Join-Path $cacheRoot "install"
  $tupExe = Join-Path $installDir "tup.exe"
  $sourceMetaFile = Join-Path $cacheRoot "tup.source.meta"

  if ((Test-Path -LiteralPath $tupExe -PathType Leaf) -and (Test-Path -LiteralPath $sourceMetaFile -PathType Leaf)) {
    $installedMetadata = Read-KeyValueFile -Path $sourceMetaFile
    if (Test-KeyValueFileMatches -Expected $cacheInputMetadata -Actual $installedMetadata) {
      $null = Get-TupVersionLine -TupExe $tupExe
      Write-Host "Tup source cache hit at $installDir"
      return @{
        mode = "source"
        installDir = $installDir
        metadata = $cacheInputMetadata
      }
    }
  }

  $stagingRoot = Join-Path $env:TEMP "codetracer-tup-source-$cacheKey"
  Ensure-CleanDirectory -Path $stagingRoot
  $sourceDir = Join-Path $stagingRoot "tup-src"
  try {
    Write-Host "Building Tup from source (cache key: $cacheKey)"
    & $gitCommand.Source clone $tupRepo $sourceDir
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to clone Tup repository '$tupRepo'."
    }
    & $gitCommand.Source -C $sourceDir checkout --detach $tupRevision
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to checkout Tup revision '$tupRevision'."
    }
    Apply-TupWindowsSourcePatches -SourceDir $sourceDir

    $sourceDirForBash = ConvertTo-BashPath -WindowsPath $sourceDir
    if ($useCodetracerBootstrapScript) {
      $generatedScriptPath = New-TupWindowsBootstrapScript -SourceDir $sourceDir
      $generatedScriptPathForBash = ConvertTo-BashPath -WindowsPath $generatedScriptPath
      $bootstrapScript = "set -euo pipefail; export PATH='${msysMingwBinDirForBash}:${msysMingw32BinDirForBash}:${msysBinDirForBash}:`$PATH'; export TUP_MINGW=1; export TUP_MINGW32=0; cd '$sourceDirForBash'; chmod +x '$generatedScriptPathForBash'; '$generatedScriptPathForBash'"
    } else {
      $bootstrapScript = "set -euo pipefail; export PATH='${msysMingwBinDirForBash}:${msysMingw32BinDirForBash}:${msysBinDirForBash}:`$PATH'; export TUP_MINGW=1; export TUP_MINGW32=0; cd '$sourceDirForBash'; $buildCommandBashEscaped"
    }
    & $msysBashExe -lc $bootstrapScript
    if ($LASTEXITCODE -ne 0) {
      throw "Tup source bootstrap command failed: $effectiveBuildCommandIdentity (requested: $buildCommand, MSYS2 shell '$msysBashExe')."
    }

    $candidatePaths = @(
      (Join-Path $sourceDir "tup.exe"),
      (Join-Path $sourceDir "tup"),
      (Join-Path $sourceDir "build/tup.exe"),
      (Join-Path $sourceDir "build/tup")
    )
    $builtTupPath = $candidatePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($builtTupPath)) {
      throw "Tup source bootstrap did not produce a tup executable in expected locations."
    }

    Ensure-CleanDirectory -Path $cacheRoot
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Copy-Item -LiteralPath $builtTupPath -Destination $tupExe -Force
    $builtTupDir = Split-Path -Path $builtTupPath -Parent
    $runtimeArtifacts = @("tup-dllinject.dll")
    foreach ($artifact in $runtimeArtifacts) {
      $artifactPath = Join-Path $builtTupDir $artifact
      if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
        Copy-Item -LiteralPath $artifactPath -Destination (Join-Path $installDir $artifact) -Force
      }
    }
    $null = Get-TupVersionLine -TupExe $tupExe
    Write-KeyValueFile -Path $sourceMetaFile -Values $cacheInputMetadata
  } finally {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Host "Installed Tup from source to $installDir"
  return @{
    mode = "source"
    installDir = $installDir
    metadata = $cacheInputMetadata
  }
}

function Ensure-Tup {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $requestedModeRaw = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_SOURCE_MODE")
  $requestedMode = if ([string]::IsNullOrWhiteSpace($requestedModeRaw)) { "prebuilt" } else { $requestedModeRaw.Trim().ToLowerInvariant() }
  $tupRoot = Join-Path $Root "tup"
  $installPathFile = Join-Path $tupRoot "tup.install.relative-path"
  $installMetaFile = Join-Path $tupRoot "tup.install.meta"

  $result = $null
  switch ($requestedMode) {
    "source" {
      $result = Ensure-TupFromSource -Root $Root -Toolchain $Toolchain
    }
    "prebuilt" {
      $result = Ensure-TupPrebuilt -Root $Root -Toolchain $Toolchain
    }
    "auto" {
      try {
        $result = Ensure-TupPrebuilt -Root $Root -Toolchain $Toolchain
      } catch {
        Write-Warning "Tup prebuilt bootstrap failed in auto mode. Falling back to source bootstrap. Error: $($_.Exception.Message)"
        $result = Ensure-TupFromSource -Root $Root -Toolchain $Toolchain
      }
    }
    default {
      throw "Unsupported TUP_WINDOWS_SOURCE_MODE '$requestedMode'. Supported values: auto, source, prebuilt."
    }
  }

  if ($result -is [array]) {
    $hashResult = $result | Where-Object { $_ -is [hashtable] -or $_ -is [System.Collections.IDictionary] } | Select-Object -Last 1
    if ($null -ne $hashResult) {
      $result = $hashResult
    }
  }
  if ($result -is [System.Collections.IDictionary] -and -not ($result -is [hashtable])) {
    $normalizedResult = @{}
    foreach ($entry in $result.GetEnumerator()) {
      $normalizedResult[[string]$entry.Key] = $entry.Value
    }
    $result = $normalizedResult
  }
  if ($null -eq $result -or -not $result.ContainsKey("installDir")) {
    throw "Tup bootstrap did not return an install directory."
  }

  $installDir = [string]$result.installDir
  $relativeInstallDir = ConvertTo-InstallRelativePath -AbsolutePath $installDir -Root $Root
  $selectedMetadata = @{
    requested_mode = $requestedMode
    effective_mode = [string]$result.mode
    install_relative_path = $relativeInstallDir
  }
  foreach ($key in $result.metadata.Keys) {
    $selectedMetadata[$key] = [string]$result.metadata[$key]
  }

  New-Item -ItemType Directory -Force -Path $tupRoot | Out-Null
  Set-Content -LiteralPath $installPathFile -Value $relativeInstallDir -Encoding ASCII
  Write-KeyValueFile -Path $installMetaFile -Values $selectedMetadata
}
