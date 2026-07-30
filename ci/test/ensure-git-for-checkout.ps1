Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Throws {
  param(
    [scriptblock]$Action,
    [string]$ExpectedMessage
  )

  $message = ""
  try {
    & $Action
    throw "The simulated failure unexpectedly succeeded."
  }
  catch {
    $message = $_.Exception.Message
  }
  Assert-True `
    -Condition ($message.Contains($ExpectedMessage)) `
    -Message "Expected failure containing '$ExpectedMessage', got '$message'."
}

function Assert-ThrowsAny {
  param([scriptblock]$Action)

  try {
    & $Action
  }
  catch {
    return
  }
  throw "The simulated failure unexpectedly succeeded."
}

function Get-BytesSha256 {
  param([byte[]]$Bytes)

  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha256.ComputeHash($Bytes)
  }
  finally {
    $sha256.Dispose()
  }
  return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function New-FakePortableGitLayout {
  param([string]$Root)

  $cmd = Join-Path $Root "cmd"
  $bin = Join-Path $Root "bin"
  New-Item -ItemType Directory -Force -Path $cmd, $bin | Out-Null
  [IO.File]::WriteAllText((Join-Path $cmd "git.exe"), "fake git")
  [IO.File]::WriteAllText((Join-Path $bin "bash.exe"), "fake bash")
}

function New-TestDirectory {
  param([string]$Name)

  $path = Join-Path $script:TestRoot $Name
  New-Item -ItemType Directory -Path $path | Out-Null
  return $path
}

function Invoke-Test {
  param(
    [string]$Name,
    [scriptblock]$Action
  )

  & $Action
  $script:Passed += 1
  Write-Host "ok $($script:Passed) - $Name"
}

$helper = Join-Path $PSScriptRoot "..\ensure-git-for-checkout.ps1"
. $helper

$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) `
  "codetracer-git-bootstrap-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $script:TestRoot | Out-Null
$script:Passed = 0
$savedPath = $env:PATH
$savedGitConfigParameters = $env:GIT_CONFIG_PARAMETERS
$savedGitConfigCount = $env:GIT_CONFIG_COUNT
$savedGitConfigKey0 = $env:GIT_CONFIG_KEY_0
$savedGitConfigValue0 = $env:GIT_CONFIG_VALUE_0
$hostGit = (Get-Command git -ErrorAction Stop).Source

try {
  Invoke-Test "pins the official PortableGit asset and rejects Chocolatey fallback" {
    Assert-True `
      ($script:PortableGitUrl -ceq `
        "https://github.com/git-for-windows/git/releases/download/" +
        "v2.55.0.windows.3/PortableGit-2.55.0.3-64-bit.7z.exe") `
      "The bootstrap does not use the reviewed official asset URL."
    Assert-True `
      ($script:PortableGitSha256 -ceq `
        "ab00566336b5472120f9a52d34f2e79c5406535792acb0548001ffd0bd090e5d") `
      "The bootstrap does not use the reviewed PortableGit digest."
    Assert-True ($script:PortableGitVersion -eq [Version]"2.55.0") `
      "The expected provisioned Git version is not pinned."
    Assert-True ($script:MinimumGitVersion -eq [Version]"2.18.0") `
      "The actions/checkout minimum Git version changed."
    $source = Get-Content -LiteralPath $helper -Raw
    Assert-True (-not $source.Contains("choco.exe")) `
      "The no-Git path still depends on Chocolatey."
  }

  Invoke-Test "uses an existing supported Git without provisioning" {
    $caseRoot = New-TestDirectory "existing"
    $gitRoot = Join-Path $caseRoot "installed-git"
    New-FakePortableGitLayout $gitRoot
    $git = Join-Path (Join-Path $gitRoot "cmd") "git.exe"
    $githubPath = Join-Path $caseRoot "github-path.txt"
    $githubEnv = Join-Path $caseRoot "github-env.txt"
    [IO.File]::WriteAllText($githubPath, "")
    [IO.File]::WriteAllText($githubEnv, "")
    $env:PATH = "original-path"
    $state = [PSCustomObject]@{ Provisioned = $false }
    $result = Ensure-CodeTracerGitForCheckout `
      -Destination (Join-Path $caseRoot "must-not-install") `
      -GitHubPathFile $githubPath `
      -GitHubEnvFile $githubEnv `
      -CandidateProvider { @($git) } `
      -VersionReader { param($path) [Version]"2.51.2" } `
      -ProvisionGit {
        param($destination, $versionReader)
        $state.Provisioned = $true
        throw "provisioning must not run"
      }
    Assert-True (-not $state.Provisioned) "A supported existing Git triggered provisioning."
    Assert-True ($result.Path -ceq (Resolve-Path $git).Path) `
      "The supported Git candidate was not selected."
    Assert-True ($result.Version -eq [Version]"2.51.2") `
      "The selected Git version was not preserved."
    $expectedEntries = @(
      (Join-Path $gitRoot "cmd"),
      (Join-Path $gitRoot "bin")
    )
    Assert-True (($result.PathEntries -join "`0") -ceq ($expectedEntries -join "`0")) `
      "The selected Git did not expose both checkout and Git Bash directories."
    $expectedPath = ($expectedEntries -join [IO.Path]::PathSeparator) +
      [IO.Path]::PathSeparator + "original-path"
    Assert-True ($env:PATH -ceq $expectedPath) `
      "The current process PATH does not prefer the selected Git."
    $persisted = @(Get-Content -LiteralPath $githubPath | Where-Object { $_ })
    Assert-True (($persisted -join "`0") -ceq ($expectedEntries -join "`0")) `
      "GITHUB_PATH does not contain the exact Git and Git Bash directories."
    $persistedEnv = @(Get-Content -LiteralPath $githubEnv)
    $expectedEnv = @(
      "GIT_CONFIG_PARAMETERS=",
      "GIT_CONFIG_COUNT=1",
      "GIT_CONFIG_KEY_0=core.longpaths",
      "GIT_CONFIG_VALUE_0=true"
    )
    Assert-True (($persistedEnv -join "`0") -ceq ($expectedEnv -join "`0")) `
      "GITHUB_ENV does not contain the exact job-scoped long-path configuration."
    Assert-True ([string]::IsNullOrEmpty($env:GIT_CONFIG_PARAMETERS)) `
      "The current process retained an inline Git configuration override."
    Assert-True ($env:GIT_CONFIG_COUNT -ceq "1") `
      "The current process did not receive the bounded Git configuration count."
    Assert-True ($env:GIT_CONFIG_KEY_0 -ceq "core.longpaths") `
      "The current process did not receive the long-path configuration key."
    Assert-True ($env:GIT_CONFIG_VALUE_0 -ceq "true") `
      "The current process did not enable Windows long-path handling."
  }

  Invoke-Test "provisions verified PortableGit when Git and Chocolatey are absent" {
    $caseRoot = New-TestDirectory "provision-success"
    $destination = Join-Path $caseRoot "portable"
    $githubPath = Join-Path $caseRoot "github-path.txt"
    $githubEnv = Join-Path $caseRoot "github-env.txt"
    [IO.File]::WriteAllText($githubPath, "")
    [IO.File]::WriteAllText($githubEnv, "")
    $assetBytes = [Text.Encoding]::UTF8.GetBytes("reviewed portable git fixture")
    $assetSha = Get-BytesSha256 $assetBytes
    $state = [PSCustomObject]@{ Downloads = 0; Extractions = 0 }
    $env:PATH = "runner-path-without-git-or-choco"

    $result = Ensure-CodeTracerGitForCheckout `
      -Destination $destination `
      -GitHubPathFile $githubPath `
      -GitHubEnvFile $githubEnv `
      -CandidateProvider { @() } `
      -VersionReader { param($path) [Version]"2.55.0" } `
      -ProvisionGit {
        param($installDestination, $versionReader)
        Install-CodeTracerPortableGit `
          -Destination $installDestination `
          -AssetUrl "https://example.invalid/reviewed-portable-git.exe" `
          -ExpectedSha256 $assetSha `
          -ExpectedGitVersion ([Version]"2.55.0") `
          -DownloadFile {
            param($url, $path)
            $state.Downloads += 1
            [IO.File]::WriteAllBytes($path, $assetBytes)
          } `
          -ExtractArchive {
            param($archive, $root)
            $state.Extractions += 1
            New-FakePortableGitLayout $root
          } `
          -VersionReader $versionReader
      }

    Assert-True ($state.Downloads -eq 1) "The pinned artifact was not downloaded exactly once."
    Assert-True ($state.Extractions -eq 1) "The verified artifact was not extracted exactly once."
    Assert-True ($result.Version -eq [Version]"2.55.0") `
      "The provisioned Git version was not verified."
    Assert-True (Test-Path -LiteralPath $result.Path -PathType Leaf) `
      "The staged installation was not moved into its final destination."
    Assert-True (($result.PathEntries | Measure-Object).Count -eq 2) `
      "PortableGit did not propagate both cmd and bin."
    Assert-True (@(Get-ChildItem -LiteralPath $caseRoot -Filter '*.exe').Count -eq 0) `
      "The verified self-extracting archive was not cleaned up."
  }

  Invoke-Test "rejects an artifact whose SHA256 does not match" {
    $caseRoot = New-TestDirectory "hash-mismatch"
    $state = [PSCustomObject]@{ Extracted = $false }
    Assert-Throws -ExpectedMessage "PortableGit SHA256 mismatch" -Action {
      Install-CodeTracerPortableGit `
        -Destination (Join-Path $caseRoot "portable") `
        -AssetUrl "https://example.invalid/portable.exe" `
        -ExpectedSha256 ("a" * 64) `
        -ExpectedGitVersion ([Version]"2.55.0") `
        -DownloadFile {
          param($url, $path)
          [IO.File]::WriteAllText($path, "tampered")
        } `
        -HashFile { param($path) "b" * 64 } `
        -ExtractArchive {
          param($archive, $root)
          $state.Extracted = $true
        } `
        -VersionReader { param($path) [Version]"2.55.0" } | Out-Null
    }
    Assert-True (-not $state.Extracted) "An unverified artifact reached the extractor."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $caseRoot "portable"))) `
      "A hash failure replaced the installation destination."
  }

  Invoke-Test "rejects malformed, obsolete, and Bash-less Git candidates" {
    $caseRoot = New-TestDirectory "candidate-versions"
    $malformed = Join-Path $caseRoot "malformed-git.exe"
    $obsolete = Join-Path $caseRoot "obsolete-git.exe"
    $bashlessRoot = Join-Path $caseRoot "bashless"
    $bashlessCmd = Join-Path $bashlessRoot "cmd"
    New-Item -ItemType Directory -Path $bashlessCmd | Out-Null
    $bashless = Join-Path $bashlessCmd "git.exe"
    [IO.File]::WriteAllText($malformed, "fake")
    [IO.File]::WriteAllText($obsolete, "fake")
    [IO.File]::WriteAllText($bashless, "fake")
    $result = Find-CodeTracerUsableGit `
      -MinimumVersion ([Version]"2.18.0") `
      -CandidateProvider { @($malformed, $obsolete, $bashless) } `
      -VersionReader {
        param($path)
        if ($path -ceq $obsolete) {
          [Version]"2.17.9"
        }
        elseif ($path -ceq $bashless) {
          [Version]"2.51.2"
        }
        else {
          $null
        }
      }
    Assert-True ($null -eq $result) `
      "The discovery path accepted malformed, obsolete, or Bash-less Git."
  }

  Invoke-Test "rejects a provisioned executable with the wrong version" {
    $caseRoot = New-TestDirectory "wrong-version"
    $bytes = [Text.Encoding]::UTF8.GetBytes("correct hash, wrong extracted Git")
    $sha = Get-BytesSha256 $bytes
    Assert-Throws -ExpectedMessage "reported version 2.54.0; expected 2.55.0" -Action {
      Install-CodeTracerPortableGit `
        -Destination (Join-Path $caseRoot "portable") `
        -ExpectedSha256 $sha `
        -ExpectedGitVersion ([Version]"2.55.0") `
        -DownloadFile {
          param($url, $path)
          [IO.File]::WriteAllBytes($path, $bytes)
        } `
        -ExtractArchive {
          param($archive, $root)
          New-FakePortableGitLayout $root
        } `
        -VersionReader { param($path) [Version]"2.54.0" } | Out-Null
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $caseRoot "portable"))) `
      "A wrong-version extraction replaced the installation destination."
  }

  Invoke-Test "propagates download failures without leaving partial state" {
    $caseRoot = New-TestDirectory "download-failure"
    Assert-Throws -ExpectedMessage "simulated download failure" -Action {
      Install-CodeTracerPortableGit `
        -Destination (Join-Path $caseRoot "portable") `
        -DownloadFile { throw "simulated download failure" } | Out-Null
    }
    Assert-True (@(Get-ChildItem -LiteralPath $caseRoot).Count -eq 0) `
      "A download failure left an archive or staging directory behind."
  }

  Invoke-Test "propagates extraction failures without replacing an installation" {
    $caseRoot = New-TestDirectory "extract-failure"
    $destination = Join-Path $caseRoot "portable"
    New-Item -ItemType Directory -Path $destination | Out-Null
    $marker = Join-Path $destination "known-good-marker"
    [IO.File]::WriteAllText($marker, "keep")
    $bytes = [Text.Encoding]::UTF8.GetBytes("verified but cannot extract")
    $sha = Get-BytesSha256 $bytes
    Assert-Throws -ExpectedMessage "simulated extraction failure" -Action {
      Install-CodeTracerPortableGit `
        -Destination $destination `
        -ExpectedSha256 $sha `
        -DownloadFile {
          param($url, $path)
          [IO.File]::WriteAllBytes($path, $bytes)
        } `
        -ExtractArchive { throw "simulated extraction failure" } | Out-Null
    }
    Assert-True (Test-Path -LiteralPath $marker -PathType Leaf) `
      "An extraction failure replaced the last known-good installation."
    $leftovers = @(Get-ChildItem -LiteralPath $caseRoot |
      Where-Object { $_.Name -ne "portable" })
    Assert-True ($leftovers.Count -eq 0) `
      "An extraction failure left an archive or staging directory behind."
  }

  Invoke-Test "restores an existing installation when activation fails" {
    $caseRoot = New-TestDirectory "activation-failure"
    $destination = Join-Path $caseRoot "portable"
    New-Item -ItemType Directory -Path $destination | Out-Null
    $marker = Join-Path $destination "known-good-marker"
    [IO.File]::WriteAllText($marker, "keep")
    $bytes = [Text.Encoding]::UTF8.GetBytes("verified but cannot activate")
    $sha = Get-BytesSha256 $bytes
    Assert-Throws -ExpectedMessage "simulated activation failure" -Action {
      Install-CodeTracerPortableGit `
        -Destination $destination `
        -ExpectedSha256 $sha `
        -ExpectedGitVersion ([Version]"2.55.0") `
        -DownloadFile {
          param($url, $path)
          [IO.File]::WriteAllBytes($path, $bytes)
        } `
        -ExtractArchive {
          param($archive, $root)
          New-FakePortableGitLayout $root
        } `
        -VersionReader { param($path) [Version]"2.55.0" } `
        -ActivateInstallation { throw "simulated activation failure" } | Out-Null
    }
    Assert-True (Test-Path -LiteralPath $marker -PathType Leaf) `
      "An activation failure did not restore the last known-good installation."
    $leftovers = @(Get-ChildItem -LiteralPath $caseRoot |
      Where-Object { $_.Name -ne "portable" })
    Assert-True ($leftovers.Count -eq 0) `
      "An activation failure left an archive, staging, or backup path behind."
  }

  Invoke-Test "replaces an existing installation only after verification" {
    $caseRoot = New-TestDirectory "replace-success"
    $destination = Join-Path $caseRoot "portable"
    New-Item -ItemType Directory -Path $destination | Out-Null
    $oldMarker = Join-Path $destination "old-marker"
    [IO.File]::WriteAllText($oldMarker, "old")
    $bytes = [Text.Encoding]::UTF8.GetBytes("verified replacement")
    $sha = Get-BytesSha256 $bytes
    $result = Install-CodeTracerPortableGit `
      -Destination $destination `
      -ExpectedSha256 $sha `
      -ExpectedGitVersion ([Version]"2.55.0") `
      -DownloadFile {
        param($url, $path)
        [IO.File]::WriteAllBytes($path, $bytes)
      } `
      -ExtractArchive {
        param($archive, $root)
        New-FakePortableGitLayout $root
      } `
      -VersionReader { param($path) [Version]"2.55.0" }
    Assert-True (-not (Test-Path -LiteralPath $oldMarker)) `
      "The verified replacement retained the previous installation."
    Assert-True (Test-Path -LiteralPath $result.Path -PathType Leaf) `
      "The verified replacement was not activated."
    Assert-True (@(Get-ChildItem -LiteralPath $caseRoot).Count -eq 1) `
      "A successful replacement left an archive, staging, or backup path behind."
  }

  Invoke-Test "fails closed when GITHUB_PATH cannot be propagated" {
    $caseRoot = New-TestDirectory "missing-github-path"
    $gitRoot = Join-Path $caseRoot "git"
    New-FakePortableGitLayout $gitRoot
    $git = Join-Path (Join-Path $gitRoot "cmd") "git.exe"
    Assert-Throws -ExpectedMessage "GITHUB_PATH is unavailable" -Action {
      Add-CodeTracerGitToPath -GitPath $git -GitHubPathFile "" | Out-Null
    }
  }

  Invoke-Test "propagates a GITHUB_PATH write failure" {
    $caseRoot = New-TestDirectory "unwritable-github-path"
    $gitRoot = Join-Path $caseRoot "git"
    New-FakePortableGitLayout $gitRoot
    $git = Join-Path (Join-Path $gitRoot "cmd") "git.exe"
    $directoryInsteadOfFile = Join-Path $caseRoot "github-path-directory"
    New-Item -ItemType Directory -Path $directoryInsteadOfFile | Out-Null
    Assert-ThrowsAny -Action {
      Add-CodeTracerGitToPath `
        -GitPath $git `
        -GitHubPathFile $directoryInsteadOfFile | Out-Null
    }
  }

  Invoke-Test "fails closed when GITHUB_ENV cannot propagate long-path support" {
    $env:GIT_CONFIG_PARAMETERS = "'core.longpaths=false'"
    Assert-Throws -ExpectedMessage "GITHUB_ENV is unavailable" -Action {
      Add-CodeTracerGitLongPathEnvironment -GitHubEnvFile ""
    }
    Assert-True ($env:GIT_CONFIG_PARAMETERS -ceq "'core.longpaths=false'") `
      "A failed propagation attempt changed the current process environment."
  }

  Invoke-Test "propagates a GITHUB_ENV write failure" {
    $caseRoot = New-TestDirectory "unwritable-github-env"
    $directoryInsteadOfFile = Join-Path $caseRoot "github-env-directory"
    New-Item -ItemType Directory -Path $directoryInsteadOfFile | Out-Null
    $env:GIT_CONFIG_PARAMETERS = "'core.longpaths=false'"
    Assert-ThrowsAny -Action {
      Add-CodeTracerGitLongPathEnvironment `
        -GitHubEnvFile $directoryInsteadOfFile
    }
    Assert-True ($env:GIT_CONFIG_PARAMETERS -ceq "'core.longpaths=false'") `
      "A failed GITHUB_ENV write changed the current process environment."
  }

  Invoke-Test "neutralizes hostile inherited GIT_CONFIG_PARAMETERS" {
    $caseRoot = New-TestDirectory "hostile-git-config-parameters"
    $githubEnv = Join-Path $caseRoot "github-env.txt"
    [IO.File]::WriteAllText($githubEnv, "")
    $env:GIT_CONFIG_PARAMETERS = "'core.longpaths=false'"
    $env:GIT_CONFIG_COUNT = "1"
    $env:GIT_CONFIG_KEY_0 = "core.longpaths"
    $env:GIT_CONFIG_VALUE_0 = "true"
    $before = (& $hostGit config --bool --get core.longpaths)
    Assert-True ($LASTEXITCODE -eq 0 -and $before -ceq "false") `
      "The hostile inline configuration fixture did not override core.longpaths."

    Add-CodeTracerGitLongPathEnvironment -GitHubEnvFile $githubEnv

    $after = (& $hostGit config --bool --get core.longpaths)
    Assert-True ($LASTEXITCODE -eq 0 -and $after -ceq "true") `
      "Hostile GIT_CONFIG_PARAMETERS still overrode the job-scoped setting."
    Assert-True ([string]::IsNullOrEmpty($env:GIT_CONFIG_PARAMETERS)) `
      "The hostile inline configuration was not cleared."
    Assert-True (
      (@(Get-Content -LiteralPath $githubEnv) -join "`0") -ceq
      (@(
        "GIT_CONFIG_PARAMETERS=",
        "GIT_CONFIG_COUNT=1",
        "GIT_CONFIG_KEY_0=core.longpaths",
        "GIT_CONFIG_VALUE_0=true"
      ) -join "`0")
    ) "The hardened environment was not propagated exactly."
  }

  Invoke-Test "bounds hostile inherited numbered Git configuration" {
    $caseRoot = New-TestDirectory "hostile-numbered-git-config"
    $githubEnv = Join-Path $caseRoot "github-env.txt"
    [IO.File]::WriteAllText($githubEnv, "")
    $env:GIT_CONFIG_PARAMETERS = ""
    $env:GIT_CONFIG_COUNT = "2"
    $env:GIT_CONFIG_KEY_0 = "core.longpaths"
    $env:GIT_CONFIG_VALUE_0 = "true"
    $env:GIT_CONFIG_KEY_1 = "core.longpaths"
    $env:GIT_CONFIG_VALUE_1 = "false"
    try {
      $before = (& $hostGit config --bool --get core.longpaths)
      Assert-True ($LASTEXITCODE -eq 0 -and $before -ceq "false") `
        "The hostile numbered configuration fixture did not override core.longpaths."

      Add-CodeTracerGitLongPathEnvironment -GitHubEnvFile $githubEnv

      $after = (& $hostGit config --bool --get core.longpaths)
      Assert-True ($LASTEXITCODE -eq 0 -and $after -ceq "true") `
        "An inherited numbered entry remained active above the bounded count."
      Assert-True ($env:GIT_CONFIG_COUNT -ceq "1") `
        "The numbered Git configuration was not bounded to one entry."
    }
    finally {
      Remove-Item -LiteralPath Env:GIT_CONFIG_KEY_1 -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath Env:GIT_CONFIG_VALUE_1 -ErrorAction SilentlyContinue
    }
  }
}
finally {
  $env:PATH = $savedPath
  $env:GIT_CONFIG_PARAMETERS = $savedGitConfigParameters
  $env:GIT_CONFIG_COUNT = $savedGitConfigCount
  $env:GIT_CONFIG_KEY_0 = $savedGitConfigKey0
  $env:GIT_CONFIG_VALUE_0 = $savedGitConfigValue0
  Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Passed -ne 16) {
  throw "Expected 16 Git bootstrap tests, but $($script:Passed) passed."
}
Write-Host "Git bootstrap contract tests passed: 16/16"
