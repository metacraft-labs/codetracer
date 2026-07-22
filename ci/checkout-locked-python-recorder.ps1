[CmdletBinding()]
param(
  [string]$Revision,
  [string]$Destination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:PythonRecorderUrl =
  "https://github.com/metacraft-labs/codetracer-python-recorder.git"
$script:ProtectedGitEnvironment = @(
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

function Remove-ProcessEnvironmentVariables {
  param([string[]]$Names)

  foreach ($name in $Names) {
    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
  }
}

function Remove-ProcessGitConfigEnvironment {
  Remove-Item -LiteralPath Env:GIT_CONFIG_COUNT -ErrorAction SilentlyContinue
  Get-ChildItem Env: | Where-Object {
    $_.Name -cmatch '^GIT_CONFIG_(KEY|VALUE)_[0-9]+$'
  } | ForEach-Object {
    Remove-Item -LiteralPath "Env:$($_.Name)" -ErrorAction SilentlyContinue
  }
}

function Get-RedactedGitOutput {
  param(
    [AllowEmptyString()]
    [string]$Output,
    [AllowEmptyString()]
    [string]$EncodedCredential
  )

  $redacted = $Output -replace `
    '(?i)(authorization:\s*basic\s+)[a-z0-9+/=]+', '${1}[REDACTED]'
  if ($EncodedCredential) {
    $redacted = $redacted.Replace($EncodedCredential, "[REDACTED]")
  }
  return $redacted
}

function Invoke-RecorderGit {
  param(
    [Parameter(Mandatory)]
    [string]$GitCommand,
    [Parameter(Mandatory)]
    [string[]]$Arguments,
    [AllowEmptyString()]
    [string]$EncodedCredential = ""
  )

  $output = & $GitCommand @Arguments 2>&1 | Out-String
  $status = $LASTEXITCODE
  if ($null -eq $status) {
    $status = if ($?) { 0 } else { 1 }
  }
  if ($status -ne 0) {
    $safeOutput = Get-RedactedGitOutput `
      -Output $output `
      -EncodedCredential $EncodedCredential
    throw "Git failed while preparing the locked Python recorder (exit $status).`n$safeOutput"
  }
  return $output.TrimEnd()
}

<#
.SYNOPSIS
Fetches the exact locked Python recorder revision into a fresh adjacent checkout.

.DESCRIPTION
Uses a process-only Git HTTP header for one fetch from a fixed, token-free
HTTPS origin. The raw token is read from SIBLING_TOKEN, removed before Git
starts, and never written to repository configuration or passed in subprocess
argv. A fresh repository and fixed Git argv keep the fetch destination outside
caller control.

.PARAMETER Revision
The lowercase 40-character commit ID recorded in CodeTracer's flake.lock.

.PARAMETER Destination
The checkout directory. Any existing directory is removed before fetching.

.PARAMETER GitCommand
An injectable Git executable used by the behavioral security test.
#>
function Invoke-LockedPythonRecorderCheckout {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Revision,
    [Parameter(Mandatory)]
    [string]$Destination,
    [string]$GitCommand = "git"
  )

  $encodedCredential = ""
  try {
    if ($Revision -cnotmatch '^[0-9a-f]{40}$') {
      throw "The locked Python recorder revision must be a 40-character lowercase SHA."
    }
    if ([string]::IsNullOrWhiteSpace($Destination)) {
      throw "The locked Python recorder destination must not be empty."
    }
    if ([string]::IsNullOrWhiteSpace($env:SIBLING_TOKEN)) {
      throw "The Python recorder checkout token is unavailable."
    }

    # Ignore inherited Git configuration, repository indirection, tracing and
    # every interactive credential path. These settings protect all repository
    # setup commands. In particular, remove any ambient numbered process config
    # before the first Git child. The HTTP header is installed only for the single
    # network fetch below. Git documents the process-only config variables at
    # https://git-scm.com/docs/git-config and the credential controls at
    # https://git-scm.com/docs/gitcredentials.
    Remove-ProcessGitConfigEnvironment
    Remove-ProcessEnvironmentVariables $script:ProtectedGitEnvironment
    $env:GIT_TERMINAL_PROMPT = "0"
    $env:GIT_ASKPASS = ""
    $env:SSH_ASKPASS = ""
    $env:GCM_INTERACTIVE = "Never"
    $env:GIT_CONFIG_GLOBAL = if ($IsWindows) { "NUL" } else { "/dev/null" }
    $env:GIT_CONFIG_SYSTEM = if ($IsWindows) { "NUL" } else { "/dev/null" }
    $env:GIT_CONFIG_NOSYSTEM = "1"
    $env:GIT_ALLOW_PROTOCOL = "https"
    $env:GIT_PROTOCOL_FROM_USER = "0"

    $encodedCredential = [Convert]::ToBase64String(
      [Text.Encoding]::ASCII.GetBytes("x-access-token:$env:SIBLING_TOKEN")
    )
    Remove-Item -LiteralPath Env:SIBLING_TOKEN -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Destination) {
      Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    Invoke-RecorderGit -GitCommand $GitCommand -Arguments @(
      "-C", $Destination, "init"
    ) | Out-Null
    Invoke-RecorderGit -GitCommand $GitCommand -Arguments @(
      "-C", $Destination, "remote", "add", "origin", $script:PythonRecorderUrl
    ) | Out-Null

    $env:GIT_CONFIG_COUNT = "6"
    $env:GIT_CONFIG_KEY_0 =
      "http.$($script:PythonRecorderUrl).extraHeader"
    $env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic $encodedCredential"
    $env:GIT_CONFIG_KEY_1 = "credential.helper"
    $env:GIT_CONFIG_VALUE_1 = ""
    $env:GIT_CONFIG_KEY_2 = "core.askPass"
    $env:GIT_CONFIG_VALUE_2 = ""
    $env:GIT_CONFIG_KEY_3 = "http.followRedirects"
    $env:GIT_CONFIG_VALUE_3 = "false"
    $env:GIT_CONFIG_KEY_4 = "protocol.allow"
    $env:GIT_CONFIG_VALUE_4 = "never"
    $env:GIT_CONFIG_KEY_5 = "protocol.https.allow"
    $env:GIT_CONFIG_VALUE_5 = "always"
    try {
      Invoke-RecorderGit -GitCommand $GitCommand -Arguments @(
        "-C", $Destination,
        "fetch", "--depth=1", "origin", $Revision
      ) -EncodedCredential $encodedCredential | Out-Null
    }
    finally {
      Remove-ProcessGitConfigEnvironment
    }

    Invoke-RecorderGit -GitCommand $GitCommand -Arguments @(
      "-C", $Destination, "checkout", "--detach", "FETCH_HEAD"
    ) | Out-Null
    $actualRevision = Invoke-RecorderGit -GitCommand $GitCommand -Arguments @(
      "-C", $Destination, "rev-parse", "HEAD"
    )
    if ($actualRevision.Trim() -cne $Revision) {
      throw "The adjacent Python recorder checkout does not match flake.lock."
    }
  }
  finally {
    Remove-Item -LiteralPath Env:SIBLING_TOKEN -ErrorAction SilentlyContinue
    Remove-ProcessGitConfigEnvironment
    Remove-ProcessEnvironmentVariables $script:ProtectedGitEnvironment
    $encodedCredential = ""
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  Invoke-LockedPythonRecorderCheckout `
    -Revision $Revision `
    -Destination $Destination
}
