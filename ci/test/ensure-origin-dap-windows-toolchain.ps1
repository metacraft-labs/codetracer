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

function New-TestDirectory {
  param([string]$Name)

  $path = Join-Path $script:TestRoot $Name
  New-Item -ItemType Directory -Path $path | Out-Null
  return $path
}

function New-FakeExecutable {
  param(
    [string]$Root,
    [string]$RelativePath
  )

  $path = Join-Path $Root $RelativePath
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  [IO.File]::WriteAllText($path, "fake executable")
  return $path
}

function New-FakeExtractedLayout {
  param(
    [string]$ExtractRoot,
    $Specification
  )

  $prefix = "$($Specification.Name)\"
  Assert-True `
    -Condition $Specification.RelativeExecutable.StartsWith($prefix) `
    -Message "Test specification path is not rooted under its tool name."
  $relativeWithinArchive = $Specification.RelativeExecutable.Substring($prefix.Length)
  New-FakeExecutable `
    -Root $ExtractRoot `
    -RelativePath $relativeWithinArchive | Out-Null
  $executableDirectory = Split-Path -Parent (Join-Path $ExtractRoot $relativeWithinArchive)
  foreach ($companion in @($Specification.CompanionExecutables)) {
    New-FakeExecutable `
      -Root $executableDirectory `
      -RelativePath $companion.Name | Out-Null
  }
}

function Get-TestSpecifications {
  $specifications = @()
  foreach ($specification in $script:ProductionSpecifications) {
    $bytes = [Text.Encoding]::UTF8.GetBytes("verified $($specification.Name) fixture")
    $script:AssetBytes[$specification.Name] = $bytes
    $specifications += [PSCustomObject]@{
      Name = $specification.Name
      CommandName = $specification.CommandName
      Version = [Version]$specification.Version
      ArchiveName = $specification.ArchiveName
      Url = "https://example.invalid/$($specification.ArchiveName)"
      Sha256 = Get-BytesSha256 -Bytes $bytes
      RelativeExecutable = $specification.RelativeExecutable
      VersionPattern = $specification.VersionPattern
      CompanionExecutables = @($specification.CompanionExecutables)
    }
  }
  return $specifications
}

function New-FakeInstalledToolchain {
  param(
    [string]$Root,
    [array]$Specifications
  )

  $tools = @()
  foreach ($specification in $Specifications) {
    $primary = New-FakeExecutable `
      -Root $Root `
      -RelativePath $specification.RelativeExecutable
    $directory = Split-Path -Parent $primary
    foreach ($companion in @($specification.CompanionExecutables)) {
      New-FakeExecutable `
        -Root $directory `
        -RelativePath $companion.Name | Out-Null
    }
    $tools += [PSCustomObject]@{
      Name = $specification.Name
      Path = $primary
      Version = [Version]$specification.Version
    }
  }
  return New-CodeTracerOriginToolchainResult -Tools $tools
}

function Remove-FakeExtractedExecutable {
  param(
    [string]$ExtractRoot,
    $ToolSpecification,
    [string]$ExecutableName
  )

  $prefix = "$($ToolSpecification.Name)\"
  $relativePrimary = $ToolSpecification.RelativeExecutable.Substring($prefix.Length)
  $primary = Join-Path $ExtractRoot $relativePrimary
  $target = if ($ExecutableName -ceq $ToolSpecification.CommandName) {
    $primary
  }
  else {
    Join-Path (Split-Path -Parent $primary) $ExecutableName
  }
  Remove-Item -LiteralPath $target -Force
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

$helper = Join-Path $PSScriptRoot "..\ensure-origin-dap-windows-toolchain.ps1"
$toolchainFile = Join-Path $PSScriptRoot `
  "..\..\non-nix-build\windows\toolchain-versions.env"
. $helper

$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) `
  "codetracer-origin-toolchain-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $script:TestRoot | Out-Null
$script:Passed = 0
$script:AssetBytes = @{}
$script:ProductionSpecifications = @(
  Get-CodeTracerOriginToolSpecifications -Path $toolchainFile
)
$savedPath = $env:PATH

try {
  Invoke-Test "pins official versioned artifacts and exact reviewed digests" {
    Assert-True ($script:ProductionSpecifications.Count -eq 3) `
      "Expected exactly three origin-DAP tool specifications."
    $capnp = $script:ProductionSpecifications[0]
    $nim = $script:ProductionSpecifications[1]
    $just = $script:ProductionSpecifications[2]
    Assert-True `
      ($capnp.Url -ceq "https://capnproto.org/capnproto-c++-win32-1.3.0.zip") `
      "The Cap'n Proto artifact URL is not the reviewed official pin."
    Assert-True `
      ($capnp.Sha256 -ceq "2c503361f8bf26fa9e7caccb6db04d6b271d5f0ad3da0616cf40e9a51335c89c") `
      "The Cap'n Proto digest is not the reviewed official pin."
    Assert-True `
      ((@($capnp.CompanionExecutables | ForEach-Object { $_.Name }) -join "`0") -ceq
        "capnpc-c++.exe`0capnpc-capnp.exe") `
      "The Cap'n Proto executable layout omits a required compiler plugin."
    Assert-True `
      ((@($capnp.CompanionExecutables | ForEach-Object { $_.Version }) -join "`0") -ceq
        "1.3.0`01.3.0") `
      "The Cap'n Proto compiler plugins are not pinned to 1.3.0."
    Assert-True `
      ($nim.Url -ceq "https://nim-lang.org/download/nim-2.2.8_x64.zip") `
      "The Nim artifact URL is not the reviewed official pin."
    Assert-True `
      ($nim.Sha256 -ceq "11fe2415a64a791b899cc78e2eeacdde93b5f122f2fabc447db36d38002bfb8c") `
      "The Nim digest is not the reviewed official pin."
    Assert-True `
      ($nim.CompanionExecutables.Count -eq 1 -and
        $nim.CompanionExecutables[0].Name -ceq "nimble.exe" -and
        $nim.CompanionExecutables[0].Version -eq [Version]"0.20.1") `
      "The pinned Nim archive must provide the reviewed nimble 0.20.1 companion."
    Assert-True `
      ($just.Url -ceq "https://github.com/casey/just/releases/download/1.46.0/just-1.46.0-x86_64-pc-windows-msvc.zip") `
      "The Just artifact URL is not the reviewed official pin."
    Assert-True `
      ($just.Sha256 -ceq "f0acf3f8ccbcf360b481baae9cae4c921774c89d5d932012481d3e0bda78ab39") `
      "The Just digest is not the reviewed official pin."
    $officialVersionOutput = @{
      "capnp.exe" = "Cap'n Proto version 1.3.0"
      "capnpc-c++.exe" = "Cap'n Proto C++ plugin version 1.3.0"
      "capnpc-capnp.exe" = "Cap'n Proto loopback plugin version 1.3.0"
      "nim.exe" = "Nim Compiler Version 2.2.8 [Windows: amd64]"
      "nimble.exe" = "nimble v0.20.1 compiled at 2026-02-23 03:37:42"
      "just.exe" = "just 1.46.0"
    }
    foreach ($tool in $script:ProductionSpecifications) {
      foreach ($executable in @(Get-CodeTracerOriginExecutableSpecifications `
          -ToolSpecification $tool `
          -PrimaryExecutable (Join-Path "C:\audit" $tool.CommandName))) {
        $sample = $officialVersionOutput[$executable.Name]
        Assert-True `
          ($sample -match ([string]$executable.VersionPattern) -and
            [Version]$matches.version -eq $executable.Version) `
          "The $($executable.Name) parser rejects its official version output."
      }
    }
    $source = Get-Content -LiteralPath $helper -Raw
    Assert-True (-not $source.Contains("choco.exe")) `
      "The origin-DAP toolchain helper still depends on Chocolatey."
  }

  Invoke-Test "uses a complete exact-version existing toolchain" {
    $caseRoot = New-TestDirectory "existing"
    $existing = New-FakeInstalledToolchain `
      -Root (Join-Path $caseRoot "tools") `
      -Specifications $script:ProductionSpecifications
    $existingPaths = @{}
    foreach ($tool in $existing.Tools) { $existingPaths[$tool.Name] = $tool.Path }
    $githubPath = Join-Path $caseRoot "github-path.txt"
    [IO.File]::WriteAllText($githubPath, "")
    $env:PATH = "original-path"
    $state = [PSCustomObject]@{ Provisioned = $false }
    $result = Ensure-CodeTracerOriginDapWindowsToolchain `
      -Destination (Join-Path $caseRoot "must-not-install") `
      -GitHubPathFile $githubPath `
      -Specifications $script:ProductionSpecifications `
      -CandidateProvider {
        param($specification)
        @($existingPaths[$specification.Name])
      } `
      -VersionReader {
        param($executableSpecification, $executable)
        [Version]$executableSpecification.Version
      } `
      -ProvisionToolchain {
        $state.Provisioned = $true
        throw "provisioning must not run"
      }
    Assert-True (-not $state.Provisioned) `
      "An exact existing toolchain triggered provisioning."
    Assert-True ($result.Tools.Count -eq 3) `
      "Existing-tool discovery did not return all three tools."
    $expectedEntries = @($existing.PathEntries)
    Assert-True `
      (($result.PathEntries -join "`0") -ceq ($expectedEntries -join "`0")) `
      "Existing tool directories were not preserved in canonical order."
    Assert-True `
      ($env:PATH -ceq (($expectedEntries -join [IO.Path]::PathSeparator) +
        [IO.Path]::PathSeparator + "original-path")) `
      "Existing tool directories were not prepended to process PATH."
    Assert-True `
      ((@(Get-Content -LiteralPath $githubPath) -join "`0") -ceq
        ($expectedEntries -join "`0")) `
      "Existing tool directories were not persisted to GITHUB_PATH."
  }

  foreach ($mode in @("partial", "old", "malformed")) {
    Invoke-Test "replaces a $mode existing toolchain with the verified bundle" {
      $caseRoot = New-TestDirectory "existing-$mode"
      $existingRoot = Join-Path $caseRoot "existing"
      $existing = New-FakeInstalledToolchain `
        -Root $existingRoot `
        -Specifications $script:ProductionSpecifications
      $existingPaths = @{}
      foreach ($tool in $existing.Tools) { $existingPaths[$tool.Name] = $tool.Path }
      if ($mode -ceq "partial") {
        Remove-Item -LiteralPath (
          Join-Path (Split-Path -Parent $existingPaths["capnp"]) "capnpc-c++.exe"
        ) -Force
      }
      $destination = Join-Path $caseRoot "provisioned"
      $githubPath = Join-Path $caseRoot "github-path.txt"
      [IO.File]::WriteAllText($githubPath, "")
      $state = [PSCustomObject]@{ Provisioned = 0 }
      $result = Ensure-CodeTracerOriginDapWindowsToolchain `
        -Destination $destination `
        -GitHubPathFile $githubPath `
        -Specifications $script:ProductionSpecifications `
        -CandidateProvider {
          param($specification)
          @($existingPaths[$specification.Name])
        } `
        -VersionReader {
          param($executableSpecification, $executable)
          if ($executable.StartsWith($existingRoot) -and
              $mode -ceq "old" -and
              $executableSpecification.Name -ceq "nim.exe") {
            return [Version]"2.2.7"
          }
          if ($executable.StartsWith($existingRoot) -and
              $mode -ceq "malformed" -and
              $executableSpecification.Name -ceq "nimble.exe") {
            return $null
          }
          return [Version]$executableSpecification.Version
        } `
        -ProvisionToolchain {
          param($requestedDestination, $specifications, $versionReader)
          $state.Provisioned += 1
          New-FakeInstalledToolchain `
            -Root $requestedDestination `
            -Specifications $specifications
        }
      Assert-True ($state.Provisioned -eq 1) `
        "A $mode existing toolchain was accepted instead of replaced."
      Assert-True ($result.Tools.Count -eq 3) `
        "Replacement for a $mode toolchain omitted a required tool."
      Assert-True `
        (@($result.Tools | Where-Object { -not $_.Path.StartsWith($destination) }).Count -eq 0) `
        "Replacement for a $mode toolchain retained an unverified executable."
    }
  }

  Invoke-Test "provisions and activates all three complete verified archives" {
    $caseRoot = New-TestDirectory "provision-success"
    $destination = Join-Path $caseRoot "toolchain"
    $specifications = @(Get-TestSpecifications)
    $state = [PSCustomObject]@{ Downloads = 0; Extractions = 0 }
    $result = Install-CodeTracerOriginToolchain `
      -Destination $destination `
      -Specifications $specifications `
      -DownloadFile {
        param($specification, $path)
        $state.Downloads += 1
        [IO.File]::WriteAllBytes($path, $script:AssetBytes[$specification.Name])
      } `
      -ExtractArchive {
        param($specification, $archive, $root)
        $state.Extractions += 1
        New-FakeExtractedLayout -ExtractRoot $root -Specification $specification
      } `
      -VersionReader {
        param($executableSpecification, $executable)
        [Version]$executableSpecification.Version
      }
    Assert-True ($state.Downloads -eq 3) `
      "The three pinned archives were not each downloaded exactly once."
    Assert-True ($state.Extractions -eq 3) `
      "The three verified archives were not each extracted exactly once."
    Assert-True ($result.Tools.Count -eq 3) `
      "Provisioning did not return all three verified tools."
    foreach ($tool in $result.Tools) {
      $specification = $specifications |
        Where-Object { $_.Name -ceq $tool.Name } |
        Select-Object -First 1
      Assert-True `
        -Condition (Test-CodeTracerOriginExecutableSet `
          -ToolSpecification $specification `
          -PrimaryExecutable $tool.Path `
          -VersionReader {
            param($executableSpecification, $executable)
            [Version]$executableSpecification.Version
          }) `
        -Message "Provisioning did not activate the complete $($tool.Name) toolset."
    }
    Assert-True (@(Get-ChildItem -LiteralPath $caseRoot).Count -eq 1) `
      "Successful provisioning left downloads, staging, or backup state."
  }

  foreach ($target in $script:ProductionSpecifications) {
    Invoke-Test "rejects a wrong $($target.Name) digest before its extraction" {
      $caseRoot = New-TestDirectory "digest-$($target.Name)"
      $specifications = @(Get-TestSpecifications)
      $state = [PSCustomObject]@{ ExtractedTarget = $false }
      Assert-Throws -ExpectedMessage "$($target.Name) SHA256 mismatch" -Action {
        Install-CodeTracerOriginToolchain `
          -Destination (Join-Path $caseRoot "toolchain") `
          -Specifications $specifications `
          -DownloadFile {
            param($specification, $path)
            [IO.File]::WriteAllBytes($path, $script:AssetBytes[$specification.Name])
          } `
          -HashFile {
            param($path)
            if ((Split-Path -Leaf $path) -ceq $target.ArchiveName) {
              return "0" * 64
            }
            return Get-BytesSha256 -Bytes ([IO.File]::ReadAllBytes($path))
          } `
          -ExtractArchive {
            param($specification, $archive, $root)
            if ($specification.Name -ceq $target.Name) {
              $state.ExtractedTarget = $true
            }
            New-FakeExtractedLayout -ExtractRoot $root -Specification $specification
          } `
          -VersionReader {
            param($executableSpecification, $executable)
            [Version]$executableSpecification.Version
          } | Out-Null
      }
      Assert-True (-not $state.ExtractedTarget) `
        "The unverified $($target.Name) archive reached extraction."
      Assert-True (@(Get-ChildItem -LiteralPath $caseRoot).Count -eq 0) `
        "A $($target.Name) digest failure left partial state behind."
    }

    Invoke-Test "propagates a $($target.Name) download failure and cleans state" {
      $caseRoot = New-TestDirectory "download-$($target.Name)"
      $specifications = @(Get-TestSpecifications)
      Assert-Throws -ExpectedMessage "simulated $($target.Name) download failure" -Action {
        Install-CodeTracerOriginToolchain `
          -Destination (Join-Path $caseRoot "toolchain") `
          -Specifications $specifications `
          -DownloadFile {
            param($specification, $path)
            if ($specification.Name -ceq $target.Name) {
              throw "simulated $($target.Name) download failure"
            }
            [IO.File]::WriteAllBytes($path, $script:AssetBytes[$specification.Name])
          } `
          -ExtractArchive {
            param($specification, $archive, $root)
            New-FakeExtractedLayout -ExtractRoot $root -Specification $specification
          } `
          -VersionReader {
            param($executableSpecification, $executable)
            [Version]$executableSpecification.Version
          } | Out-Null
      }
      Assert-True (@(Get-ChildItem -LiteralPath $caseRoot).Count -eq 0) `
        "A $($target.Name) download failure left partial state behind."
    }

    Invoke-Test "propagates a $($target.Name) extraction failure and preserves the install" {
      $caseRoot = New-TestDirectory "extract-$($target.Name)"
      $destination = Join-Path $caseRoot "toolchain"
      New-Item -ItemType Directory -Path $destination | Out-Null
      $marker = Join-Path $destination "known-good-marker"
      [IO.File]::WriteAllText($marker, "keep")
      $specifications = @(Get-TestSpecifications)
      Assert-Throws -ExpectedMessage "simulated $($target.Name) extraction failure" -Action {
        Install-CodeTracerOriginToolchain `
          -Destination $destination `
          -Specifications $specifications `
          -DownloadFile {
            param($specification, $path)
            [IO.File]::WriteAllBytes($path, $script:AssetBytes[$specification.Name])
          } `
          -ExtractArchive {
            param($specification, $archive, $root)
            if ($specification.Name -ceq $target.Name) {
              throw "simulated $($target.Name) extraction failure"
            }
            New-FakeExtractedLayout -ExtractRoot $root -Specification $specification
          } `
          -VersionReader {
            param($executableSpecification, $executable)
            [Version]$executableSpecification.Version
          } | Out-Null
      }
      Assert-True (Test-Path -LiteralPath $marker -PathType Leaf) `
        "A $($target.Name) extraction failure replaced the known-good install."
      Assert-True (@(Get-ChildItem -LiteralPath $caseRoot).Count -eq 1) `
        "A $($target.Name) extraction failure left staging or backup state."
    }
  }

  foreach ($targetTool in $script:ProductionSpecifications) {
    $targetExecutables = @(
      [PSCustomObject]@{ Name = $targetTool.CommandName }
    )
    foreach ($companion in @($targetTool.CompanionExecutables)) {
      $targetExecutables += [PSCustomObject]@{ Name = $companion.Name }
    }
    foreach ($targetExecutable in $targetExecutables) {
      Invoke-Test "rejects an archive missing $($targetExecutable.Name)" {
        $caseRoot = New-TestDirectory "layout-$($targetTool.Name)-$($targetExecutable.Name)"
        $specifications = @(Get-TestSpecifications)
        Assert-Throws -ExpectedMessage "$($targetTool.Name) archive did not contain" -Action {
          Install-CodeTracerOriginToolchain `
            -Destination (Join-Path $caseRoot "toolchain") `
            -Specifications $specifications `
            -DownloadFile {
              param($specification, $path)
              [IO.File]::WriteAllBytes($path, $script:AssetBytes[$specification.Name])
            } `
            -ExtractArchive {
              param($specification, $archive, $root)
              New-FakeExtractedLayout -ExtractRoot $root -Specification $specification
              if ($specification.Name -ceq $targetTool.Name) {
                Remove-FakeExtractedExecutable `
                  -ExtractRoot $root `
                  -ToolSpecification $specification `
                  -ExecutableName $targetExecutable.Name
              }
            } `
            -VersionReader {
              param($executableSpecification, $executable)
              [Version]$executableSpecification.Version
            } | Out-Null
        }
        Assert-True (@(Get-ChildItem -LiteralPath $caseRoot).Count -eq 0) `
          "Missing $($targetExecutable.Name) left partial state behind."
      }

      Invoke-Test "rejects malformed or old $($targetExecutable.Name)" {
        $caseRoot = New-TestDirectory "version-$($targetTool.Name)-$($targetExecutable.Name)"
        $destination = Join-Path $caseRoot "toolchain"
        New-Item -ItemType Directory -Path $destination | Out-Null
        $marker = Join-Path $destination "known-good-marker"
        [IO.File]::WriteAllText($marker, "keep")
        $specifications = @(Get-TestSpecifications)
        Assert-Throws -ExpectedMessage "$($targetExecutable.Name) reported version unparseable" -Action {
          Install-CodeTracerOriginToolchain `
            -Destination $destination `
            -Specifications $specifications `
            -DownloadFile {
              param($specification, $path)
              [IO.File]::WriteAllBytes($path, $script:AssetBytes[$specification.Name])
            } `
            -ExtractArchive {
              param($specification, $archive, $root)
              New-FakeExtractedLayout -ExtractRoot $root -Specification $specification
            } `
            -VersionReader {
              param($executableSpecification, $executable)
              if ($executableSpecification.Name -ceq $targetExecutable.Name) {
                return $null
              }
              return [Version]$executableSpecification.Version
            } | Out-Null
        }
        Assert-True (Test-Path -LiteralPath $marker -PathType Leaf) `
          "Malformed $($targetExecutable.Name) replaced the known-good install."
        Assert-True (@(Get-ChildItem -LiteralPath $caseRoot).Count -eq 1) `
          "Malformed $($targetExecutable.Name) left partial state behind."
      }
    }
  }

  Invoke-Test "restores an existing install after partial activation failure" {
    $caseRoot = New-TestDirectory "activation-failure"
    $destination = Join-Path $caseRoot "toolchain"
    New-Item -ItemType Directory -Path $destination | Out-Null
    $marker = Join-Path $destination "known-good-marker"
    [IO.File]::WriteAllText($marker, "keep")
    $specifications = @(Get-TestSpecifications)
    Assert-Throws -ExpectedMessage "simulated activation failure" -Action {
      Install-CodeTracerOriginToolchain `
        -Destination $destination `
        -Specifications $specifications `
        -DownloadFile {
          param($specification, $path)
          [IO.File]::WriteAllBytes($path, $script:AssetBytes[$specification.Name])
        } `
        -ExtractArchive {
          param($specification, $archive, $root)
          New-FakeExtractedLayout -ExtractRoot $root -Specification $specification
        } `
        -VersionReader {
          param($executableSpecification, $executable)
          [Version]$executableSpecification.Version
        } `
        -ActivateInstallation {
          param($staging, $activatedDestination)
          Move-Item -LiteralPath $staging -Destination $activatedDestination
          [IO.File]::WriteAllText(
            (Join-Path $activatedDestination "partial-activation"),
            "remove"
          )
          throw "simulated activation failure"
        } | Out-Null
    }
    Assert-True (Test-Path -LiteralPath $marker -PathType Leaf) `
      "Activation failure did not restore the known-good install."
    Assert-True (-not (Test-Path -LiteralPath (
        Join-Path $destination "partial-activation"
      ))) "Activation rollback retained partially activated content."
    Assert-True (@(Get-ChildItem -LiteralPath $caseRoot).Count -eq 1) `
      "Activation failure left staging or backup state behind."
  }

  Invoke-Test "replaces an existing install only after complete verification" {
    $caseRoot = New-TestDirectory "replace-success"
    $destination = Join-Path $caseRoot "toolchain"
    New-Item -ItemType Directory -Path $destination | Out-Null
    $oldMarker = Join-Path $destination "old-marker"
    [IO.File]::WriteAllText($oldMarker, "old")
    $specifications = @(Get-TestSpecifications)
    $result = Install-CodeTracerOriginToolchain `
      -Destination $destination `
      -Specifications $specifications `
      -DownloadFile {
        param($specification, $path)
        [IO.File]::WriteAllBytes($path, $script:AssetBytes[$specification.Name])
      } `
      -ExtractArchive {
        param($specification, $archive, $root)
        New-FakeExtractedLayout -ExtractRoot $root -Specification $specification
      } `
      -VersionReader {
        param($executableSpecification, $executable)
        [Version]$executableSpecification.Version
      }
    Assert-True (-not (Test-Path -LiteralPath $oldMarker)) `
      "The verified replacement retained the prior installation."
    Assert-True ($result.Tools.Count -eq 3) `
      "The verified replacement omitted a required tool."
    Assert-True (@(Get-ChildItem -LiteralPath $caseRoot).Count -eq 1) `
      "The verified replacement left downloads, staging, or backup state."
  }

  foreach ($pathFileState in @("existing", "absent")) {
    Invoke-Test "rolls back PATH and $pathFileState GITHUB_PATH on write failure" {
      $caseRoot = New-TestDirectory "path-rollback-$pathFileState"
      $entries = @()
      foreach ($name in @("capnp", "nim", "just")) {
        $directory = Join-Path $caseRoot $name
        New-Item -ItemType Directory -Path $directory | Out-Null
        $entries += $directory
      }
      $githubPath = Join-Path $caseRoot "github-path.txt"
      $originalBytes = [Text.Encoding]::UTF8.GetBytes("known-good`n")
      if ($pathFileState -ceq "existing") {
        [IO.File]::WriteAllBytes($githubPath, $originalBytes)
      }
      $env:PATH = "known-good-path"
      $toolchain = [PSCustomObject]@{ PathEntries = $entries }
      Assert-Throws -ExpectedMessage "simulated GITHUB_PATH failure" -Action {
        Add-CodeTracerOriginToolchainToPath `
          -Toolchain $toolchain `
          -GitHubPathFile $githubPath `
          -PersistEntries {
            param($pathFile, $pathEntries)
            Add-Content -LiteralPath $pathFile -Value $pathEntries[0]
            throw "simulated GITHUB_PATH failure"
          } | Out-Null
      }
      Assert-True ($env:PATH -ceq "known-good-path") `
        "A GITHUB_PATH failure did not restore process PATH."
      if ($pathFileState -ceq "existing") {
        Assert-True `
          (([IO.File]::ReadAllBytes($githubPath) -join ",") -ceq
            ($originalBytes -join ",")) `
          "A GITHUB_PATH failure did not restore prior bytes."
      }
      else {
        Assert-True (-not (Test-Path -LiteralPath $githubPath)) `
          "A failed first GITHUB_PATH write left a partial file."
      }
    }
  }

  Invoke-Test "fails closed for invalid GITHUB_PATH and PATH entries" {
    $caseRoot = New-TestDirectory "invalid-path-inputs"
    $entry = Join-Path $caseRoot "bin"
    New-Item -ItemType Directory -Path $entry | Out-Null
    $toolchain = [PSCustomObject]@{ PathEntries = @($entry) }
    $env:PATH = "unchanged-path"
    Assert-Throws -ExpectedMessage "GITHUB_PATH is unavailable" -Action {
      Add-CodeTracerOriginToolchainToPath `
        -Toolchain $toolchain `
        -GitHubPathFile "" | Out-Null
    }
    $directoryInsteadOfFile = Join-Path $caseRoot "github-path-directory"
    New-Item -ItemType Directory -Path $directoryInsteadOfFile | Out-Null
    Assert-Throws -ExpectedMessage "points to a directory" -Action {
      Add-CodeTracerOriginToolchainToPath `
        -Toolchain $toolchain `
        -GitHubPathFile $directoryInsteadOfFile | Out-Null
    }
    $githubPath = Join-Path $caseRoot "github-path.txt"
    Assert-Throws -ExpectedMessage "is not a directory" -Action {
      Add-CodeTracerOriginToolchainToPath `
        -Toolchain ([PSCustomObject]@{ PathEntries = @(
          (Join-Path $caseRoot "missing")
        ) }) `
        -GitHubPathFile $githubPath | Out-Null
    }
    Assert-Throws -ExpectedMessage "contains a newline" -Action {
      Add-CodeTracerOriginToolchainToPath `
        -Toolchain ([PSCustomObject]@{ PathEntries = @("$entry`npoison") }) `
        -GitHubPathFile $githubPath | Out-Null
    }
    Assert-True ($env:PATH -ceq "unchanged-path") `
      "Invalid path input mutated process PATH."
    Assert-True (-not (Test-Path -LiteralPath $githubPath)) `
      "Invalid path input created GITHUB_PATH."
  }
}
finally {
  $env:PATH = $savedPath
  Remove-Item `
    -LiteralPath $script:TestRoot `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue
}

if ($script:Passed -ne 32) {
  throw "Expected 32 origin-DAP toolchain tests, but $($script:Passed) passed."
}
Write-Host "Origin-DAP Windows toolchain contract tests passed: 32/32"
