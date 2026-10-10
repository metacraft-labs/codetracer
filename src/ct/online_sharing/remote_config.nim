## Configuration file handler for ct-remote functionality.
##
## Manages a simple key=value configuration file at
## ``~/.config/codetracer/remote.config`` (or ``%APPDATA%\codetracer\remote.config``
## on Windows). This is the same format and location used by the C# ct-remote
## binary, ensuring seamless migration for existing users.
##
## The file stores:
## - Bearer token from OAuth login
## - Default organization slug
## - Base remote URL override

import std/[os, strutils, uri]
import ../../common/ct_home

const
  BearerTokenKey* = "CodeTracer-Remote-BearerToken"
  DefaultOrganizationKey* = "CodeTracer-Default-Organization"
  RemoteUrlKey* = "CodeTracer-Base-Remote-Url"
  DefaultBaseRemoteUrl* = "https://api.codetracer.com"
    ## The API origin the client talks to when nothing overrides it: every
    ## ``/api/v1/*`` call and the ``/auth/desktop`` sign-in page `ct login`
    ## opens.
  DefaultShareBaseUrl* = "https://ide.codetracer.com"
    ## The user-facing origin share links are issued on when the API base is
    ## the default one.  The link is something a person opens in a browser,
    ## so it names the product's web address, which forwards share-link and
    ## API paths to the same service.  A deployment that overrides the API
    ## base has no separate web origin, so its links are issued on that base
    ## (see ``shareBaseUrlFor``).
  ConfigFileName = "remote.config"

type
  RemoteConfig* = object
    configFilePath*: string

proc defaultConfigDir(): string =
  ## Returns the platform-appropriate config directory for CodeTracer.
  ## The ``CODETRACER_REMOTE_CONFIG_DIR`` env var overrides the default,
  ## which is useful for testing. Otherwise uses ``XDG_CONFIG_HOME`` on Unix
  ## or ``%APPDATA%`` on Windows, matching the C# implementation.
  let envDir = getEnv("CODETRACER_REMOTE_CONFIG_DIR", "")
  if envDir.len > 0:
    return envDir
  # `$CODETRACER_HOME/config` relocates it with every other per-user location.
  let ctHomeConfig = ctHomeArea(chaConfig)
  if ctHomeConfig.len > 0:
    return ctHomeConfig
  when defined(windows):
    result = getEnv("APPDATA", getHomeDir() / "AppData" / "Roaming") / "codetracer"
  else:
    result = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config") / "codetracer"

proc initRemoteConfig*(configFilePath = ""): RemoteConfig =
  ## Create a RemoteConfig. If ``configFilePath`` is empty, uses the
  ## platform default (``~/.config/codetracer/remote.config``).
  ## The ``CODETRACER_REMOTE_CONFIG_DIR`` env var can override the directory.
  if configFilePath.len > 0:
    result.configFilePath = configFilePath
  else:
    result.configFilePath = defaultConfigDir() / ConfigFileName

proc configDir*(config: RemoteConfig): string =
  ## Returns the directory containing the config file.
  result = parentDir(config.configFilePath)

proc readConfigValue*(config: RemoteConfig, key: string): string =
  ## Reads a value from the config file by key. Returns empty string
  ## if the key is not found or the file doesn't exist.
  ## Key matching is case-insensitive, consistent with the C# implementation.
  result = ""
  if not fileExists(config.configFilePath):
    return
  try:
    for line in lines(config.configFilePath):
      let trimmed = line.strip()
      if trimmed.len == 0 or trimmed.startsWith("#"):
        continue
      let eqPos = trimmed.find('=')
      if eqPos > 0:
        let lineKey = trimmed[0 ..< eqPos]
        if lineKey.cmpIgnoreCase(key) == 0:
          result = trimmed[eqPos + 1 .. ^1]
          return
  except CatchableError:
    discard

proc saveConfigValue*(config: RemoteConfig, key, value: string,
                      overwrite = true) =
  ## Writes a key=value pair to the config file. If ``overwrite`` is true
  ## (default), replaces an existing key. If false, only writes if the key
  ## doesn't already exist.
  let dir = config.configDir()
  if not dirExists(dir):
    createDir(dir)

  var existingLines: seq[string] = @[]
  var found = false

  if fileExists(config.configFilePath):
    try:
      for line in lines(config.configFilePath):
        let trimmed = line.strip()
        let eqPos = trimmed.find('=')
        if eqPos > 0:
          let lineKey = trimmed[0 ..< eqPos]
          if lineKey.cmpIgnoreCase(key) == 0:
            found = true
            if overwrite:
              existingLines.add(key & "=" & value)
            else:
              existingLines.add(line)
            continue
        existingLines.add(line)
    except CatchableError:
      discard

  if not found:
    existingLines.add(key & "=" & value)

  writeFile(config.configFilePath, existingLines.join("\n") & "\n")

proc getBearerToken*(config: RemoteConfig, cliToken = ""): string =
  ## Returns the bearer token. Prefers the CLI-provided token, falls back
  ## to the stored config value. Raises ``ValueError`` if no token is available.
  result = if cliToken.len > 0: cliToken
           else: config.readConfigValue(BearerTokenKey)
  if result.len == 0:
    raise newException(ValueError,
      "No bearer token found. Please login first with: ct login")

proc resolveBaseRemoteUrl*(config: RemoteConfig, cliBaseUrl = ""): string =
  ## Returns the base remote URL. Priority:
  ## 1. CLI-provided ``--base-url``
  ## 2. Environment variable ``CODETRACER_REMOTE_BASE_URL``
  ## 3. Stored config value
  ## 4. Default (``DefaultBaseRemoteUrl``, https://api.codetracer.com)
  if cliBaseUrl.len > 0:
    return cliBaseUrl
  let envUrl = getEnv("CODETRACER_REMOTE_BASE_URL", "")
  if envUrl.len > 0:
    return envUrl
  let configUrl = config.readConfigValue(RemoteUrlKey)
  if configUrl.len > 0:
    return configUrl
  return DefaultBaseRemoteUrl

proc normalizedOrigin(url: string): string =
  ## ``scheme://host[:port]`` lower-cased, with any path or trailing slash
  ## dropped, so ``https://API.codetracer.com/`` compares equal to the
  ## default.  Returns the stripped input when it does not parse as a URL.
  let trimmed = url.strip().strip(leading = false, chars = {'/'})
  let parsed = parseUri(trimmed)
  if parsed.scheme.len == 0 or parsed.hostname.len == 0:
    return trimmed.toLowerAscii()
  result = parsed.scheme.toLowerAscii() & "://" & parsed.hostname.toLowerAscii()
  if parsed.port.len > 0:
    result &= ":" & parsed.port
  if parsed.path.strip(chars = {'/'}).len > 0:
    result &= "/" & parsed.path.strip(chars = {'/'})

proc isDefaultBaseRemoteUrl*(baseUrl: string): bool =
  ## Whether ``baseUrl`` is the default API origin, ignoring case and a
  ## trailing slash.
  normalizedOrigin(baseUrl) == normalizedOrigin(DefaultBaseRemoteUrl)

proc shareBaseUrlFor*(apiBaseUrl: string): string =
  ## The origin a share link is issued on, given the resolved API base.
  ##
  ## * The default API base issues links on ``DefaultShareBaseUrl``, the
  ##   product's web address.
  ## * Any other base — ``--base-url``, ``CODETRACER_REMOTE_BASE_URL`` or the
  ##   stored ``remote.config`` value — issues links on that same base, because
  ##   a self-hosted deployment serves the share link where it serves the API.
  if isDefaultBaseRemoteUrl(apiBaseUrl):
    DefaultShareBaseUrl
  else:
    apiBaseUrl.strip().strip(leading = false, chars = {'/'})

proc apiBaseUrlForWebOrigin*(webOrigin: string): string =
  ## The API base to use for a link that was issued on ``webOrigin`` (a share
  ## link or a collaboration invite).  The product's web address maps to the
  ## default API origin; any other origin is its own API base.
  if normalizedOrigin(webOrigin) == normalizedOrigin(DefaultShareBaseUrl):
    DefaultBaseRemoteUrl
  else:
    webOrigin.strip().strip(leading = false, chars = {'/'})

proc shareLinkFor*(apiBaseUrl, orgSlug, artifactId: string): string =
  ## ``{share base}/{orgSlug}/{artifactId}/download`` — the link a user hands
  ## to somebody else, on the origin ``shareBaseUrlFor`` picks.
  shareBaseUrlFor(apiBaseUrl) & "/" & orgSlug & "/" & artifactId & "/download"
