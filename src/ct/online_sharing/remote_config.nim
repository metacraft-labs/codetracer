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

import std/[os, strutils]

const
  BearerTokenKey* = "CodeTracer-Remote-BearerToken"
  DefaultOrganizationKey* = "CodeTracer-Default-Organization"
  RemoteUrlKey* = "CodeTracer-Base-Remote-Url"
  DefaultBaseRemoteUrl* = "https://ide.codetracer.com"
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
  ## 4. Default (https://ide.codetracer.com)
  if cliBaseUrl.len > 0:
    return cliBaseUrl
  let envUrl = getEnv("CODETRACER_REMOTE_BASE_URL", "")
  if envUrl.len > 0:
    return envUrl
  let configUrl = config.readConfigValue(RemoteUrlKey)
  if configUrl.len > 0:
    return configUrl
  return DefaultBaseRemoteUrl
