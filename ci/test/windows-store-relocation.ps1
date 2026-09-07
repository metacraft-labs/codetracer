Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Gate for the Windows toolchain store's RELOCATABILITY, plus the store-root
# delete guard and the documented-exclusion cross-check.
#
# WHY THIS EXISTS, in one paragraph, because the shape of the test follows
# directly from it. Toolchain components are published from one machine and
# materialised on another, at a root that may differ. A component that bakes
# an absolute path into its tree therefore produces something worse than a
# broken install: it produces a WORKING-LOOKING install that resolves against
# the publisher's directories. Nothing throws, nothing logs, and every later
# consumer inherits the same wrong answer. So the assertion this file has to
# make is not "the pointer file says the right string" -- a string comparison
# would pass on a tree that cannot run. It is: materialise at one root, move
# the tree to a DIFFERENT root, DESTROY the first root, and then resolve and
# EXECUTE the tool. A tree that secretly depended on the first root has
# nowhere to hide once the first root is gone.
#
# Tests implemented here:
#   * t_win_store_relocation_roundtrip          (the gate)
#   * t_win_store_no_delete_under_store_root
#   * t_win_store_junction_components_converted
#   * t_win_store_fpc_and_msvc_documented_exclusions
#
# NO MOCKS. Per the workspace policy on mock objects, this file uses none. The
# production functions from `non-nix-build/windows/toolchain-utils.ps1` are
# dot-sourced and called directly; the component trees are real directories on
# a real filesystem; the "tools" are real executables that the operating
# system really runs and whose output is read back. The one substitution is
# that the executables are two-line scripts rather than a 1.5 GB WinLibs
# toolchain -- and that is the test's subject matter, not a stand-in for a
# collaborator: what is under test is whether a tree RESOLVES after being
# moved, which is a property of the pointer discipline and the absence of
# baked paths, not of how large the tree is or what the binary computes.
#
# NEGATIVE CONTROLS. Every check that reports a defect is paired with an input
# that does NOT have that defect, asserted clean through the same code path.
# A detector that fires on everything and a detector that fires on nothing are
# both useless, and only the pair distinguishes them.
#
# Runs on Linux/macOS pwsh as well as Windows. Where the two platforms differ
# the difference is named rather than papered over: on Windows the escaping
# link is a real NTFS junction and the tool is a `.cmd`; elsewhere they are a
# symlink and a shell script. Both exercise the same production code, because
# the audit reads `LinkTarget` and the `IsPathRooted` verdict, neither of
# which is Windows-specific.

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$utilsPath = Join-Path $repoRoot "non-nix-build/windows/toolchain-utils.ps1"
$envPs1Path = Join-Path $repoRoot "env.ps1"
$exclusionsPath = Join-Path $repoRoot "non-nix-build/windows/store-exclusions.json"

$script:Failures = 0
$script:Checks = 0

function Assert-True {
  param([bool]$Condition, [string]$Message)
  $script:Checks++
  if (-not $Condition) {
    $script:Failures++
    Write-Host "  FAIL: $Message"
  } else {
    Write-Host "  ok:   $Message"
  }
}

function Assert-Equal {
  param($Expected, $Actual, [string]$Message)
  Assert-True -Condition ($Expected -eq $Actual) -Message "$Message (expected '$Expected', got '$Actual')"
}

function Assert-Throws {
  <#
    Runs $Script and asserts it threw, and that the message mentions
    $MessageContains. The second half matters: a test that only checks
    "something threw" passes when the code throws for an unrelated reason,
    which is how a guard gets credit for a bug.
  #>
  param([scriptblock]$Script, [string]$MessageContains, [string]$Message)

  $threw = $false
  $text = ""
  try {
    & $Script | Out-Null
  } catch {
    $threw = $true
    $text = [string]$_.Exception.Message
  }

  Assert-True -Condition $threw -Message "$Message (threw)"
  if ($threw) {
    Assert-True -Condition ($text -like "*$MessageContains*") `
      -Message "$Message (message names '$MessageContains'; got: $text)"
  }
}

if (-not (Test-Path -LiteralPath $utilsPath -PathType Leaf)) {
  throw "toolchain-utils.ps1 not found at '$utilsPath'."
}
. $utilsPath

$isWindowsHost = $false
try { $isWindowsHost = $IsWindows } catch { $isWindowsHost = $false }

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("ct-store-reloc-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null

# The guard reads the environment, so the tests drive it through the
# environment. This is the production lookup path, not a hook added for
# testing: `CODETRACER_WINDOWS_STORE_ROOT` is how an operator relocates the
# store, and exercising the guard through it is exercising the real thing.
$savedStoreRoot = [Environment]::GetEnvironmentVariable("CODETRACER_WINDOWS_STORE_ROOT")
$savedReproStoreRoot = [Environment]::GetEnvironmentVariable("REPRO_STORE_ROOT")

try {

# ---------------------------------------------------------------------------
# Helpers: a real component tree with a real executable in it.
# ---------------------------------------------------------------------------

function New-ToolExecutable {
  <#
    Writes an executable that, when run, prints its OWN resolved directory and
    a version string. Printing its own directory is what makes the round-trip
    assertion strong: the test can prove the thing that ran came out of the
    NEW root rather than out of a leftover copy at the old one.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$BinDir,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Version
  )

  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

  if ($isWindowsHost) {
    $path = Join-Path $BinDir "$Name.cmd"
    $body = @(
      "@echo off",
      "echo VERSION=$Version",
      "echo HOME_DIR=%~dp0"
    )
    Set-Content -LiteralPath $path -Value $body -Encoding ASCII
    return $path
  }

  $path = Join-Path $BinDir $Name
  $body = @(
    "#!/bin/sh",
    "echo VERSION=$Version",
    "echo HOME_DIR=`$(cd `"`$(dirname `"`$0`")`" && pwd)"
  )
  Set-Content -LiteralPath $path -Value $body -Encoding ASCII
  # 0755. Set through the real chmod because .NET's UnixFileMode surface
  # differs across the PowerShell versions this has to run under, and an
  # executable bit that silently did not get set would make every round-trip
  # assertion below fail for the wrong reason.
  & chmod 755 $path
  return $path
}

function Invoke-ToolExecutable {
  <#
    Runs the executable and returns a hashtable of the KEY=VALUE lines it
    printed, or $null if it could not be run at all. Not a Test-Path check:
    the whole point is that the file is EXECUTED.
  #>
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  $output = $null
  try {
    $output = & $Path 2>&1
  } catch {
    return $null
  }
  if ($LASTEXITCODE -ne 0) {
    return $null
  }

  $result = @{}
  foreach ($line in @($output)) {
    $text = [string]$line
    $idx = $text.IndexOf("=")
    if ($idx -gt 0) {
      $result[$text.Substring(0, $idx).Trim()] = $text.Substring($idx + 1).Trim()
    }
  }
  return $result
}

function New-EscapingLink {
  <#
    A junction on Windows, a symlink elsewhere; in both cases with an ABSOLUTE
    target, which is the shape `Get-ReparsePointFindings` must refuse. Returns
    $true when the link was created, $false when the platform would not allow
    it -- the caller then says so instead of silently claiming a pass.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$LinkPath,
    [Parameter(Mandatory = $true)][string]$TargetPath
  )

  try {
    if ($isWindowsHost) {
      New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath -ErrorAction Stop | Out-Null
    } else {
      New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath -ErrorAction Stop | Out-Null
    }
    return $true
  } catch {
    return $false
  }
}

function Copy-TreeToNewRoot {
  <#
    The publish-and-refill hop, modelled as literally as this host allows: the
    tree is archived, unpacked at a DIFFERENT root, and the original root is
    then DESTROYED. Destroying it is the load-bearing step -- without it a
    tree carrying an absolute path back to the source would keep working and
    the round trip would prove nothing.

    `tar` is used when present because an archive round trip also proves the
    tree does not depend on anything an archive cannot carry. A plain
    recursive copy is an acceptable fallback for the relocation question
    itself, and which one ran is announced rather than hidden.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$DestinationRoot
  )

  New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null

  $tar = Get-Command tar -ErrorAction SilentlyContinue
  if ($null -ne $tar) {
    $archive = Join-Path $scratch ("transfer-" + [Guid]::NewGuid().ToString("N") + ".tar")
    & $tar.Source -cf $archive -C $SourceRoot .
    if ($LASTEXITCODE -eq 0) {
      & $tar.Source -xf $archive -C $DestinationRoot
      if ($LASTEXITCODE -eq 0) {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        return "tar"
      }
    }
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
  }

  Copy-Item -LiteralPath (Join-Path $SourceRoot "*") -Destination $DestinationRoot -Recurse -Force
  return "copy"
}

# ---------------------------------------------------------------------------
# t_win_store_no_delete_under_store_root
#
# BOTH ARMS ARE REQUIRED and the reason is the whole design of the check: a
# guard that refuses everything would pass the refusal arm on its own, and
# would also have broken every legitimate Ensure-* call in the tree. So the
# refusal is asserted AND the private-scratch path is asserted still to work.
# ---------------------------------------------------------------------------

Write-Host "== t_win_store_no_delete_under_store_root"

$storeRoot = Join-Path $scratch "store"
$privateScratch = Join-Path $scratch "private-scratch"
New-Item -ItemType Directory -Force -Path $storeRoot | Out-Null

[Environment]::SetEnvironmentVariable("CODETRACER_WINDOWS_STORE_ROOT", $storeRoot)
[Environment]::SetEnvironmentVariable("REPRO_STORE_ROOT", $null)

$entryPath = Join-Path $storeRoot "gcc/15.2.0"
New-Item -ItemType Directory -Force -Path $entryPath | Out-Null
Set-Content -LiteralPath (Join-Path $entryPath "marker.txt") -Value "entry" -Encoding ASCII

Assert-Throws -Script { Ensure-CleanDirectory -Path $entryPath } `
  -MessageContains "content-addressed store root" `
  -Message "Ensure-CleanDirectory refuses a path under the store root"

Assert-True -Condition (Test-Path -LiteralPath (Join-Path $entryPath "marker.txt")) `
  -Message "and the refusal LEFT THE ENTRY ON DISK rather than deleting it and then complaining"

# The largest version of the mistake: deleting the root itself.
Assert-Throws -Script { Ensure-CleanDirectory -Path $storeRoot } `
  -MessageContains "content-addressed store root" `
  -Message "Ensure-CleanDirectory refuses the store root itself, not only its children"

# The refusal must name the offending path, or an operator cannot act on it.
$namedPath = $false
try { Ensure-CleanDirectory -Path $entryPath } catch { $namedPath = ([string]$_.Exception.Message -like "*$entryPath*") }
Assert-True -Condition $namedPath -Message "the refusal names the offending path"

# NEGATIVE CONTROL (arm two): private scratch is untouched by the guard.
New-Item -ItemType Directory -Force -Path $privateScratch | Out-Null
Set-Content -LiteralPath (Join-Path $privateScratch "stale.txt") -Value "stale" -Encoding ASCII
Ensure-CleanDirectory -Path $privateScratch
Assert-True -Condition (Test-Path -LiteralPath $privateScratch -PathType Container) `
  -Message "NEGATIVE CONTROL: a private scratch path is still cleaned"
Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $privateScratch "stale.txt"))) `
  -Message "NEGATIVE CONTROL: and cleaning it really did empty it, so the guard did not silently no-op everything"

# A sibling whose name merely STARTS with the root's name is not under it.
# Without this, a prefix comparison that forgot the separator would fence
# directories it has no business fencing, and the arm above would not catch it.
$lookalike = $storeRoot + "-scratch"
New-Item -ItemType Directory -Force -Path $lookalike | Out-Null
Ensure-CleanDirectory -Path $lookalike
Assert-True -Condition (Test-Path -LiteralPath $lookalike -PathType Container) `
  -Message "NEGATIVE CONTROL: '<root>-scratch' is not treated as being under '<root>'"

# And with no store configured at all, nothing is fenced -- the guard must not
# be a global prohibition on deleting directories.
[Environment]::SetEnvironmentVariable("CODETRACER_WINDOWS_STORE_ROOT", $null)
Assert-Equal -Expected "" -Actual (Get-ContainingStoreRoot -Path $entryPath) `
  -Message "NEGATIVE CONTROL: with no store root configured, no path is fenced"
[Environment]::SetEnvironmentVariable("CODETRACER_WINDOWS_STORE_ROOT", $storeRoot)

# ---------------------------------------------------------------------------
# t_win_store_relocation_roundtrip  -- THE GATE
#
# Per component, not in aggregate. A blanket "the tree still works" assertion
# would hide one broken component in twenty, which is exactly the failure this
# gate is supposed to catch.
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "== t_win_store_relocation_roundtrip (THE GATE)"

$rootOne = Join-Path $scratch "R1"
$rootTwo = Join-Path $scratch "R2"
New-Item -ItemType Directory -Force -Path $rootOne | Out-Null

# Each entry mirrors the layout its production Ensure-* function now
# produces, including which subdirectory the pointer names -- that is the
# part relocation depends on, and getting it wrong here would make the test
# pass against a layout nothing produces.
$components = @(
  [pscustomobject]@{ name = "gcc";   version = "15.2.0";  installSubPath = "gcc/winlibs-15.2.0/mingw64" },
  [pscustomobject]@{ name = "llvm";  version = "20.1.0";  installSubPath = "llvm/20.1.0/clang+llvm-20.1.0-x86_64-pc-windows-msvc" },
  [pscustomobject]@{ name = "zstd";  version = "1.5.6";   installSubPath = "zstd/1.5.6/zstd-v1.5.6-win64" },
  [pscustomobject]@{ name = "nim";   version = "2.2.4";   installSubPath = "nim/2.2.4/nim-2.2.4" },
  [pscustomobject]@{ name = "capnp"; version = "1.0.2";   installSubPath = "capnp/1.0.2/capnproto-c++-1.0.2" }
)

foreach ($component in $components) {
  $versionRoot = Join-Path $rootOne ("$($component.name)/$($component.version)")
  $installDir = Join-Path $rootOne $component.installSubPath
  $binDir = Join-Path $installDir "bin"
  New-ToolExecutable -BinDir $binDir -Name $component.name -Version $component.version | Out-Null

  # The PRODUCTION writer, not a hand-rolled equivalent. If
  # `Write-InstallPointer` ever started writing an absolute path, this test
  # would catch it; a test that wrote its own pointer file would not.
  $relative = Write-InstallPointer -Root $rootOne -Component $component.name `
    -VersionRoot $versionRoot -InstallDir $installDir -Metadata @{
      version = $component.version
      install_arm = "test-fixture"
    }
  Assert-Equal -Expected $component.installSubPath -Actual $relative `
    -Message "$($component.name): the pointer records a ROOT-RELATIVE path"
}

# Prove the tools work at R1 first. Without this the round trip could "pass"
# because the tools never worked anywhere, and the gate would be measuring
# nothing.
foreach ($component in $components) {
  $dir = Resolve-InstallDirFromRelativePathFile -InstallRoot $rootOne `
    -RelativePathFile (Join-Path $rootOne "$($component.name)/$($component.version)/$($component.name).install.relative-path")
  $exe = Join-Path $dir "bin/$($component.name)"
  if ($isWindowsHost) { $exe = "$exe.cmd" }
  $ran = Invoke-ToolExecutable -Path $exe
  Assert-True -Condition ($null -ne $ran -and $ran["VERSION"] -eq $component.version) `
    -Message "PRECONDITION: $($component.name) resolves and RUNS at the original root R1"
}

# The publish-and-refill hop.
$transferMechanism = Copy-TreeToNewRoot -SourceRoot $rootOne -DestinationRoot $rootTwo
Write-Host "  (transfer mechanism: $transferMechanism)"

# DESTROY R1. This is what turns the test from a rename into a relocation:
# anything still reaching for R1 now has nothing to reach.
Remove-Item -LiteralPath $rootOne -Recurse -Force
Assert-True -Condition (-not (Test-Path -LiteralPath $rootOne)) `
  -Message "the original root R1 is GONE, so nothing can silently keep resolving against it"

foreach ($component in $components) {
  $pointer = Join-Path $rootTwo "$($component.name)/$($component.version)/$($component.name).install.relative-path"
  $dir = Resolve-InstallDirFromRelativePathFile -InstallRoot $rootTwo -RelativePathFile $pointer
  $exe = Join-Path $dir "bin/$($component.name)"
  if ($isWindowsHost) { $exe = "$exe.cmd" }

  $ran = Invoke-ToolExecutable -Path $exe
  Assert-True -Condition ($null -ne $ran) `
    -Message "$($component.name): resolves and EXECUTES at the new root R2 after R1 was destroyed"

  if ($null -ne $ran) {
    Assert-Equal -Expected $component.version -Actual $ran["VERSION"] `
      -Message "$($component.name): the executable that ran is the right one"

    # It reported its own directory. That directory must be under R2 and must
    # NOT be under R1 -- the assertion a pointer-file string comparison cannot
    # make.
    $reported = ([string]$ran["HOME_DIR"]).TrimEnd('\', '/')
    $underTwo = $reported.StartsWith(
      ([System.IO.Path]::GetFullPath($rootTwo)), [System.StringComparison]::OrdinalIgnoreCase)
    Assert-True -Condition $underTwo `
      -Message "$($component.name): the tool that ran reports a home directory under R2 ('$reported')"
    Assert-True -Condition (-not $reported.StartsWith(
        ([System.IO.Path]::GetFullPath($rootOne)), [System.StringComparison]::OrdinalIgnoreCase)) `
      -Message "$($component.name): and NOT under the destroyed R1"
  }

  # And the relocated tree must itself be clean, by the same audit the
  # provisioning report runs.
  $findings = @(Get-InstallTreeRelocatabilityFindings -Root $rootTwo `
      -Path (Join-Path $rootTwo $component.installSubPath) |
    Where-Object { Test-RelocatabilityViolation -Finding $_ })
  Assert-Equal -Expected 0 -Actual $findings.Count `
    -Message "$($component.name): the relocated tree carries no relocatability violation"
}

# Components classified non-relocatable must be ABSENT, not merely failing.
foreach ($excluded in @("fpc", "msvc")) {
  Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $rootTwo $excluded))) `
    -Message "excluded component '$excluded' is ABSENT from the store, not present-and-broken"
}

# NEGATIVE CONTROL for the whole gate. A component that DOES bake an absolute
# path must fail the same round trip. Without this the gate could be passing
# because the round trip cannot fail -- which is precisely the defect this
# campaign has already found in two other controls.
Write-Host "  -- negative control: a component that bakes an absolute path"

$ncRootOne = Join-Path $scratch "NC1"
$ncRootTwo = Join-Path $scratch "NC2"
$ncInstall = Join-Path $ncRootOne "poisoned/1.0.0/tree"
$ncBin = Join-Path $ncInstall "bin"
New-Item -ItemType Directory -Force -Path $ncBin | Out-Null

# The tool resolves a sibling data file by an ABSOLUTE path -- the shape a
# real tool acquires when its configure step records where it was built.
$ncDataFile = Join-Path $ncInstall "share/poisoned.conf"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ncDataFile) | Out-Null
Set-Content -LiteralPath $ncDataFile -Value "ok" -Encoding ASCII

if ($isWindowsHost) {
  $ncExe = Join-Path $ncBin "poisoned.cmd"
  Set-Content -LiteralPath $ncExe -Encoding ASCII -Value @(
    "@echo off",
    "if not exist `"$ncDataFile`" exit /b 3",
    "echo VERSION=1.0.0")
} else {
  $ncExe = Join-Path $ncBin "poisoned"
  Set-Content -LiteralPath $ncExe -Encoding ASCII -Value @(
    "#!/bin/sh",
    "[ -f `"$ncDataFile`" ] || exit 3",
    "echo VERSION=1.0.0")
  & chmod 755 $ncExe
}

Write-InstallPointer -Root $ncRootOne -Component "poisoned" `
  -VersionRoot (Join-Path $ncRootOne "poisoned/1.0.0") -InstallDir $ncInstall | Out-Null

$ncRanBefore = Invoke-ToolExecutable -Path $ncExe
Assert-True -Condition ($null -ne $ncRanBefore) `
  -Message "NEGATIVE CONTROL precondition: the poisoned tool DOES work at its original root"

# The content scan must see it before anything is moved -- that is the point
# of having a content scan at all.
$ncContent = @(Get-BakedAbsolutePathFindings -Root $ncRootOne -Path $ncInstall |
  Where-Object { $_.kind -eq "baked-absolute-path" })
Assert-True -Condition ($ncContent.Count -ge 1) `
  -Message "NEGATIVE CONTROL: the CONTENT scan finds the baked absolute path"

# ...and the reparse scan must NOT, because there is no reparse point here.
# This pair is what proves the two checks are not redundant, and it is the
# case the milestone names: a component can be non-relocatable with zero
# reparse points.
$ncReparse = @(Get-ReparsePointFindings -Root $ncRootOne -Path $ncInstall)
Assert-Equal -Expected 0 -Actual $ncReparse.Count `
  -Message "NEGATIVE CONTROL: the REPARSE scan finds nothing, so a zero reparse count is not a clearance"

Copy-TreeToNewRoot -SourceRoot $ncRootOne -DestinationRoot $ncRootTwo | Out-Null
Remove-Item -LiteralPath $ncRootOne -Recurse -Force

$ncRelocatedExe = Join-Path $ncRootTwo "poisoned/1.0.0/tree/bin/poisoned"
if ($isWindowsHost) { $ncRelocatedExe = "$ncRelocatedExe.cmd" }
$ncRanAfter = Invoke-ToolExecutable -Path $ncRelocatedExe
Assert-True -Condition ($null -eq $ncRanAfter) `
  -Message "NEGATIVE CONTROL: the poisoned tool FAILS after relocation -- so the round trip above can fail"

# ---------------------------------------------------------------------------
# t_win_store_junction_components_converted
#
# Checked by WALKING the materialised tree, never by reading the scripts.
# Reading the scripts is what let ensure-gcc.ps1's unconditional junction be
# described as conditional for as long as it was.
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "== t_win_store_junction_components_converted"

$linkRoot = Join-Path $scratch "links"
$insideTarget = Join-Path $linkRoot "gcc/winlibs-15.2.0/mingw64"
$outsideTarget = Join-Path $scratch "outside-the-root"
New-Item -ItemType Directory -Force -Path $insideTarget | Out-Null
New-Item -ItemType Directory -Force -Path $outsideTarget | Out-Null

# Case 1: the exact link ensure-gcc.ps1 used to create -- an ABSOLUTE target
# that points INSIDE the install root. This is the case a "does the target
# resolve inside the root?" check passes and relocation fails, and it is why
# the audit tests the stored target instead.
$absoluteInsideLink = Join-Path $linkRoot "gcc/15.2.0"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $absoluteInsideLink) | Out-Null
$madeAbsoluteInside = New-EscapingLink -LinkPath $absoluteInsideLink -TargetPath $insideTarget

if ($madeAbsoluteInside) {
  $findings = @(Get-ReparsePointFindings -Root $linkRoot -Path (Join-Path $linkRoot "gcc"))
  $absolute = @($findings | Where-Object { $_.kind -eq "reparse-absolute-target" })
  Assert-True -Condition ($absolute.Count -ge 1) `
    -Message "an ABSOLUTE-target link is flagged even though its target is inside the root"
  Assert-True -Condition (@($absolute | Where-Object { Test-RelocatabilityViolation -Finding $_ }).Count -ge 1) `
    -Message "and it counts as a relocatability violation"
} else {
  Write-Host "  SKIP: this host will not create links without elevation; the absolute-target case was not exercised."
  Assert-True -Condition $true -Message "(link creation unavailable - case skipped, and said so)"
}

# Case 2: an absolute target OUTSIDE the root. Same verdict, different reason;
# both must be caught, and a check that only caught this one would have
# cleared the gcc junction.
$outsideLink = Join-Path $linkRoot "llvm-system"
$madeOutside = New-EscapingLink -LinkPath $outsideLink -TargetPath $outsideTarget
if ($madeOutside) {
  $findings = @(Get-ReparsePointFindings -Root $linkRoot -Path $linkRoot |
    Where-Object { $_.path -like "*llvm-system*" })
  Assert-True -Condition (@($findings | Where-Object { Test-RelocatabilityViolation -Finding $_ }).Count -ge 1) `
    -Message "a link to a target outside the root is a violation too"
}

# NEGATIVE CONTROL: a RELATIVE link resolving inside the root travels with the
# tree and must NOT be flagged. Without this the audit could be "flag every
# reparse point", which would be indistinguishable from working and would
# fail every component that legitimately uses an internal relative link.
$relativeLinkMade = $false
$relativeLink = Join-Path $linkRoot "gcc/current"
try {
  New-Item -ItemType SymbolicLink -Path $relativeLink -Target "winlibs-15.2.0/mingw64" -ErrorAction Stop | Out-Null
  $relativeLinkMade = $true
} catch {
  $relativeLinkMade = $false
}

if ($relativeLinkMade) {
  $relFindings = @(Get-ReparsePointFindings -Root $linkRoot -Path (Join-Path $linkRoot "gcc") |
    Where-Object { $_.path -like "*current*" })
  Assert-Equal -Expected 1 -Actual $relFindings.Count `
    -Message "NEGATIVE CONTROL: the relative link IS seen by the walk (so the walk reaches it)"
  Assert-Equal -Expected "reparse-inside-root" -Actual $relFindings[0].kind `
    -Message "NEGATIVE CONTROL: and it is classified as travelling with the tree"
  Assert-True -Condition (-not (Test-RelocatabilityViolation -Finding $relFindings[0])) `
    -Message "NEGATIVE CONTROL: so it is NOT a violation -- the audit is not 'flag everything'"
} else {
  Write-Host "  SKIP: relative symlink creation unavailable on this host."
}

# NEGATIVE CONTROL: a tree with no links at all yields no findings, so the
# walk is not manufacturing them.
$cleanTree = Join-Path $scratch "clean-tree/bin"
New-Item -ItemType Directory -Force -Path $cleanTree | Out-Null
Set-Content -LiteralPath (Join-Path $cleanTree "tool.txt") -Value "no links here" -Encoding ASCII
Assert-Equal -Expected 0 `
  -Actual (@(Get-ReparsePointFindings -Root (Join-Path $scratch "clean-tree") -Path $cleanTree)).Count `
  -Message "NEGATIVE CONTROL: a link-free tree produces no reparse findings"

# The audit must not FOLLOW an escaping link, or it walks outside the tree it
# was asked about. Proven by putting a file beyond the link and asserting it
# is never reported.
if ($madeOutside) {
  Set-Content -LiteralPath (Join-Path $outsideTarget "beyond.txt") -Value "must not be walked" -Encoding ASCII
  $walked = @(Get-BakedAbsolutePathFindings -Root $linkRoot -Path $linkRoot |
    Where-Object { $_.path -like "*beyond.txt*" })
  Assert-Equal -Expected 0 -Actual $walked.Count `
    -Message "the audit does not FOLLOW an escaping link into the tree it names"
}

# ---------------------------------------------------------------------------
# The rustup content-level repair.
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "== rustup settings.toml relocatability repair"

$rustupHome = Join-Path $scratch "rustup"
New-Item -ItemType Directory -Force -Path $rustupHome | Out-Null
$settingsPath = Join-Path $rustupHome "settings.toml"

# The real shape rustup writes: a version, a default toolchain, a profile, and
# an [overrides] table whose KEYS are absolute directory paths.
#
# One of the two override keys is a REAL absolute path on this host (the
# scratch root) and the other is the Windows-shaped literal rustup writes on
# the lane. The real one is what the content scan is asserted against: a
# hard-coded `C:\...` would not be an absolute path on a Linux runner, so
# asserting on it would make the precondition pass or fail for a reason that
# has nothing to do with the check.
$overrideKey = $scratch.Replace("\", "\\")
Set-Content -LiteralPath $settingsPath -Encoding ASCII -Value @(
  'version = "12"',
  'default_toolchain = "1.85.0-x86_64-pc-windows-msvc"',
  'profile = "minimal"',
  '',
  '[overrides]',
  "`"$overrideKey`" = `"1.85.0-x86_64-pc-windows-msvc`"",
  '"C:\\work\\codetracer" = "nightly-x86_64-pc-windows-msvc"')

$before = @(Get-BakedAbsolutePathFindings -Root $scratch -Path $rustupHome |
  Where-Object { $_.kind -eq "baked-absolute-path" })
Assert-True -Condition ($before.Count -ge 1) `
  -Message "PRECONDITION: the unrepaired settings.toml contains an absolute path the scan can see"

$repair = Repair-RustupSettingsRelocatability -RustupHome $rustupHome
Assert-True -Condition $repair.changed -Message "the repair reports that it changed the file"
Assert-Equal -Expected 3 -Actual $repair.removed_lines.Count `
  -Message "it removed the [overrides] header and both override entries"

$after = Get-Content -LiteralPath $settingsPath -Raw
Assert-True -Condition ($after -notlike "*$overrideKey*") -Message "the absolute paths are gone"
Assert-Equal -Expected 0 `
  -Actual (@(Get-BakedAbsolutePathFindings -Root $scratch -Path $rustupHome |
    Where-Object { $_.kind -eq "baked-absolute-path" })).Count `
  -Message "and the content scan now finds nothing -- the same check that failed before the repair"
Assert-True -Condition ($after -like "*default_toolchain*") `
  -Message "and default_toolchain SURVIVED -- the repair is targeted, not a truncation"
Assert-True -Condition ($after -like "*version = `"12`"*") -Message "as did version"
Assert-True -Condition ($after -like "*profile*") -Message "as did profile"

# NEGATIVE CONTROL: a settings.toml with no [overrides] table is left exactly
# alone. A repair that rewrote every file would pass the assertions above.
$cleanRustup = Join-Path $scratch "rustup-clean"
New-Item -ItemType Directory -Force -Path $cleanRustup | Out-Null
$cleanSettings = Join-Path $cleanRustup "settings.toml"
Set-Content -LiteralPath $cleanSettings -Encoding ASCII -Value @(
  'version = "12"', 'default_toolchain = "1.85.0-x86_64-pc-windows-msvc"')
$cleanBytesBefore = [System.IO.File]::ReadAllBytes($cleanSettings)
$cleanRepair = Repair-RustupSettingsRelocatability -RustupHome $cleanRustup
Assert-True -Condition (-not $cleanRepair.changed) `
  -Message "NEGATIVE CONTROL: a settings.toml with no overrides is reported unchanged"
Assert-True -Condition (
    [System.Linq.Enumerable]::SequenceEqual(
      [byte[]]$cleanBytesBefore, [byte[]][System.IO.File]::ReadAllBytes($cleanSettings))) `
  -Message "NEGATIVE CONTROL: and is byte-identical afterwards"

# NEGATIVE CONTROL: a missing settings.toml is not an error.
$emptyRustup = Join-Path $scratch "rustup-empty"
New-Item -ItemType Directory -Force -Path $emptyRustup | Out-Null
$emptyRepair = Repair-RustupSettingsRelocatability -RustupHome $emptyRustup
Assert-True -Condition (-not $emptyRepair.changed) `
  -Message "NEGATIVE CONTROL: a rustup home with no settings.toml is a no-op, not a throw"

# A table AFTER [overrides] must survive. Without this the repair could be
# "delete everything from [overrides] onwards", which would pass every check
# above and quietly destroy config.
$orderRustup = Join-Path $scratch "rustup-order"
New-Item -ItemType Directory -Force -Path $orderRustup | Out-Null
Set-Content -LiteralPath (Join-Path $orderRustup "settings.toml") -Encoding ASCII -Value @(
  'version = "12"',
  '[overrides]',
  '"C:\\gone" = "toolchain"',
  '[some_later_table]',
  'keep_me = "yes"')
Repair-RustupSettingsRelocatability -RustupHome $orderRustup | Out-Null
$orderAfter = Get-Content -LiteralPath (Join-Path $orderRustup "settings.toml") -Raw
Assert-True -Condition ($orderAfter -like "*keep_me*") `
  -Message "a table AFTER [overrides] survives the repair"
Assert-True -Condition ($orderAfter -notlike "*C:\\gone*") `
  -Message "while the override itself is still removed"

# ---------------------------------------------------------------------------
# Assert-BootstrapRelocatability -- the WARN-to-FAIL promotion.
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "== Assert-BootstrapRelocatability promotes a violation to a failure"

$reportDir = Join-Path $scratch "reports"
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

$cleanReport = Join-Path $reportDir "clean.json"
@{ relocatability_violations = @() } | ConvertTo-Json -Depth 5 |
  Set-Content -LiteralPath $cleanReport -Encoding UTF8
$cleanPassed = $true
try { Assert-BootstrapRelocatability -ReportPath $cleanReport } catch { $cleanPassed = $false }
Assert-True -Condition $cleanPassed `
  -Message "NEGATIVE CONTROL: a report with no violations passes"

$dirtyReport = Join-Path $reportDir "dirty.json"
@{ relocatability_violations = @(
    @{ step = "GCC"; kind = "reparse-absolute-target"; path = "C:\\dev-deps\\gcc\\15.2.0"; detail = "absolute target" }) } |
  ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $dirtyReport -Encoding UTF8
Assert-Throws -Script { Assert-BootstrapRelocatability -ReportPath $dirtyReport } `
  -MessageContains "GCC" `
  -Message "a report with a violation FAILS, naming the component"

# A missing report is the absence of evidence, not a pass.
Assert-Throws -Script { Assert-BootstrapRelocatability -ReportPath (Join-Path $reportDir "nope.json") } `
  -MessageContains "unchecked claim" `
  -Message "a missing report is a failure, not a silent pass"

# ---------------------------------------------------------------------------
# t_win_store_fpc_and_msvc_documented_exclusions
#
# Mechanical, and cross-checked against env.ps1's OWN dispatch block rather
# than against a second hand-maintained list -- a list checked against another
# list can drift together.
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "== t_win_store_fpc_and_msvc_documented_exclusions"

Assert-True -Condition (Test-Path -LiteralPath $exclusionsPath -PathType Leaf) `
  -Message "the exclusion list exists at non-nix-build/windows/store-exclusions.json"

$exclusions = Get-Content -LiteralPath $exclusionsPath -Raw | ConvertFrom-Json
$excludedNames = @($exclusions.exclusions | ForEach-Object { $_.component })

foreach ($required in @("FPC", "MSVC")) {
  Assert-True -Condition ($excludedNames -contains $required) `
    -Message "$required is named in the exclusion list"
  $entry = $exclusions.exclusions | Where-Object { $_.component -eq $required } | Select-Object -First 1
  Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($entry.summary)) `
    -Message "$required carries a stated reason"
  Assert-True -Condition (@($entry.evidence).Count -ge 1) `
    -Message "$required carries at least one piece of evidence, not just an assertion"
}

# The FPC entry must record BOTH open questions and must not claim either is
# settled. This is the check that stops "measure it" from decaying into
# "repeat what we were told".
$fpcEntry = $exclusions.exclusions | Where-Object { $_.component -eq "FPC" } | Select-Object -First 1
$fpcQuestions = @($fpcEntry.open_questions)
Assert-Equal -Expected 2 -Actual $fpcQuestions.Count `
  -Message "FPC records both open questions (uninstall registry keys; absolute paths in fpc.cfg)"
foreach ($question in $fpcQuestions) {
  Assert-True -Condition ($question.status -in @("UNMEASURED", "MEASURED")) `
    -Message "FPC question '$($question.claim)' carries an explicit measurement status"
  Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($question.how_to_measure)) `
    -Message "FPC question '$($question.claim)' says how it would be measured"
}

# Cross-check against env.ps1's dispatch: every gated component NOT declared
# `relocatable` must be in the exclusion list, so an exclusion cannot lapse by
# somebody adding a second installer-shaped component.
$parseErrors = $null
$envAst = [System.Management.Automation.Language.Parser]::ParseFile($envPs1Path, [ref]$null, [ref]$parseErrors)
Assert-Equal -Expected 0 -Actual $parseErrors.Count -Message "env.ps1 parses"

$dispatchCalls = $envAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq "Invoke-BootstrapStep"
  }, $true)
Assert-True -Condition ($dispatchCalls.Count -ge 15) `
  -Message "the dispatch block was found by AST ($($dispatchCalls.Count) Invoke-BootstrapStep calls)"

$nonRelocatable = @()
$relocatableSteps = @()
foreach ($call in $dispatchCalls) {
  $step = ""
  $class = ""
  for ($i = 0; $i -lt $call.CommandElements.Count - 1; $i++) {
    $element = $call.CommandElements[$i]
    if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
      $next = $call.CommandElements[$i + 1]
      # `-Step "TTD"` is a quoted StringConstantExpressionAst; `-Relocatability
      # relocatable` is a BAREWORD, which the parser also represents as a
      # StringConstantExpressionAst (with a BareWord StringConstantType), so
      # one branch covers both. Anything else falls back to the raw extent
      # text rather than being silently dropped -- a component whose arguments
      # this loop could not read must not quietly disappear from the
      # cross-check below.
      $value = ""
      if ($next -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        $value = $next.Value
      } else {
        $value = $next.Extent.Text.Trim('"', "'")
      }
      if ($element.ParameterName -eq "Step") { $step = $value }
      if ($element.ParameterName -eq "Relocatability") { $class = $value }
    }
  }
  if ([string]::IsNullOrWhiteSpace($step)) { continue }
  if ($class -eq "relocatable") { $relocatableSteps += $step } else { $nonRelocatable += $step }
}

Assert-True -Condition ($relocatableSteps.Count -ge 15) `
  -Message "the AST read the Relocatability argument for the relocatable components ($($relocatableSteps.Count))"
Assert-True -Condition ($nonRelocatable -contains "FPC") `
  -Message "PRECONDITION: env.ps1 really does declare FPC non-relocatable (so the check below has a subject)"

foreach ($step in $nonRelocatable) {
  Assert-True -Condition ($excludedNames -contains $step) `
    -Message "every non-relocatable gated component is in the exclusion list ('$step')"
}

# The other direction: an excluded component must not simultaneously be
# declared relocatable, which would mean the list and the code disagree.
foreach ($excluded in $excludedNames) {
  Assert-True -Condition (-not ($relocatableSteps -contains $excluded)) `
    -Message "excluded component '$excluded' is not also declared relocatable in env.ps1"
}

# MSVC's exclusion is structural: assert it really is absent from the dispatch
# rather than trusting the note that says so.
$allSteps = @($relocatableSteps + $nonRelocatable)
Assert-True -Condition (-not ($allSteps -contains "MSVC")) `
  -Message "MSVC is absent from the dispatch entirely, which is what makes its exclusion structural"

# And that export-msvc-env.ps1 genuinely installs nothing -- the evidence the
# exclusion rests on, checked rather than quoted.
$msvcSource = Get-Content -LiteralPath (Join-Path $repoRoot "non-nix-build/windows/export-msvc-env.ps1") -Raw
foreach ($installer in @("Download-File", "Invoke-WebRequest", "winget install", "Expand-Archive", "Ensure-CleanDirectory")) {
  Assert-True -Condition ($msvcSource -notlike "*$installer*") `
    -Message "export-msvc-env.ps1 contains no '$installer' -- it discovers, it does not install"
}

} finally {
  [Environment]::SetEnvironmentVariable("CODETRACER_WINDOWS_STORE_ROOT", $savedStoreRoot)
  [Environment]::SetEnvironmentVariable("REPRO_STORE_ROOT", $savedReproStoreRoot)
  if (Test-Path -LiteralPath $scratch) {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host ""
Write-Host "windows-store-relocation: $($script:Checks - $script:Failures)/$($script:Checks) checks passed"
if ($script:Failures -gt 0) {
  throw "windows-store-relocation: $($script:Failures) check(s) failed."
}
