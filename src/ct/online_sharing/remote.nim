## Remote sharing commands.
##
## Previously this module was a thin wrapper that shelled out to the external
## ``ct-remote`` binary. Now the functionality is implemented natively in Nim.
## The ``runCtRemote`` proc is kept for the deprecated ``ct remote`` passthrough.

import
  std/[ os, osproc, options, sequtils, strutils ],
  ../../common/[ paths ],
  ../cli/[ logging ],
  remote_config, authenticate as auth_module, desktop_capability

proc runCtRemote*(args: seq[string]): int {.deprecated: "Use native commands instead".} =
  ## Deprecated: shells out to the external ct-remote binary.
  ## Kept only for the ``ct remote <args>`` escape hatch.
  var execPath = ctRemoteExe
  if not fileExists(execPath):
    execPath = findExe("ct-remote")

  if execPath.len == 0 or not fileExists(execPath):
    echo "ct-remote is no longer required. Use native commands instead:"
    echo "  ct upload, ct download, ct login, ct set-default-org,"
    echo "  ct get-default-org, ct activate, ct check-license"
    return 1

  try:
    let fullArgs = args.concat(@["--binary-name", "ct remote"])
    var options = {poParentStreams}
    if getEnv("CODETRACER_DEBUG_CT_REMOTE", "0") == "1":
      options.incl(poEchoCmd)
    let process = startProcess(execPath, args = fullArgs, options = options)
    result = waitForExit(process)
  except CatchableError as err:
    echo "Failed to launch ct-remote (" & execPath & "): " & err.msg
    result = 1

proc loginCommand*(defaultOrg: Option[string], baseUrl: Option[string] = none(string)) =
  ## Authenticate, by whichever flow this host can actually run.
  ##
  ## `CodeTracer-Identity.md` §5: loopback redirect by default, device
  ## authorization grant where loopback CANNOT run. The choice is a
  ## MEASUREMENT — `probeDesktopCapabilities` binds a real socket and looks for
  ## a real browser — and there is deliberately no flag, environment variable
  ## or config key that can override it. §5.3 gives the reason: an environment
  ## variable that changes which authentication path runs is one line from one
  ## that disables authentication.
  ##
  ## WHAT THIS FIXES TODAY, independently of the device grant. Before this,
  ## `ct login` over SSH or in a container opened a browser that could not
  ## appear and then BLOCKED on a loopback socket no browser could ever reach —
  ## a hang with no diagnosis. It now says which half of the measurement
  ## failed, before doing anything.
  let probe = probeDesktopCapabilities()
  var capability = DesktopCapability(canBindLoopback: false,
                                     canLaunchBrowser: false)
  if not probe.determinedCapability(capability):
    # "We did not check" is not "it does not work", and defaulting to the
    # browser flow here is exactly what would strand a headless user.
    echo "Cannot determine how to sign in on this host: " &
      probe.verdictReason() & "."
    echo "Refusing to guess: the browser flow would block on a callback that"
    echo "may never arrive. Please report this, with your platform."
    quit(1)

  case selectFlow(capability)
  of sfDeviceGrant:
    echo "This host cannot use the browser redirect sign-in: " &
      probe.verdictReason() & "."
    echo "The device authorization grant is the flow for exactly this case."
    echo "Its client is implemented (RFC 8628) but the authorization server"
    echo "endpoint does not exist yet — CodeTracer-Identity ID2. Until it does,"
    echo "sign in on a machine with a browser and copy the remote config over."
    quit(1)
  of sfLoopbackRedirect:
    discard

  let remoteConfig = initRemoteConfig()
  let resolvedBaseUrl = remoteConfig.resolveBaseRemoteUrl(
    baseUrl.get(""))
  try:
    auth_module.authenticate(remoteConfig, resolvedBaseUrl)
  except CatchableError as e:
    echo "Login failed: " & e.msg
    quit(1)
  if defaultOrg.isSome:
    remoteConfig.saveConfigValue(DefaultOrganizationKey, defaultOrg.get)
    echo "Default organization set to: " & defaultOrg.get

proc setDefaultOrg*(newOrg: string) =
  ## Set the default organization in the remote config file.
  let remoteConfig = initRemoteConfig()
  remoteConfig.saveConfigValue(DefaultOrganizationKey, newOrg)
  echo "Default organization set to: " & newOrg

proc getDefaultOrg*() =
  ## Print the current default organization from the remote config file.
  let remoteConfig = initRemoteConfig()
  let org = remoteConfig.readConfigValue(DefaultOrganizationKey)
  if org.len == 0:
    echo "No default organization set. Use 'ct set-default-org <name>' to set one."
  else:
    echo org
