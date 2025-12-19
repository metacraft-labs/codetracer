import
  std/[strutils, strformat, os, osproc],
  results,
  strings, filepaths

proc isSymlinkDangling(symlinkPath: string): bool =
  let target = expandSymlink(symlinkPath)
  return not fileExists(target)

proc extractExecCommand(desktopFile: string): string =
  let content = readFile(desktopFile)
  const execPrefix = "Exec="

  for line in content.splitLines():
      let normalized = strip(line, leading = true, trailing = false)
      if normalized.startsWith(execPrefix):
        return normalized[execPrefix.len ..< normalized.len]

  return ""

func rcFilesDir: string =
  # TODO:
  #
  # * Make an architectural decision below
  # * Move these definitions to the `filepaths` module that can be imported
  #   by any other module that needs to put stuff in the local directories.
  #
  # Should we use OS-specific locations for these files?
  #
  # Arguments in favor:
  # * Polluting the user home folder is a bit ugly for files that the
  #   user should not know about.
  # * The OS have their conventions for a reason - things like roaming
  #   profiles, enterprise-enacted back-up policies, etc, may end up
  #   creating problems if we don't follow the conventions.
  #
  # Arguments against:
  # * The .local directory is likely to exist on macOS already
  #   (but less so on Windows)
  # * The documentation of CodeTracer becomes more complicated
  #   (more difficult to keep in the expert user's head)
  #
  os.getHomeDir() / ".local" / "share" / "codetracer"

func shellLaunchersDir*: string =
  rcFilesDir() / "shell-launchers"

func appInstallFsLocationPath*: string =
  rcFilesDir() / "app-install-fs-location"

const
  bashrc = "bashrc"
  zshrc = "zshrc"
  fishrc = "fishrc"

template slurpShellIntegrationFile(name: string): string =
  const
    slurpedFile = currentSourcePath().parentDir & "/../shell-integrations/" & name
    slurpedContent = staticRead(slurpedFile)
  slurpedContent

proc createRcFile(filePath: FilePath, content: string): CreatedFilePath
                 {.raises: [IOError, OSError].} =
  createDir(filePath.parentDir)
  writeFile(filePath, content)
  filePath

func ourBashRcLocation: FilePath =
  rcFilesDir() / bashrc

proc createOurBashRc: CreatedFilePath =
  createRcFile ourBashRcLocation(), slurpShellIntegrationFile("bashrc")

func ourZshRcLocation: FilePath =
  rcFilesDir() / zshrc

proc createOurZshRc: CreatedFilePath =
  createRcFile ourZshRcLocation(), slurpShellIntegrationFile("zshrc")

func ourFishRcLocation: FilePath =
  rcFilesDir() / fishrc

proc createOurFishRc: CreatedFilePath =
  createRcFile ourFishRcLocation(), slurpShellIntegrationFile("fishrc")

proc installCodetracerOnPath*(codetracerExe: string): Result[void, string] {.raises: [].} =
  when defined(linux):
    var execPath = codetracerExe

    let userHome = getEnv("HOME");
    let binDir = userHome / ".local" / "bin"

    if not dirExists(binDir):
      try:
        createDir(binDir)
      except CatchableError as error:
        return err "Failed to create the codetracer user local binary directory: " & error.msg

    else:
      echo fmt2"{binDir} already exists"

    if existsEnv("APPIMAGE"):
      execPath = getEnv("APPIMAGE")

    try:
      if not fileExists(binDir / "ct"):
        echo fmt2"Creating symlink to {execPath} in {binDir}"
        createSymlink(execPath, binDir / "ct")

      elif isSymlinkDangling(binDir / "ct"):
        # Try and clean up the installation
        removeFile(binDir / "ct")
        createSymlink(execPath, binDir / "ct")
      else:
        echo fmt2"{binDir}/ct already exists and is not dangling"
    except OSError as e:
      return err "Failed to put CodeTracer on the PATH: " & e.msg

  elif defined(macosx):
    let
      homeDir = getEnv("HOME")
      shellLaunchersDir = shellLaunchersDir()

    if homeDir.len == 0:
      return err "Unable to obtain user's home directory"

    try:
      createDir(shellLaunchersDir)
      let ctLauncherPath = shellLaunchersDir / "ct"
      writeFile(ctLauncherPath, slurpShellIntegrationFile "shell-launchers/ct")
      setFilePermissions(ctLauncherPath, {fpUserExec, fpGroupExec, fpOthersExec,
                                          fpUserRead, fpGroupRead, fpOthersRead,
                                          fpUserWrite})
    except CatchableError as err:
      return err "Failed to create the ct shell launcher: " & err.msg

    let shellPath = getEnv("SHELL", "/bin/bash")

    var profileFile: string
    var integrationLine: string

    try:
      if shellPath.contains("fish"):
        let fishrc = createOurFishRc()
        profileFile = homeDir / ".config" / "fish" / "config.fish"
        integrationLine = fmt2"""if test -s "{fishrc}"; source "{fishrc}"; end"""
      elif shellPath.contains("zsh"):
        let zshrc = createOurZshRc()
        profileFile = homeDir / ".zshrc"
        integrationLine = fmt2"""[ -s "{zshrc}" ] && . "{zshrc}""""
      elif shellPath.contains("bash"):
        let bashrc = createOurBashRc()
        profileFile = homeDir / ".bash_profile"
        integrationLine = fmt2"""[ -s "{bashrc}" ] && . "{bashrc}""""
      else:
        return err fmt"CodeTracer doesn't support the {shellPath} shell"
    except CatchableError as err:
      return err "Failed to create the main CodeTracer shell integration file: " & err.msg

    # Create the profile file if it doesn't exist.
    if not fileExists(profileFile):
      try:
        writeFile(profileFile, "")
      except CatchableError as err:
        return err "Failed to create a fresh user shell profile"

    # Read the current content of the profile file.
    let content = try: readFile(profileFile)
                  except CatchableError as err:
                    return err "Failed to read the user shell profile: " & err.msg

    # Check if the integration line is already present.
    if content.contains(integrationLine):
      echo "CodeTracer integration already performed. No changes made."
    else:
      # Append the integration line.
      try:
        var f = open(profileFile, fmAppend)
        f.write("\n", integrationLine, "\n")
        f.close()
      except CatchableError as err:
        return err "Failed to append to the user shell profile: " & err.msg

      echo "Updated ", profileFile, " to source CodeTracer profile"

  elif defined(windows):
    # TODO: Implement this path
    discard

  ok()

const
  # TODO: These definitions should eventually be moved
  # elsewhere and shared with bash and various scripts
  # that generate metadata such as .desktop files, etc
  # Just create ENV files that are `staticRead` in Nim
  codetracerXdgAppName = "codetracer"
  codetracerIconFilename = codetracerXdgAppName & ".png"

when defined(linux):
  proc installCodetracerDesktopFile*(linksPath: string, rootDir: string, codetracerExe: string) =

    let iconsetPath = rootDir / "resources" / "Icon.iconset"
    let desktopFilePath = rootDir / "resources" / "codetracer.desktop"
    let userHome = getEnv("HOME");
    let iconThemesDir = userHome / ".local" / "share" / "icons" / "hicolor"
    let desktopFileDir = userHome / ".local" / "share" / "applications"

    var execPath = codetracerExe

    # If this env var is not set, then we will install codetracer for the dev
    # environment, otherwise we will install the AppImage

    if existsEnv("APPIMAGE"):
      execPath = getEnv("APPIMAGE")

    proc copyCodeTracerAppIcon(srcPath, dstDir: string) =
      let dstPath = dstDir / codetracerIconFilename

      if not dirExists(dstDir):
        createDir(dstDir)
      else:
        echo fmt"{dstDir} already exists"

      if not fileExists(dstPath):
        copyFile(srcPath, dstPath)
        echo fmt"{dstPath} created"
      else:
        echo fmt"{dstPath} already exists"

    # TODO: discover these dinamically perhaps
    for size in [16, 32, 128, 256, 512]:
      try:
        let
          xSize = fmt"{size}x{size}"
          iconSrcPath = iconsetPath / fmt"icon_{xSize}.png"
          iconDstDir = iconThemesDir / xSize / "apps"

          doubleSizeIconSrcPath = iconsetPath / fmt"icon_{xSize}@2x.png"
          doubleSizeIconDstDir = iconThemesDir / (xSize & "@2") / "apps"

        copyCodeTracerAppIcon(iconSrcPath, iconDstDir)
        copyCodeTracerAppIcon(doubleSizeIconSrcPath, doubleSizeIconDstDir)

      except OSError as e:
        echo "Failed to copy over CodeTracer icon: ", e.msg
        quit(1)

    try:
      var contents = readFile(desktopFilePath)

      # Here we modify the desktop file to point towards the executable that
      # ran the `install` command

      echo fmt"Replacing exec field with {execPath}"
      contents = contents.replace("Exec=ct edit %F", fmt"Exec={execPath} edit %F")

      let desktopFile = desktopFileDir / "codetracer.desktop"

      # Check if desktop file exists
      if fileExists(desktopFile):

        # Check if the `Exec` field is correct
        let execField = extractExecCommand(desktopFile)

        echo "exec field: ", execField

        # Desktop file is broken, remove it and add it again
        if not fileExists(execField):
          removeFile(desktopFile)
          writeFile(desktopFile, contents)
      # File doesn't exist, add it
      else:
        writeFile(desktopFile, contents)
        echo "Successfully copied the desktop file"

      # Update the desktop database to register the new MIME type
      try:
        let process = startProcess("update-desktop-database", args = @[desktopFileDir], options = {})
        let exitCode = waitForExit(process)
        if exitCode == 0:
          echo "Successfully updated desktop database"
        else:
          echo "Warning: update-desktop-database returned non-zero exit code: " & $exitCode
      except CatchableError as e:
        echo "Warning: Failed to update desktop database: " & e.msg

    except OSError as e:
      echo "Failed to install desktop file: ", e.msg
      quit(1)
