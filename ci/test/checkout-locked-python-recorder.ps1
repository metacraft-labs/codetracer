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

function Get-StringSha256 {
  param([string]$Value)

  $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
  $hash = [Security.Cryptography.SHA256]::HashData($bytes)
  return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Read-FakeGitLog {
  param([string]$Path)

  return @(Get-Content -LiteralPath $Path | ForEach-Object {
    $_ | ConvertFrom-Json
  })
}

function Assert-EnvironmentClean {
  $names = @(
    "SIBLING_TOKEN",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_KEY_0",
    "GIT_CONFIG_VALUE_0",
    "GIT_CONFIG_KEY_1",
    "GIT_CONFIG_VALUE_1",
    "GIT_CONFIG_KEY_2",
    "GIT_CONFIG_VALUE_2",
    "GIT_CONFIG_KEY_3",
    "GIT_CONFIG_VALUE_3",
    "GIT_CONFIG_KEY_4",
    "GIT_CONFIG_VALUE_4",
    "GIT_CONFIG_KEY_5",
    "GIT_CONFIG_VALUE_5",
    "GIT_CONFIG_KEY_17",
    "GIT_CONFIG_VALUE_17",
    "GIT_TERMINAL_PROMPT",
    "GIT_ASKPASS",
    "SSH_ASKPASS",
    "GCM_INTERACTIVE",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_SYSTEM",
    "GIT_CONFIG_NOSYSTEM",
    "GIT_CONFIG_PARAMETERS",
    "GIT_EXEC_PATH",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_INDEX_FILE",
    "GIT_ALLOW_PROTOCOL",
    "GIT_PROTOCOL_FROM_USER",
    "GIT_PROXY_COMMAND",
    "GIT_TRACE",
    "GIT_TRACE_CURL",
    "GIT_TRACE_CURL_NO_DATA",
    "GIT_TRACE2",
    "GIT_TRACE2_EVENT",
    "GIT_TRACE2_PERF"
  )
  foreach ($name in $names) {
    Assert-True `
      -Condition (-not (Test-Path -LiteralPath "Env:$name")) `
      -Message "Authentication environment variable $name was not cleaned up."
  }
}

$helper = Join-Path $PSScriptRoot "..\checkout-locked-python-recorder.ps1"
. $helper

$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
  "codetracer-recorder-auth-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
  $fakeGitImplementation = Join-Path $testRoot "fake-git-impl.ps1"
  @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArguments)
$ErrorActionPreference = "Stop"

$header = $env:GIT_CONFIG_VALUE_0
$entry = [ordered]@{
  Arguments = @($GitArguments)
  ConfigCount = $env:GIT_CONFIG_COUNT
  ConfigKeys = @(
    $env:GIT_CONFIG_KEY_0,
    $env:GIT_CONFIG_KEY_1,
    $env:GIT_CONFIG_KEY_2,
    $env:GIT_CONFIG_KEY_3,
    $env:GIT_CONFIG_KEY_4,
    $env:GIT_CONFIG_KEY_5
  )
  NonHeaderConfigValues = @(
    $env:GIT_CONFIG_VALUE_1,
    $env:GIT_CONFIG_VALUE_2,
    $env:GIT_CONFIG_VALUE_3,
    $env:GIT_CONFIG_VALUE_4,
    $env:GIT_CONFIG_VALUE_5
  )
  HeaderSha256 = if ($header) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($header)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    [Convert]::ToHexString($hash).ToLowerInvariant()
  } else { "" }
  HeaderHasBasicPrefix = [bool]($header -cmatch '^AUTHORIZATION: basic [A-Za-z0-9+/=]+$')
  RawTokenPresent = [bool]$env:SIBLING_TOKEN
  GitTerminalPrompt = $env:GIT_TERMINAL_PROMPT
  GitAskPass = $env:GIT_ASKPASS
  SshAskPass = $env:SSH_ASKPASS
  GcmInteractive = $env:GCM_INTERACTIVE
  GitConfigGlobal = $env:GIT_CONFIG_GLOBAL
  GitConfigSystem = $env:GIT_CONFIG_SYSTEM
  GitConfigNoSystem = $env:GIT_CONFIG_NOSYSTEM
  GitConfigParameters = $env:GIT_CONFIG_PARAMETERS
  GitExecPath = $env:GIT_EXEC_PATH
  GitAlternateObjects = $env:GIT_ALTERNATE_OBJECT_DIRECTORIES
  GitAllowProtocol = $env:GIT_ALLOW_PROTOCOL
  GitProtocolFromUser = $env:GIT_PROTOCOL_FROM_USER
  GitProxyCommand = $env:GIT_PROXY_COMMAND
  GitTrace = $env:GIT_TRACE
  GitTraceCurl = $env:GIT_TRACE_CURL
}
($entry | ConvertTo-Json -Compress) | Add-Content -LiteralPath $env:FAKE_GIT_LOG

$operation = if ($GitArguments.Count -ge 3) { $GitArguments[2] } else { "" }
if ($operation -eq "fetch" -and $env:FAKE_GIT_FAIL_FETCH -eq "1") {
  [Console]::Error.WriteLine("fatal: $header")
  exit 73
}
if ($operation -eq "rev-parse") {
  if ($env:FAKE_GIT_HEAD) { $env:FAKE_GIT_HEAD } else { $env:FAKE_GIT_REVISION }
}
exit 0
'@ | Set-Content -LiteralPath $fakeGitImplementation

  if ($IsWindows) {
    $fakeGit = Join-Path $testRoot "fake-git.cmd"
    @'
@pwsh -NoLogo -NoProfile -File "%~dp0fake-git-impl.ps1" %*
@exit /b %ERRORLEVEL%
'@ | Set-Content -LiteralPath $fakeGit
  }
  else {
    $fakeGit = Join-Path $testRoot "fake-git"
    @'
#!/usr/bin/env bash
exec pwsh -NoLogo -NoProfile -File "$(dirname "$0")/fake-git-impl.ps1" "$@"
'@ | Set-Content -LiteralPath $fakeGit -NoNewline
    & chmod +x $fakeGit
    if ($LASTEXITCODE -ne 0) {
      throw "Could not make the fake Git transport executable."
    }
  }

  $revision = "0123456789abcdef0123456789abcdef01234567"
  $token = "ct-recorder-token-$([Guid]::NewGuid().ToString('N'))"
  $basic = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("x-access-token:$token")
  )
  $header = "AUTHORIZATION: basic $basic"
  $ambientToken = "ambient-token-$([Guid]::NewGuid().ToString('N'))"
  $ambientBasic = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("x-access-token:$ambientToken")
  )
  $log = Join-Path $testRoot "success.jsonl"
  $destination = Join-Path $testRoot "recorder"
  New-Item -ItemType Directory -Path $destination | Out-Null
  Set-Content -LiteralPath (Join-Path $destination "stale-cache-marker") -Value "stale"
  New-Item -ItemType Directory -Path (Join-Path $destination ".git") | Out-Null
  @'
[remote "origin"]
  url = file:///hostile/local-recorder
'@ | Set-Content -LiteralPath (Join-Path $destination ".git\config")

  $env:SIBLING_TOKEN = $token
  $env:FAKE_GIT_LOG = $log
  $env:FAKE_GIT_REVISION = $revision
  $env:GIT_CONFIG_COUNT = "18"
  $env:GIT_CONFIG_KEY_0 = "http.https://github.com/.extraHeader"
  $env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic $ambientBasic"
  $env:GIT_CONFIG_KEY_1 = "http.followRedirects"
  $env:GIT_CONFIG_VALUE_1 = "true"
  $env:GIT_CONFIG_KEY_2 = "protocol.file.allow"
  $env:GIT_CONFIG_VALUE_2 = "always"
  $env:GIT_CONFIG_KEY_17 = "url.ext::hostile.insteadOf"
  $env:GIT_CONFIG_VALUE_17 = "https://github.com/"
  $env:GIT_CONFIG_PARAMETERS =
    "'url.file:///hostile/rewrite/.insteadOf=https://github.com/' 'remote.origin.vcs=ext'"
  $env:GIT_EXEC_PATH = Join-Path $testRoot "hostile-git-exec"
  $env:GIT_ALTERNATE_OBJECT_DIRECTORIES = Join-Path $testRoot "hostile-objects"
  $env:GIT_ALLOW_PROTOCOL = "file:ext"
  $env:GIT_PROTOCOL_FROM_USER = "1"
  $env:GIT_PROXY_COMMAND = "hostile-proxy"
  $env:GIT_TRACE = Join-Path $testRoot "hostile-trace"
  $env:GIT_TRACE_CURL = "1"
  Invoke-LockedPythonRecorderCheckout `
    -Revision $revision `
    -Destination $destination `
    -GitCommand $fakeGit

  Assert-EnvironmentClean
  Assert-True `
    -Condition (-not (Test-Path -LiteralPath (Join-Path $destination "stale-cache-marker"))) `
    -Message "The helper reused pre-existing recorder state."
  Assert-True `
    -Condition (-not (Test-Path -LiteralPath (Join-Path $destination ".git\config"))) `
    -Message "The helper reused a substituted local recorder remote."

  $entries = Read-FakeGitLog $log
  Assert-True ($entries.Count -eq 5) "The helper did not run the exact five expected Git commands."
  $repositoryUrl = "https://github.com/metacraft-labs/codetracer-python-recorder.git"
  $expectedArguments = @(
    (@("-C", $destination, "init") -join "`0"),
    (@("-C", $destination, "remote", "add", "origin", $repositoryUrl) -join "`0"),
    (@("-C", $destination, "fetch", "--depth=1", "origin", $revision) -join "`0"),
    (@("-C", $destination, "checkout", "--detach", "FETCH_HEAD") -join "`0"),
    (@("-C", $destination, "rev-parse", "HEAD") -join "`0")
  )
  for ($index = 0; $index -lt $entries.Count; $index++) {
    Assert-True `
      -Condition (($entries[$index].Arguments -join "`0") -ceq $expectedArguments[$index]) `
      -Message "Unexpected Git argv or command ordering."
    Assert-True `
      -Condition (-not $entries[$index].RawTokenPresent) `
      -Message "The raw token reached a Git child process."
    Assert-True ($entries[$index].GitTerminalPrompt -ceq "0") "Git prompting was not disabled."
    Assert-True ($entries[$index].GcmInteractive -ceq "Never") "Git Credential Manager was not disabled."
    Assert-True ($entries[$index].GitConfigNoSystem -ceq "1") "System Git config was not blocked."
    $nullDevice = if ($IsWindows) { "NUL" } else { "/dev/null" }
    Assert-True ($entries[$index].GitConfigGlobal -ceq $nullDevice) `
      "Global Git config was not blocked."
    Assert-True ($entries[$index].GitConfigSystem -ceq $nullDevice) `
      "System Git config was not redirected to the null device."
    Assert-True ([string]::IsNullOrEmpty($entries[$index].GitConfigParameters)) `
      "Inherited process Git configuration reached a child."
    Assert-True ([string]::IsNullOrEmpty($entries[$index].GitExecPath)) `
      "An inherited Git executable path reached a child."
    Assert-True ([string]::IsNullOrEmpty($entries[$index].GitAlternateObjects)) `
      "An inherited Git object cache reached a child."
    Assert-True ($entries[$index].GitAllowProtocol -ceq "https") `
      "Git protocols were not restricted to HTTPS."
    Assert-True ($entries[$index].GitProtocolFromUser -ceq "0") `
      "Caller-selected Git protocols were not blocked."
    Assert-True ([string]::IsNullOrEmpty($entries[$index].GitProxyCommand)) `
      "An inherited remote helper reached a child."
    Assert-True ([string]::IsNullOrEmpty($entries[$index].GitTrace)) `
      "An inherited Git trace destination reached a child."
    Assert-True ([string]::IsNullOrEmpty($entries[$index].GitTraceCurl)) `
      "Inherited curl credential tracing reached a child."
    $argumentText = $entries[$index].Arguments -join "`n"
    Assert-True (-not $argumentText.Contains($token)) "The raw token entered Git argv."
    Assert-True (-not $argumentText.Contains($basic)) "The encoded token entered Git argv."
  }

  $fetch = $entries[2]
  Assert-True ($fetch.ConfigCount -ceq "6") "The fetch lacks process-only Git configuration."
  Assert-True `
    -Condition ($fetch.ConfigKeys[0] -ceq `
      "http.https://github.com/metacraft-labs/codetracer-python-recorder.git.extraHeader") `
    -Message "The HTTP header is not associated with the fixed recorder origin."
  Assert-True ($fetch.ConfigKeys[1] -ceq "credential.helper") "Credential helpers were not blocked."
  Assert-True ($fetch.ConfigKeys[2] -ceq "core.askPass") "Git askpass config was not blocked."
  Assert-True ($fetch.ConfigKeys[3] -ceq "http.followRedirects") "HTTP redirects were not controlled."
  Assert-True ($fetch.ConfigKeys[4] -ceq "protocol.allow") "Alternate Git protocols were not blocked."
  Assert-True ($fetch.ConfigKeys[5] -ceq "protocol.https.allow") "HTTPS was not explicitly allowed."
  Assert-True `
    -Condition (($fetch.NonHeaderConfigValues -join "`0") -ceq "`0`0false`0never`0always") `
    -Message "Fetch credential, redirect, or protocol defenses have unexpected values."
  Assert-True $fetch.HeaderHasBasicPrefix "The fetch did not receive the expected header form."
  Assert-True `
    -Condition ($fetch.HeaderSha256 -ceq (Get-StringSha256 $header)) `
    -Message "The fetch did not receive the expected credential via environment."
  foreach ($entry in @($entries[0], $entries[1], $entries[3], $entries[4])) {
    Assert-True `
      -Condition ([string]::IsNullOrEmpty($entry.ConfigCount)) `
      -Message "The HTTP credential outlived the single fetch."
  }

  # Only the fixed remote-add argv may contain a URL. A caller-controlled
  # userinfo, subpath, lookalike, alternate protocol, or helper URL therefore
  # cannot become the authenticated fetch target.
  foreach ($entry in $entries) {
    foreach ($argument in $entry.Arguments) {
      if ($argument -match '(^[a-zA-Z][a-zA-Z0-9+.-]*://)|(^ext::)|(@github\.com)') {
        Assert-True ($argument -ceq $repositoryUrl) `
          "A Git command requested a non-fixed recorder URL."
      }
    }
  }

  # A fetch failure must be redacted and clean every credential variable.
  $failureLog = Join-Path $testRoot "failure.jsonl"
  $env:SIBLING_TOKEN = $token
  $env:FAKE_GIT_LOG = $failureLog
  $env:FAKE_GIT_FAIL_FETCH = "1"
  $failureMessage = ""
  try {
    Invoke-LockedPythonRecorderCheckout `
      -Revision $revision `
      -Destination (Join-Path $testRoot "fetch-failure") `
      -GitCommand $fakeGit
    throw "The simulated fetch failure unexpectedly succeeded."
  }
  catch {
    $failureMessage = $_.Exception.Message
  }
  finally {
    Remove-Item Env:FAKE_GIT_FAIL_FETCH -ErrorAction SilentlyContinue
  }
  Assert-EnvironmentClean
  Assert-True ($failureMessage.Contains("[REDACTED]")) "Fetch failure output was not redacted."
  Assert-True (-not $failureMessage.Contains($token)) "A raw token leaked in failure output."
  Assert-True (-not $failureMessage.Contains($basic)) "An encoded token leaked in failure output."

  # Revision mismatch and invalid-lock failures remain strict.
  $env:SIBLING_TOKEN = $token
  $env:FAKE_GIT_LOG = Join-Path $testRoot "mismatch.jsonl"
  $env:FAKE_GIT_HEAD = "ffffffffffffffffffffffffffffffffffffffff"
  $mismatchFailed = $false
  try {
    Invoke-LockedPythonRecorderCheckout `
      -Revision $revision `
      -Destination (Join-Path $testRoot "mismatch") `
      -GitCommand $fakeGit
  }
  catch {
    $mismatchFailed = $_.Exception.Message.Contains("does not match flake.lock")
  }
  finally {
    Remove-Item Env:FAKE_GIT_HEAD -ErrorAction SilentlyContinue
  }
  Assert-True $mismatchFailed "The helper accepted a mismatched checkout revision."
  Assert-EnvironmentClean

  $env:SIBLING_TOKEN = $token
  $invalidRevisionFailed = $false
  try {
    Invoke-LockedPythonRecorderCheckout `
      -Revision "main" `
      -Destination (Join-Path $testRoot "invalid") `
      -GitCommand $fakeGit
  }
  catch {
    $invalidRevisionFailed = $_.Exception.Message.Contains("40-character lowercase SHA")
  }
  Assert-True $invalidRevisionFailed "The helper accepted a non-locked revision."
  Assert-EnvironmentClean

  $env:GIT_CONFIG_PARAMETERS = "'credential.helper=hostile-helper'"
  $missingTokenFailed = $false
  try {
    Invoke-LockedPythonRecorderCheckout `
      -Revision $revision `
      -Destination (Join-Path $testRoot "missing-token") `
      -GitCommand $fakeGit
  }
  catch {
    $missingTokenFailed = $_.Exception.Message.Contains("token is unavailable")
  }
  Assert-True $missingTokenFailed "The helper accepted a missing checkout token."
  Assert-EnvironmentClean

  # No test trace or checkout file may contain either credential form.
  foreach ($file in Get-ChildItem -LiteralPath $testRoot -File -Recurse) {
    $contents = Get-Content -LiteralPath $file.FullName -Raw
    Assert-True (-not $contents.Contains($token)) "A raw token was persisted to $($file.Name)."
    Assert-True (-not $contents.Contains($basic)) "An encoded token was persisted to $($file.Name)."
    Assert-True (-not $contents.Contains($ambientToken)) "Ambient credentials were persisted to $($file.Name)."
    Assert-True (-not $contents.Contains($ambientBasic)) "Encoded ambient credentials were persisted to $($file.Name)."
  }

  Write-Host "Locked Python recorder checkout security contract: PASS"
}
finally {
  Remove-Item Env:FAKE_GIT_LOG -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_GIT_REVISION -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_GIT_HEAD -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_GIT_FAIL_FETCH -ErrorAction SilentlyContinue
  Remove-Item Env:SIBLING_TOKEN -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
