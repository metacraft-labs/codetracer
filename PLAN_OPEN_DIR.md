# Plan: Open Directory / Edit Mode Feature for CodeTracer

## Executive Summary

This plan outlines the work needed to enable CodeTracer to open in "edit mode" over a directory, similar to how VS Code opens a workspace. The feature will allow users to launch CodeTracer as an IDE for editing code, with the ability to later record and debug.

## Current State Analysis

### What Already Exists

1. **Frontend Edit Mode Infrastructure** (partial implementation)
   - `LayoutMode` enum with `EditMode`, `DebugMode`, `QuickEditMode`, `InteractiveEditMode`, `CalltraceLayoutMode` values
     - File: `src/common/common_types/debugger_features/debugger.nim:42-47`
   - `switchToEdit()` function that transitions UI to edit mode
     - File: `src/frontend/ui_js.nim:631` (line numbers may shift)
   - `toggleMode()` and `toggleReadOnly()` with keyboard shortcuts (Ctrl+F5, Ctrl+E)
     - File: `src/frontend/ui_js.nim:672-690` (approximate)
   - Panel hiding/restoration logic (`closeAuxiliaryPanels`, `reopenAuxiliaryPanels`)
     - File: `src/frontend/ui_js.nim:537-621` (approximate)
   - `EditModeHiddenPanel` struct for saving panel state
     - File: `src/frontend/types.nim:1432`

2. **Frontend Argument Parsing** (exists but not connected to CLI)
   - `edit` argument handling in electron args parser
     - File: `src/frontend/index/args.nim:71-87`
   - Parses `edit <path>` and sets `data.startOptions.edit = true`
   - Extracts folder path and optional file path
   - **Note**: Line 73 uses `argsExceptNoSandbox[i + 3]` which may need review - the index arithmetic depends on electron's argv structure

3. **StartOptions Structure**
   - `edit*: bool` field already exists
   - `folder*: langstring` for working directory
   - `name*: langstring` for initial file to open
     - File: `src/common/common_types/codetracer_features/frontend.nim:193-215`

4. **Frontend Initialization for Edit Mode**
   - `onNoTrace()` handler processes edit mode startup
     - File: `src/frontend/ui_js.nim:1122-1200`
   - Loads filesystem, filenames, and initializes editor-only UI
   - `startup.nim:139-160` handles the `edit` branch

5. **Welcome Screen Structure**
   - Current welcome screen (`src/frontend/ui/welcome_screen.nim`) shows:
     - `recentProjectsView()` - list of recent traces (left side in current layout)
     - `renderStartOptions()` - action buttons (right side in current layout)
   - Options include: "Record new trace", "Open local trace", "Open online trace", "CodeTracer shell" (inactive)
   - Uses `loadInitialOptions()` at line 651-701 to configure options
   - `welcomeScreenView()` at line 703-723 defines the layout
   - "Open online trace" flow:
     - Shows `onlineFormView()` (line 453-495) with input for download URL/key
     - Sends IPC `CODETRACER::download-trace-file` with the URL
     - Handler in `online_sharing.nim:84-97` runs `ct download <url>`
     - Downloads zip, imports trace, then calls `loadExistingRecord(traceId)` to open it
   - Note: Currently hidden via `TRACE_SHARING_HIDDEN_FOR_WELCOME_SCREEN = true` (line 735) - **will be enabled**

6. **Database for Recent Traces**
   - SQLite database stores traces: `src/common/trace_index.nim`
   - `findRecentTraces()` function retrieves recent traces
   - Table schema defined in `common_trace_index.nim`

### What's Missing

1. **CLI Command** - No `ct edit <directory>` or `ct open <directory>` command
2. **Recent Folders Storage** - Database only stores traces, not opened folders
3. **Welcome Screen Left Panel** - Only shows traces, not folders
4. **"Open Folder" Button** - Not in the welcome screen options
5. **Desktop Integration** - No file/folder association or "Open with CodeTracer"

---

## Implementation Plan

### Phase 1: CLI Command (Core Feature)

**Goal**: Enable `ct edit <path>` command from terminal

#### 1.1 Add CLI Command Definition
- **File**: `src/ct/codetracerconf.nim`
- Add `edit` to `StartupCommand` enum (around line 18-51)
- Define command arguments:
  ```nim
  of StartupCommand.edit:
    editPath* {.
      argument
      desc: "Path to a directory or file to open for editing"
    .}: string
  ```

#### 1.2 Implement Edit Command Handler
- **File**: `src/ct/launch/launch.nim`
- Add case for `StartupCommand.edit` in `runInitial()` (around line 119):
  ```nim
  of StartupCommand.edit:
    let absPath = absolutePath(conf.editPath)
    if not fileExists(absPath) and not dirExists(absPath):
      errorMessage "Path does not exist: " & absPath
      quit(1)
    discard launchElectron(args = @["edit", absPath])
  ```

#### 1.3 Verify Electron Launch
- **File**: `src/ct/launch/electron.nim`
- The existing `launchElectron(args)` should work - it passes args to electron
- The frontend already parses `edit <path>` in `args.nim:71-87`

---

### Phase 2: Recent Folders Storage

**Goal**: Store and retrieve recently opened folders

#### 2.1 Add Database Table for Folders
- **File**: `src/common/common_trace_index.nim`
- Add to `SQL_CREATE_TABLE_STATEMENTS`:
  ```nim
  """CREATE TABLE IF NOT EXISTS recent_folders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      path TEXT UNIQUE,
      name TEXT,
      lastOpened TEXT);"""
  ```

#### 2.2 Add Folder CRUD Operations
- **File**: `src/common/trace_index.nim`
- Add functions:
  ```nim
  proc addRecentFolder*(path: string, test: bool)
  proc findRecentFolders*(limit: int, test: bool): seq[RecentFolder]
  proc removeRecentFolder*(path: string, test: bool)
  ```

#### 2.3 Define RecentFolder Type
- **File**: `src/common/types.nim`
- Add type:
  ```nim
  RecentFolder* = object
    id*: int
    path*: string
    name*: string  # basename for display
    lastOpened*: string
  ```

#### 2.4 Add CLI Metadata Command
- **File**: `src/ct/trace/metadata.nim`
- Extend `traceMetadata` to support `--recent-folders` flag
- Return JSON array of recent folders

#### 2.5 Add Frontend Folder Metadata Retrieval
- **File**: `src/frontend/trace_metadata.nim`
- Add function similar to `findRecentTracesWithCodetracer`:
  ```nim
  proc findRecentFoldersWithCodetracer*(app: ElectronApp, limit: int): Future[seq[RecentFolder]]
  ```

---

### Phase 3: Welcome Screen Split Layout

**Goal**: Split welcome screen into left (folders) and right (traces) panels with "Open Folder" button

#### 3.1 Update Welcome Screen Layout
- **File**: `src/frontend/ui/welcome_screen.nim`
- Modify `welcomeScreenView()` (line 703-723) to have two-column layout:
  ```nim
  proc welcomeScreenView(self: WelcomeScreenComponent): VNode =
    buildHtml(tdiv(id = "welcome-screen", class = class)):
      tdiv(class = "welcome-title"):
        # ... existing title code
      tdiv(class = "welcome-content"):
        tdiv(class = "welcome-left-panel"):
          recentFoldersView(self)      # NEW: folders list
        tdiv(class = "welcome-right-panel"):
          recentProjectsView(self)     # existing traces list
      renderStartOptions(self)
  ```

#### 3.2 Add Recent Folders View
- **File**: `src/frontend/ui/welcome_screen.nim`
- Add new proc:
  ```nim
  proc recentFolderView(self: WelcomeScreenComponent, folder: RecentFolder, position: int): VNode
  proc recentFoldersView(self: WelcomeScreenComponent): VNode
  ```
- Style similar to `recentProjectsView()` but for folders
- On click: load folder in edit mode via IPC

#### 3.3 Enable "Open Online Trace" Button
- **File**: `src/frontend/ui/welcome_screen.nim`
- Change `TRACE_SHARING_HIDDEN_FOR_WELCOME_SCREEN` from `true` to `false` (line 735)
- Fix the input label in `onlineFormView()` (line 468):
  - Change `"Download ID with password"` to `"Download URL or key"`
  - The input takes a single URL/key string (not space-separated ID + password)
- **Dialog structure already exists** (same style as "Record new trace"):
  - `onlineTraceView()` (line 641-649): wrapper with logo + title "Download and open online trace"
  - `onlineFormView()` (line 453-495): form with input field + Back/Download buttons
  - Uses same CSS class `"new-record-screen"` for consistent styling
- The backend wiring is already in place:
  - IPC handler `onDownloadTraceFile` in `online_sharing.nim:84-97`
  - Runs `ct download <url>` which downloads and imports the trace
  - Calls `loadExistingRecord(traceId)` to open the trace in CodeTracer

#### 3.4 Add "Open Folder" Button
- **File**: `src/frontend/ui/welcome_screen.nim`
- Modify `loadInitialOptions()` to add new option:
  ```nim
  WelcomeScreenOption(
    name: "Open folder",
    command: proc =
      self.data.ipc.send "CODETRACER::open-folder-dialog"
  )
  ```

#### 3.5 Add IPC Handler for Folder Dialog
- **File**: `src/frontend/index/window.nim` or appropriate IPC handler file
- Add handler for `CODETRACER::open-folder-dialog`:
  ```nim
  ipcMain.on("CODETRACER::open-folder-dialog") do (event: js):
    let result = await dialog.showOpenDialog(mainWindow, js{
      properties: @[cstring"openDirectory"]
    })
    if not result.canceled and result.filePaths.len > 0:
      # Transition to edit mode with selected folder
      # Similar to how edit mode is initialized in startup.nim
  ```

#### 3.6 Add IPC Handler for Loading Folder
- Add handler for `CODETRACER::load-recent-folder`:
  - Load folder in edit mode (similar to `CODETRACER::load-recent-trace`)
  - Update recent folders in database

#### 3.7 Update WelcomeScreenComponent Type
- **File**: `src/frontend/types.nim`
- Add to `WelcomeScreenComponent`:
  ```nim
  recentFoldersScroll*: int
  loadingFolder*: RecentFolder
  ```

#### 3.8 Update Data Type
- **File**: `src/frontend/types.nim`
- Add to `Data`:
  ```nim
  recentFolders*: seq[RecentFolder]
  ```

#### 3.9 Pass Recent Folders in Welcome Screen Message
- **File**: `src/frontend/index/startup.nim`
- Modify the `CODETRACER::welcome-screen` message (line 166) to include:
  ```nim
  recentFolders: recentFolders
  ```

---

### Phase 4: CSS Styling

**Goal**: Style the split welcome screen layout while **preserving the current visual style exactly**

#### Current Style Reference (MUST PRESERVE)
The existing welcome screen has these key characteristics:
- **Dialog**: `700px` width, `#242424` background, `12px` border-radius, `1px solid #3a3a3a` border
- **Title**: `SpaceGrotesk` font, `32px` size, `#f3f3f3` color
- **Recent traces container**: `#2c2c2c` background, `6px` border-radius, `8px` padding, `48px` top/bottom margin
- **Recent traces title**: `18px` font, `SpaceGrotesk`, `500` weight
- **Trace items**: `#3a3a3a` background, `28px` height, `4px` border-radius, `#ffedd5` text color
- **Trace items hover**: `#565656` background
- **Fonts**: `FiraCode` for trace content, `SpaceGrotesk` for titles
- **Start option buttons**: `#3a3a3a` background, `6px` border-radius, `14px` font

#### 4.1 Modify `.welcome-content` for Side-by-Side Layout
- **Files**:
  - `src/build-debug/frontend/styles/default_dark_theme_electron.css`
  - `src/build-debug/frontend/styles/default_white_theme.css`
  - `src/build-debug/frontend/styles/default_dark_theme_extension.css`

Current `.welcome-content` (line ~1507):
```css
.welcome-screen-wrapper .welcome-screen .welcome-content {
  display: flex;
  flex-direction: column;  /* Change to row */
  align-items: center;
  width: -webkit-fill-available;
}
```

Change to:
```css
.welcome-screen-wrapper .welcome-screen .welcome-content {
  display: flex;
  flex-direction: row;  /* Side-by-side */
  gap: 16px;            /* Space between panels */
  align-items: flex-start;
  width: -webkit-fill-available;
}
```

#### 4.2 Add Styles for Recent Folders (Clone of Recent Traces)
The `.recent-folders` styles should be **identical** to `.recent-traces`:
```css
/* Exact clone of .recent-traces styles */
.welcome-screen-wrapper .welcome-screen .welcome-content .recent-folders {
  position: relative;
  width: 50%;  /* Half width for side-by-side */
  background-color: #2c2c2c;
  border-radius: 6px;
  padding: 8px;
  margin-top: 48px;
  margin-bottom: 48px;
  padding-right: 0px;
}

/* Adjust .recent-traces to also be 50% width */
.welcome-screen-wrapper .welcome-screen .welcome-content .recent-traces {
  width: 50%;  /* Changed from -webkit-fill-available */
}

.welcome-screen-wrapper .welcome-screen .welcome-content .recent-folders-title {
  /* Identical to .recent-traces-title */
  text-align: start;
  font-size: 18px;
  font-weight: 500;
  line-height: 18px;
  letter-spacing: -0.18px;
  font-family: 'SpaceGrotesk';
  margin-bottom: 6px;
}

.welcome-screen-wrapper .welcome-screen .welcome-content .recent-folders-list {
  /* Identical to .recent-traces-list */
  max-height: 172px;
  overflow-y: scroll;
  overflow-x: visible;
}

.welcome-screen-wrapper .welcome-screen .welcome-content .recent-folders-list .recent-folder {
  /* Identical to .recent-trace */
  color: #ffedd5;
  background-color: #3a3a3a;
  height: 28px;
  margin-top: 2px;
  margin-bottom: 6px;
  display: flex;
  position: relative;
  text-align: left;
  border-radius: 4px;
  width: -webkit-fill-available;
}

.welcome-screen-wrapper .welcome-screen .welcome-content .recent-folders-list .recent-folder:hover {
  cursor: pointer;
  background-color: #565656;
}

/* Folder name styling - identical to trace title */
.welcome-screen-wrapper .welcome-screen .welcome-content .recent-folders-list .recent-folder .recent-folder-name {
  margin-left: 8px;
  margin-right: 8px;
  font-size: 14px;
  font-weight: 500;
  font-family: 'FiraCode';
  line-height: 18px;
  letter-spacing: -0.14px;
  position: relative;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
  display: flex;
  align-items: center;
}

.welcome-screen-wrapper .welcome-screen .welcome-content .no-recent-folders {
  /* Identical to .no-recent-traces */
  height: 67px;
  width: 100%;
  align-items: center;
  display: flex;
  text-align: left;
  font-size: 18px;
  font-weight: bold;
  font-style: italic;
}
```

#### 4.3 Widen the Dialog
Since we now have two panels side-by-side, increase dialog width:
```css
.welcome-screen-wrapper .welcome-screen {
  width: 900px;  /* Increased from 700px */
  /* All other properties remain identical */
}
```

#### 4.4 Update All Theme Files
Apply the same changes to:
- `default_dark_theme_electron.css`
- `default_white_theme.css` (with appropriate light theme colors)
- `default_dark_theme_extension.css`

---

### Phase 5: Desktop Integration (Linux)

**Goal**: Enable "Open with CodeTracer" in file managers

#### 5.1 Update Desktop File
- **File**: `resources/codetracer.desktop`
- Change to:
  ```ini
  [Desktop Entry]
  Version=1.0
  Type=Application
  Exec=ct edit %F
  Name=CodeTracer
  Comment=A user-friendly time-travelling debugger designed to support a wide range of programming languages.
  Icon=codetracer
  Categories=Development
  Keywords=codetracer;time-travelling;debugger;omniscient;noir;nargo;tracing
  StartupWMClass=CodeTracer
  MimeType=inode/directory;
  ```

#### 5.2 Update Installation
- **File**: `src/common/install_utils.nim`
- Ensure `update-desktop-database` is called after installation (if not already)

---

### Phase 6: Track Folder Opens

**Goal**: Record folder opens in recent folders database

#### 6.1 Update Startup to Record Folder Open
- **File**: `src/frontend/index/startup.nim`
- In the `data.startOptions.edit` branch (line 139), add:
  ```nim
  # Record this folder in recent folders
  await addRecentFolderViaIpc(data.startOptions.folder)
  ```

#### 6.2 Add IPC for Recording Folder
- Add `CODETRACER::add-recent-folder` IPC message
- Backend handler calls `addRecentFolder()` from trace_index

---

## File Changes Summary

| Phase | File | Change Type |
|-------|------|-------------|
| 1.1 | `src/ct/codetracerconf.nim` | Add `edit` command enum + args |
| 1.2 | `src/ct/launch/launch.nim` | Add edit command handler |
| 2.1 | `src/common/common_trace_index.nim` | Add recent_folders table |
| 2.2 | `src/common/trace_index.nim` | Add folder CRUD functions |
| 2.3 | `src/common/types.nim` | Add RecentFolder type |
| 2.4 | `src/ct/trace/metadata.nim` | Add --recent-folders support |
| 2.5 | `src/frontend/trace_metadata.nim` | Add findRecentFoldersWithCodetracer |
| 3.1-3.2 | `src/frontend/ui/welcome_screen.nim` | Split layout + folders view |
| 3.3 | `src/frontend/ui/welcome_screen.nim` | Enable "Open online trace" (set const to false, fix label) |
| 3.4-3.5 | `src/frontend/ui/welcome_screen.nim` | Add "Open folder" button |
| 3.5-3.6 | `src/frontend/index/window.nim` | Add folder dialog IPC handlers |
| 3.7-3.8 | `src/frontend/types.nim` | Add recentFolders fields |
| 3.9 | `src/frontend/index/startup.nim` | Pass recentFolders to welcome screen |
| 4.1 | `src/build-debug/frontend/styles/*.css` | Add split layout styles |
| 5.1 | `resources/codetracer.desktop` | Add MimeType + edit command |
| 6.1 | `src/frontend/index/startup.nim` | Record folder opens |
| 7.1 | `src/frontend/types.nim` | Add workspaceFolder field |
| 7.2 | `src/frontend/index/traces.nim` | Compare workspace vs trace folders |
| 7.3 | `src/frontend/index/files.nim` | `loadFilesystemWithCategory()`, `findCommonAncestor()` |
| 7.4 | `src/frontend/ui_js.nim` | `onFilesystemCategoryLoaded()` handler |
| 7.5 | `src/frontend/index/files.nim` | Update root structure for categories |
| 7.7 | `src/frontend/ui_js.nim` | Preserve filesystem in `onUpdateTrace()` |
| 7.8 | CSS files | Styling for "Trace Files" category |
| 8.1 | `src/common/common_types/.../frontend.nim` | Add new ClientAction entries |
| 8.2 | `src/frontend/ui_js.nim` | Add menu items + dynamic sub-menu |
| 8.3 | `src/frontend/renderer.nim` | Add action handlers |
| 8.4 | `src/frontend/index/launch_config.nim` (new) | launch.json parser (ctIndex context) |
| 8.5 | `src/frontend/index/ipc_utils.nim` | Add `onRecordFromLaunch` handler |
| 8.6 | `src/frontend/ui/debug.nim` | Add toolbar dropdown |
| 8.7 | `src/frontend/types.nim` | Add `launchConfigs` field to Data |
| 9.1 | `src/config/default_edit_layout.json` (new) | Default edit layout template |
| 9.2 | `src/frontend/types.nim` | Add `editModeLayout`, `lastUsedEditLayout` |
| 9.3 | `src/frontend/index/config.nim` | Add `loadEditLayoutConfig()` |
| 9.4 | `src/frontend/index/window.nim` | Enable layout persistence with mode |
| 9.5 | `src/frontend/ui_js.nim` | Save/restore edit layout on mode switch |

---

## Phase 8: Menu Actions & launch.json Support

**Goal**: Add "Open Trace" and "Record New Trace" menu options, and support VS Code's launch.json for recording configurations.

### 8.1 Add New ClientAction Entries

**File**: `src/common/common_types/codetracer_features/frontend.nim`

Add to `ClientAction` enum (around line 60):
```nim
aOpenTrace,          # Open existing trace file/folder
aRecordNewTrace,     # Show record new trace dialog
aRecordFromLaunch,   # Record using launch.json configuration
```

### 8.2 Add Menu Items

**File**: `src/frontend/ui_js.nim`

Modify `webTechMenu()` (around line 243) to add items to the "File" folder:
```nim
folder "File":
  element "Open Trace...", aOpenTrace
  element "Open Folder...", aOpenFolder  # Opens folder dialog for edit mode
  element "Record New Trace...", aRecordNewTrace
  --sub
  element "Close Current File", closeTab
  # ... existing items
```

Add launch config options to the existing "Build" folder (line ~368) or the "Debug" folder (line ~381):
```nim
folder "Build":
  element "Record New Trace...", aRecordNewTrace
  element "Record from Launch Config...", aRecordFromLaunch
  --sub
  element "Rebuild/Re-record file", aReRecord, true
  element "Rebuild/Re-record project", aReRecordProject, true
```

Note: The menu uses a `defineMenu` DSL macro. Elements need corresponding `ClientAction` enum values.

### 8.3 Add Action Handlers

**File**: `src/frontend/renderer.nim`

Add handlers for new actions:
```nim
proc openTraceDialog*(data: Data) {.async.} =
  # Show file dialog to select trace folder
  data.ipc.send "CODETRACER::open-trace-dialog"

proc recordNewTraceDialog*(data: Data) =
  # Show the existing new-record-screen in welcome_screen
  data.ui.components.welcomeScreen.newRecordScreen = true
  data.ui.components.welcomeScreen.welcomeScreen = false
  data.redraw()

proc recordFromLaunchConfig*(data: Data) {.async.} =
  # Parse launch.json and show selection dialog
  let configs = await data.parseLaunchConfigs()
  if configs.len > 0:
    data.showLaunchConfigSelector(configs)
  else:
    data.showNotification("No launch.json found in .vscode folder")
```

Register in action handlers:
```nim
data.actions[aOpenTrace] = proc = discard data.openTraceDialog()
data.actions[aRecordNewTrace] = proc = data.recordNewTraceDialog()
data.actions[aRecordFromLaunch] = proc = discard data.recordFromLaunchConfig()
```

### 8.4 launch.json Parser - Architecture Considerations

**Important**: CodeTracer has two distinct compilation contexts:
1. **Native (C)**: The `ct` CLI (`src/ct/`) - handles recording, replay, etc.
2. **JavaScript**: Frontend in Electron (`src/frontend/`) - UI and IPC coordination

The launch.json parsing runs in the **Electron index process** (Node.js context, `-d:ctIndex`), which has filesystem access. Recording is triggered by spawning the native `ct record` command.

**File**: `src/frontend/index/launch_config.nim` (NEW - runs in ctIndex context)

Based on [VS Code debugging configuration](https://code.visualstudio.com/docs/debugtest/debugging-configuration) specification:

```nim
## This module runs in the Electron index process (Node.js context).
## It parses launch.json and prepares arguments for spawning `ct record`.

when defined(ctIndex) or defined(ctTest):
  import std/[jsffi, sequtils, strutils]
  import ../lib/[jslib, electron_lib]

  type
    LaunchConfig* = ref object
      name*: cstring
      `type`*: cstring
      request*: cstring
      program*: cstring
      args*: seq[cstring]
      cwd*: cstring
      env*: JsAssoc[cstring, cstring]
      module*: cstring  # Python -m module

  proc substituteVariables(s: cstring, workspaceFolder: cstring): cstring =
    var result = $s
    result = result.replace("${workspaceFolder}", $workspaceFolder)
    result = result.replace("${workspaceRoot}", $workspaceFolder)
    return cstring(result)

  proc parseLaunchJson*(workspaceFolder: cstring): Future[seq[LaunchConfig]] {.async.} =
    ## Parse .vscode/launch.json - runs in Node.js context with fs access
    let launchPath = nodePath.join(workspaceFolder, cstring".vscode", cstring"launch.json")

    let exists = await pathExists(launchPath)
    if not exists:
      return @[]

    try:
      let (content, err) = await fsReadFileWithErr(launchPath)
      if not err.isNil:
        return @[]

      # Strip // comments (JSONC support)
      var cleanLines: seq[string] = @[]
      for line in ($content).splitLines():
        let trimmed = line.strip()
        if not trimmed.startsWith("//"):
          cleanLines.add(line)
      let cleanContent = cleanLines.join("\n")

      let json = JSON.parse(cstring(cleanContent))
      var configs: seq[LaunchConfig] = @[]

      let configurations = json.configurations
      for i in 0..<configurations.length.to(int):
        let config = configurations[i]
        let request = config.request.to(cstring)
        if request != cstring"launch":
          continue  # Skip "attach" configurations

        var lc = LaunchConfig()
        lc.name = config.name.to(cstring)
        lc.`type` = config.`type`.to(cstring)
        lc.request = request
        lc.program = substituteVariables(
          config.program.to(cstring), workspaceFolder)
        lc.cwd = if config.cwd.isNil: workspaceFolder
                 else: substituteVariables(config.cwd.to(cstring), workspaceFolder)

        if not config.args.isNil:
          for j in 0..<config.args.length.to(int):
            lc.args.add(substituteVariables(config.args[j].to(cstring), workspaceFolder))

        if not config.env.isNil:
          lc.env = JsAssoc[cstring, cstring]{}
          # Copy env vars with substitution
          for key in js_keys(config.env):
            lc.env[key] = substituteVariables(config.env[key].to(cstring), workspaceFolder)

        if not config.module.isNil:
          lc.module = config.module.to(cstring)

        configs.add(lc)

      return configs
    except:
      errorPrint "Error parsing launch.json: ", getCurrentExceptionMsg()
      return @[]

  proc adaptToRecordArgs*(config: LaunchConfig, workspaceFolder: cstring):
      tuple[program: cstring, args: seq[cstring], cwd: cstring] =
    ## Convert launch config to `ct record` arguments.
    ## Recording is done by spawning native `ct record <program> <args>`.

    var program = config.program
    var args = config.args

    # Special case: Python module mode (-m)
    if config.module.len > 0:
      program = cstring"python"
      args = @[cstring"-m", config.module] & config.args

    result = (
      program: program,
      args: args,
      cwd: if config.cwd.len > 0: config.cwd else: workspaceFolder
    )
```

### 8.4.1 Recording Flow (IPC between contexts)

The recording is triggered from the frontend but executed by spawning the native `ct` CLI:

```
┌─────────────────────────────────────────────────────────────────┐
│  Renderer (ui.js)                                               │
│  User clicks "Record: My App" in menu                           │
│       │                                                         │
│       ▼ IPC: "CODETRACER::record-from-launch"                  │
└───────┼─────────────────────────────────────────────────────────┘
        │
┌───────▼─────────────────────────────────────────────────────────┐
│  Index Process (index.js) - Node.js context                     │
│                                                                 │
│  1. Receive IPC with launch config                              │
│  2. Call adaptToRecordArgs() to get program/args                │
│  3. Spawn: `ct record <program> <args...>`                      │
│  4. Monitor process, capture trace ID from output               │
│  5. Send IPC: "CODETRACER::record-complete" with trace ID       │
└───────┼─────────────────────────────────────────────────────────┘
        │ spawns
┌───────▼─────────────────────────────────────────────────────────┐
│  Native ct CLI (record.nim)                                     │
│                                                                 │
│  • detectLang(program) - auto-detect language                   │
│  • resolvePythonInterpreter() - find Python if needed           │
│  • recordInternal() - do the actual recording                   │
│  • Output trace ID to stdout                                    │
└─────────────────────────────────────────────────────────────────┘
```

**File**: `src/frontend/index/ipc_utils.nim` (add handler)

```nim
proc onRecordFromLaunch*(sender: js, response: jsobject(config=LaunchConfig)) {.async.} =
  let (program, args, cwd) = adaptToRecordArgs(response.config, data.workspaceFolder)

  # Build ct record command
  var ctArgs = @[cstring"record", program]
  ctArgs = ctArgs.concat(args)

  # Spawn native ct process
  let ctPath = codetracerExe  # Path to ct binary
  let (stdout, stderr, err) = await childProcessExec(
    ctPath,
    ctArgs,
    js{cwd: cwd, env: response.config.env})

  if err.isNil:
    # Parse trace ID from output and load it
    let traceId = parseTraceIdFromOutput(stdout)
    if traceId > 0:
      await loadExistingRecord(traceId)
  else:
    mainWindow.webContents.send "CODETRACER::record-error", js{error: stderr}
```

**Key Insight**: The adaptation is simple because we just spawn `ct record` with the extracted program and args. CodeTracer's native `record` command handles:
- Language detection from program path (`detectLang` in `record.nim:238`)
- Python interpreter resolution (`resolvePythonInterpreter`)
- Backend selection (rr vs db-backend)
- All recording logic

### 8.5 Launch Config Selection UI

**File**: `src/frontend/ui/launch_config_selector.nim` (NEW) or integrate into welcome_screen.nim

```nim
proc launchConfigSelectorView*(data: Data, configs: seq[LaunchConfig]): VNode =
  buildHtml(tdiv(class = "launch-config-selector")):
    tdiv(class = "launch-config-title"):
      text "Select Launch Configuration"
    tdiv(class = "launch-config-list"):
      for i, config in configs:
        tdiv(
          class = "launch-config-item",
          onclick = proc =
            data.recordWithLaunchConfig(config)
        ):
          span(class = "launch-config-name"):
            text config.name
          span(class = "launch-config-type"):
            text config.`type`
          span(class = "launch-config-program"):
            text config.program
```

### 8.6 Recording with Launch Config

**File**: `src/frontend/renderer.nim`

```nim
proc recordWithLaunchConfig*(data: Data, config: LaunchConfig) {.async.} =
  let (program, args, env, cwd) = adaptToCodetracerRecord(config, $data.workspaceFolder)

  # Send record command via IPC
  data.ipc.send "CODETRACER::new-record", js{
    program: program.cstring,
    args: args.mapIt(it.cstring),
    workdir: cwd.cstring,
    env: env.toJs,
    openAfterRecord: true
  }
```

### 8.7 IPC Handlers for Open Trace Dialog

**File**: `src/frontend/index/window.nim` or appropriate IPC file

```nim
proc onOpenTraceDialog*(sender: js, response: js) {.async.} =
  let selection = await electron.dialog.showOpenDialog(mainWindow, js{
    properties: @[cstring"openDirectory"],
    title: cstring"Select Trace Folder",
    buttonLabel: cstring"Open Trace"
  })

  let filePaths = cast[seq[cstring]](selection.filePaths)
  if filePaths.len > 0:
    # Load the trace from selected folder
    let tracePath = filePaths[0]
    # Determine trace ID or load directly
    mainWindow.webContents.send "CODETRACER::load-trace-from-path", js{path: tracePath}
```

### 8.8 Supported launch.json Types

Based on [VS Code documentation](https://code.visualstudio.com/docs/debugtest/debugging-configuration), CodeTracer should support:

| VS Code Type | CodeTracer Adaptation |
|--------------|----------------------|
| `python` / `debugpy` | `python3 <script>` or `python3 -m <module>` |
| `node` / `pwa-node` | `node <script>` |
| `cppdbg` / `cppvsdbg` | Direct executable |
| `go` | `go run <file>` or direct binary |
| `lldb` / `codelldb` | Direct executable (Rust, C++) |
| `coreclr` | `dotnet run` or direct executable |

### 8.9 Variable Substitution Support

From [VS Code variables reference](https://code.visualstudio.com/docs/debugtest/debugging-configuration):

| Variable | Substitution |
|----------|--------------|
| `${workspaceFolder}` | Workspace root path |
| `${workspaceRoot}` | Same as above (deprecated) |
| `${file}` | Currently open file (if applicable) |
| `${fileBasename}` | Basename of current file |
| `${fileDirname}` | Directory of current file |
| `${env:VAR}` | Environment variable |

### 8.10 Dynamic Launch Config Sub-Menu

**File**: `src/frontend/ui_js.nim`

The launch configurations should be accessible through a **dynamically populated sub-menu** in the Debug menu:

```nim
folder "Debug":
  # ... existing debug items ...
  --sub
  folder "Record Configuration":
    # Dynamically populated from launch.json
    # If no launch.json exists, show single disabled item
    if data.launchConfigs.len == 0:
      element "No launch.json found", aNoOp, false
    else:
      for config in data.launchConfigs:
        element config.name, aRecordLaunchConfig  # Dynamic action
```

**Implementation**:
- Parse launch.json on workspace load and store in `data.launchConfigs`
- Rebuild menu when workspace changes
- Each config item triggers recording with that specific configuration

### 8.11 Debug Toolbar Popup Menu

**File**: `src/frontend/ui/debug.nim`

Add a dropdown/popup button to the debug toolbar for quick access:

```nim
proc launchConfigDropdown*(data: Data): VNode =
  buildHtml(tdiv(class = "launch-config-dropdown")):
    button(
      class = "launch-config-trigger",
      onclick = proc = data.ui.showLaunchConfigPopup = not data.ui.showLaunchConfigPopup
    ):
      span(class = "icon-record")
      span(class = "dropdown-arrow")

    if data.ui.showLaunchConfigPopup:
      tdiv(class = "launch-config-popup"):
        if data.launchConfigs.len == 0:
          tdiv(class = "launch-config-empty"):
            text "No configurations in .vscode/launch.json"
        else:
          for config in data.launchConfigs:
            tdiv(
              class = "launch-config-popup-item",
              onclick = proc = data.recordWithLaunchConfig(config)
            ):
              span(class = "config-name"): text config.name
              span(class = "config-type"): text config.`type`
```

### 8.12 Command Palette Integration

**File**: `src/frontend/types.nim` and command palette handling

Launch configurations are automatically available in the command palette by virtue of being in the menu. The command palette searches menu items, so:

- "Record Configuration: My Python App" will appear when user types "record" or "python"
- Each launch config becomes a searchable command

**Additional Enhancement** - Add explicit command entries:
```nim
# In command interpreter setup
for config in data.launchConfigs:
  data.services.search.commandsPrepared.add(
    fuzzysort.prepare(cstring("Record: " & config.name)))
```

### Summary of Menu & launch.json Changes

**Access Points for Launch Configurations**:

| Location | Description |
|----------|-------------|
| Debug Menu → "Record Configuration" | Dynamic sub-menu listing all configs |
| Debug Toolbar | Dropdown button with popup menu |
| Command Palette (Ctrl+Shift+P) | Searchable by config name |
| File Menu → "Record New Trace..." | Opens manual record dialog |

**New Menu Items**:
- File → "Open Trace..." (shows folder picker)
- File → "Record New Trace..." (shows existing record dialog)
- Debug → "Record Configuration" → [dynamic list from launch.json]

**launch.json Flow**:
1. On workspace load, parse `.vscode/launch.json`
2. Store configurations in `data.launchConfigs`
3. Populate Debug menu sub-menu dynamically
4. User selects config from menu, toolbar popup, or command palette
5. Adapt config to CodeTracer record command
6. Execute record
7. Auto-open trace when complete

---

## Phase 9: Edit Mode Layout Management

**Goal**: Edit mode should have its own persistent layout, separate from debug mode, that is saved and restored across sessions.

### Current Layout System Analysis

**Key Findings**:
1. **GoldenLayout** is used for the panel system (`src/public/third_party/tempL/goldenlayout.js`)
2. Layouts are stored as JSON in `~/.config/codetracer/{layout_name}.json`
3. Currently only ONE layout file: `default_layout.json` (used for debug mode)
4. `savedLayoutBeforeEdit` (types.nim:1453) saves debug layout temporarily when entering edit mode (stored in `Components` type)
5. Edit mode hides "auxiliary panels" (State, Scratchpad, EventLog, etc.) via `closeAuxiliaryPanels()`
6. Layout persistence is currently **disabled** (window.nim:121: "FOR NOW: persisting config disabled")

**Current Edit Mode Behavior** (ui_js.nim:537-631):
- Saves debug layout to `savedLayoutBeforeEdit` (in memory only)
- Closes auxiliary panels, keeping only filesystem and editors
- Does NOT persist edit layout to disk

### 9.1 Add Separate Edit Mode Layout File

**File**: `src/config/default_edit_layout.json` (NEW)

Create a default edit-focused layout:
```json
{
  "settings": { /* same as default_layout.json */ },
  "dimensions": { /* same as default_layout.json */ },
  "root": {
    "type": "row",
    "content": [
      {
        "type": "component",
        "componentType": "genericUiComponent",
        "size": "20%",
        "componentState": {
          "id": 0,
          "content": 9,  // Filesystem
          "label": "Files"
        }
      },
      {
        "type": "stack",
        "size": "80%",
        "content": []  // Editors will be added dynamically
      }
    ]
  }
}
```

### 9.2 Track Edit Layout Separately

**File**: `src/frontend/types.nim`

Add to `Components`:
```nim
Components* = ref object
  # ... existing fields ...
  savedLayoutBeforeEdit*: GoldenLayoutResolvedConfig  # Existing - debug layout snapshot
  editModeLayout*: GoldenLayoutResolvedConfig         # NEW - persistent edit layout
  lastUsedEditLayout*: GoldenLayoutResolvedConfig     # NEW - last saved edit layout
```

**File**: `src/frontend/config.nim`

Add constants:
```nim
const
  defaultLayoutPath* = "default_layout.json"      # Existing
  defaultEditLayoutPath* = "default_edit_layout.json"  # NEW
```

### 9.3 Load Edit Layout on Startup

**File**: `src/frontend/index/config.nim`

Add function to load edit layout:
```nim
proc loadEditLayoutConfig*(main: js, filename: string): Future[js] {.async.} =
  ## Load edit mode layout, similar to loadLayoutConfig but for edit mode
  let (data, err) = await fsreadFileWithErr(cstring(filename))
  if not err.isNil:
    # Copy default edit layout to user config directory
    let errCopy = await fsCopyFileWithErr(
      cstring(fmt"{configDir / defaultEditLayoutPath}"),
      cstring(filename))
    if errCopy.isNil:
      return await loadEditLayoutConfig(main, filename)
    else:
      errorPrint "edit layout copy error: ", errCopy
      return js{}
  else:
    return JSON.parse(data)
```

**File**: `src/frontend/index/startup.nim`

When entering edit mode (around line 139):
```nim
if data.startOptions.edit:
  # Load edit-specific layout
  let editLayoutPath = fmt"{userLayoutDir}/edit_layout.json"
  let editLayout = await loadEditLayoutConfig(main, editLayoutPath)

  let filesystem = await loadFilesystem(...)
  let filenames = await loadFilenames(...)

  main.webContents.send "CODETRACER::no-trace", js{
    # ... existing fields ...
    layout: editLayout,  # Use edit layout instead of debug layout
    isEditMode: true
  }
```

### 9.4 Save Edit Layout on Change

**File**: `src/frontend/index/window.nim`

Enable layout persistence and add edit mode support:
```nim
proc onSaveConfig*(sender: js, response: jsobject(name=cstring, layout=cstring, isEditMode=bool)) {.async.} =
  let filename = if response.isEditMode:
    fmt"{userLayoutDir}/edit_layout.json"
  else:
    fmt"{userLayoutDir}/{response.name}.json"

  try:
    discard await writeFileAsync(fsAsync, cstring(filename), response.layout)
    debugPrint "Saved layout to: ", filename
  except:
    errorPrint "Failed to save layout: ", getCurrentExceptionMsg()
```

**File**: `src/frontend/renderer.nim`

Update `saveConfig` to include mode:
```nim
proc saveConfig*(data: Data) =
  let layoutJson = JSON.stringify(data.ui.layout.saveLayout())
  data.ipc.send "CODETRACER::save-config", js{
    name: data.config.layout,
    layout: layoutJson,
    isEditMode: data.ui.mode == EditMode
  }
```

### 9.5 Restore Edit Layout When Returning to Edit Mode

**File**: `src/frontend/ui_js.nim`

Modify `switchToEdit()`:
```nim
proc switchToEdit*(data: Data) =
  if data.ui.mode != EditMode:
    # Save current debug layout
    if data.ui.savedLayoutBeforeEdit.isNil:
      data.ui.savedLayoutBeforeEdit = cast[GoldenLayoutResolvedConfig](
        JSON.parse(JSON.stringify(data.ui.layout.saveLayout())))

    data.ui.mode = EditMode

    # Load last used edit layout if available
    if not data.ui.lastUsedEditLayout.isNil:
      try:
        data.ui.layout.loadLayout(data.ui.lastUsedEditLayout)
        data.ui.resolvedConfig = data.ui.lastUsedEditLayout
      except:
        # Fallback to closing auxiliary panels
        data.setEditorsReadOnlyState(false)
    else:
      # First time or no saved edit layout - close auxiliary panels
      data.setEditorsReadOnlyState(false)

    redrawAll()
```

Modify `switchToDebug()`:
```nim
proc switchToDebug*(data: Data) =
  if data.ui.mode != DebugMode:
    # Save current edit layout for next time
    data.ui.lastUsedEditLayout = cast[GoldenLayoutResolvedConfig](
      JSON.parse(JSON.stringify(data.ui.layout.saveLayout())))

    data.ui.mode = DebugMode

    # Restore debug layout
    if not data.ui.savedLayoutBeforeEdit.isNil:
      try:
        data.ui.layout.loadLayout(data.ui.savedLayoutBeforeEdit)
        data.ui.resolvedConfig = data.ui.savedLayoutBeforeEdit
        data.ui.savedLayoutBeforeEdit = nil
      except:
        data.setEditorsReadOnlyState(true)
    else:
      data.setEditorsReadOnlyState(true)

    redrawAll()
```

### 9.6 Load Edit Layout from Disk on Init

**File**: `src/frontend/ui_js.nim`

In `onNoTrace()` handler (around line 1122):
```nim
proc onNoTrace(...) {.async.} =
  # ... existing code ...

  # Store edit layout for mode switching
  if response.isEditMode:
    data.ui.lastUsedEditLayout = response.layout

  data.ui.resolvedConfig = response.layout
  # ... rest of initialization
```

### Summary of Edit Layout Changes

**New Files**:
- `src/config/default_edit_layout.json` - Default edit-focused layout

**Modified Files**:
- `src/frontend/types.nim` - Add `editModeLayout`, `lastUsedEditLayout` fields
- `src/frontend/config.nim` - Add `defaultEditLayoutPath` constant
- `src/frontend/index/config.nim` - Add `loadEditLayoutConfig()` function
- `src/frontend/index/startup.nim` - Load edit layout when starting in edit mode
- `src/frontend/index/window.nim` - Enable layout persistence with mode awareness
- `src/frontend/renderer.nim` - Include mode in save config message
- `src/frontend/ui_js.nim` - Save/restore edit layout on mode switch

**Behavior**:

| Scenario | Layout Used |
|----------|-------------|
| `ct edit .` (first time) | `default_edit_layout.json` copied to user dir |
| `ct edit .` (subsequent) | User's saved `edit_layout.json` |
| Switch Edit → Debug | Save edit layout, restore debug layout |
| Switch Debug → Edit | Save debug layout, restore edit layout |
| Modify layout in edit mode | Auto-saved to `edit_layout.json` |

---

## UI Mockup

**IMPORTANT**: The visual style must match the existing welcome screen exactly:
- Same fonts (SpaceGrotesk for titles, FiraCode for content)
- Same colors (#242424 background, #2c2c2c panels, #3a3a3a items, #ffedd5 text)
- Same border-radius, padding, and spacing
- Same hover effects (#565656 on hover)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  [logo]  Welcome to CodeTracer IDE                        Version X.X.X    │
├─────────────────────────────────────┬───────────────────────────────────────┤
│  RECENT FOLDERS                     │  RECENT TRACES                        │
│  ┌────────────────────────────────┐ │  ┌──────────────────────────────────┐ │
│  │ my-project                     │ │  │ ID: 42 | hello-world             │ │
│  ├────────────────────────────────┤ │  ├──────────────────────────────────┤ │
│  │ another-app                    │ │  │ ID: 41 | my-app                  │ │
│  ├────────────────────────────────┤ │  ├──────────────────────────────────┤ │
│  │ test-code                      │ │  │ ID: 40 | debugging-test          │ │
│  └────────────────────────────────┘ │  └──────────────────────────────────┘ │
│                                     │                                       │
│  (No folders yet.)                  │  (No traces yet.)                     │
├─────────────────────────────────────┴───────────────────────────────────────┤
│   [Open folder]   [Record new trace]   [Open local trace]   [Open online trace]   │
└─────────────────────────────────────────────────────────────────────────────┘

Style notes:
- Panel background: #2c2c2c with 6px border-radius
- Item rows: #3a3a3a background, 28px height, 4px border-radius
- Item hover: #565656 background
- Text: #ffedd5 color, FiraCode font, 14px
- Title: SpaceGrotesk font, 18px, 500 weight
- Buttons: #3a3a3a background, 6px border-radius
```

---

## Testing Plan

1. **CLI Testing**
   - `ct edit .` - Open current directory
   - `ct edit /absolute/path` - Open absolute path
   - `ct edit relative/path` - Open relative path
   - `ct edit file.py` - Open single file (should open parent folder + file)
   - `ct edit nonexistent` - Error handling

2. **Welcome Screen Testing**
   - Launch `ct` with no arguments
   - Verify split layout (folders left, traces right)
   - Click "Open Folder" button → folder dialog opens
   - Select folder → editor mode loads
   - Verify folder appears in recent folders on next launch
   - Click "Open online trace" → shows download form
   - Enter download URL/key → downloads and opens trace

3. **Recent Folders Testing**
   - Open several folders
   - Verify they appear in recent folders list (most recent first)
   - Click a recent folder → loads in edit mode
   - Database persists across restarts

4. **Desktop Integration Testing (Linux)**
   - Right-click folder in file manager → "Open with CodeTracer"
   - `.desktop` file validation with `desktop-file-validate`

5. **Edit Mode Layout Testing**
   - First launch `ct edit .` → uses default edit layout (filesystem + editors)
   - Resize/rearrange panels → layout persists after restart
   - Switch Edit → Debug → Edit → layout preserved
   - Separate edit and debug layouts maintained independently
   - `~/.config/codetracer/edit_layout.json` created on first edit session
   - Close CodeTracer in edit mode, reopen → same layout restored

6. **Menu & launch.json Testing**
   - File → "Open Trace..." → folder dialog opens
   - File → "Record New Trace..." → record dialog appears
   - Create `.vscode/launch.json` → Debug menu shows configurations
   - Select launch config → recording starts with correct program/args
   - Command palette search finds launch configurations
   - Debug toolbar dropdown shows launch configs

---

## Implementation Order

1. **Phase 1** (CLI Command) - Essential foundation, enables manual testing
2. **Phase 2** (Recent Folders Storage) - Backend support for UI
3. **Phase 3** (Welcome Screen) - User-facing feature
4. **Phase 4** (CSS) - Polish the UI
5. **Phase 6** (Track Opens) - Complete the loop
6. **Phase 7** (Filesystem Panel) - Workspace vs Trace Files handling
7. **Phase 8** (Menu & launch.json) - Recording from edit mode
8. **Phase 9** (Edit Mode Layout) - Separate persistent layouts for edit/debug modes
9. **Phase 5** (Desktop Integration) - Nice-to-have for file managers

---

## Dependencies & Considerations

1. **Electron Dialog API** - Already used (`chooseDir` exists in welcome_screen.nim)
2. **SQLite** - Already used for trace storage
3. **File System Permissions** - Ensure write access for editing
4. **Existing IPC Patterns** - Follow existing patterns like `CODETRACER::load-recent-trace`

---

## Phase 7: Filesystem Panel - Workspace vs Trace Files

**Goal**: The filesystem panel should display the workspace directory tree in edit mode, and intelligently handle the transition to replay mode by showing "Trace Files" category only when the trace references files outside the workspace.

### Current Filesystem Panel Architecture

**Key Files**:
- `src/frontend/ui/filesystem.nim` - Main panel component using jstree
- `src/frontend/index/files.nim` - `loadFilesystem()`, `loadFile()`, `loadPathContentPartially()`
- `src/frontend/types.nim` - `CodetracerFile`, `EditorService.filesystem`

**Current Data Flow**:
```
Edit Mode:
  startOptions.folder → loadFilesystem([folder], "", false) → filesystem

Trace/Replay Mode:
  trace.sourceFolders → loadFilesystem(sourceFolders, traceFilesPath, imported) → filesystem
```

**Key Insight**: Currently, when loading a trace, the filesystem is **completely replaced** with `trace.sourceFolders`. We need to change this to:
1. Keep the workspace tree as the primary view
2. Add a "Trace Files" category only for files outside the workspace

### 7.1 Track Workspace Folder Separately

**File**: `src/frontend/types.nim`

Add to `Data` or `EditorService`:
```nim
workspaceFolder*: cstring  # The folder opened in edit mode (persists across mode switches)
```

**File**: `src/frontend/index/startup.nim`

In the edit mode branch (line 139), store the workspace folder:
```nim
data.workspaceFolder = folder  # Store for later comparison
```

### 7.2 Modify Filesystem Loading for Replay Mode

**File**: `src/frontend/index/traces.nim`

Change `loadTrace()` (lines 153-180) to:
1. NOT replace the filesystem if workspace folder is set
2. Compare `trace.sourceFolders` against `data.workspaceFolder`
3. Only load external files into a separate "Trace Files" category

```nim
proc loadTrace*(data: var ServerData, main: js, trace: Trace, config: Config, helpers: Helpers): Future[void] {.async.} =
  # ... existing code ...

  # NEW: Determine which trace source folders are outside workspace
  var externalFolders: seq[cstring] = @[]
  var workspaceContainsTrace = false

  if data.workspaceFolder.len > 0:
    for sourceFolder in trace.sourceFolders:
      if sourceFolder.startsWith(data.workspaceFolder):
        workspaceContainsTrace = true
      else:
        externalFolders.add(sourceFolder)
  else:
    # No workspace - load all trace folders (current behavior)
    externalFolders = trace.sourceFolders

  # Only send filesystem if there are external folders
  if externalFolders.len > 0:
    discard sendFilesystemWithCategory(main, externalFolders, traceFilesPath, trace.imported, "Trace Files")
  elif not workspaceContainsTrace:
    # Trace has no overlap with workspace - load full trace filesystem
    discard sendFilesystem(main, trace.sourceFolders, traceFilesPath, trace.imported)
  # else: workspace already contains trace files, no filesystem change needed
```

### 7.3 Add "Trace Files" Category Support

**File**: `src/frontend/index/files.nim`

Add new function to load filesystem with a category label:
```nim
proc loadFilesystemWithCategory*(
    paths: seq[cstring],
    traceFilesPath: cstring,
    selfContained: bool,
    categoryName: cstring): Future[CodetracerFile] {.async.} =
  # Similar to loadFilesystem but uses categoryName instead of "source folders"
  var folderGroup = CodetracerFile(
    text: categoryName,  # "Trace Files" instead of "source folders"
    children: @[],
    state: js{opened: true},
    index: 0,
    parentIndices: @[],
    original: CodetracerFileData(
      text: categoryName,
      path: cstring""))
  # ... rest same as loadFilesystem
```

**File**: `src/frontend/index/traces.nim`

Add new IPC sender:
```nim
proc sendFilesystemWithCategory(main: js, paths: seq[cstring], traceFilesPath: cstring, selfContained: bool, category: cstring) {.async.} =
  let folders = await loadFilesystemWithCategory(paths, traceFilesPath, selfContained, category)
  main.webContents.send "CODETRACER::filesystem-category-loaded", js{ folders: folders, category: category }
```

### 7.4 Handle Filesystem Category in Frontend

**File**: `src/frontend/ui_js.nim`

Add new IPC handler:
```nim
proc onFilesystemCategoryLoaded(
  sender: js,
  response: jsobject(
    folders=CodetracerFile,
    category=cstring)) =
  # Add as a new top-level category in the existing filesystem tree
  # instead of replacing the entire tree
  if data.services.editor.filesystem.isNil:
    data.services.editor.filesystem = response.folders
  else:
    # Add "Trace Files" as a sibling to "source folders"
    # First, check if category already exists and remove it
    var newChildren: seq[CodetracerFile] = @[]
    for child in data.services.editor.filesystem.children:
      if child.text != response.category:
        newChildren.add(child)

    # Add the new category
    response.folders.text = response.category
    newChildren.add(response.folders)
    data.services.editor.filesystem.children = newChildren

  # Force jstree refresh
  let tree = jqFind(".filesystem").jstree(true)
  if not tree.isNil:
    tree.refresh()
  data.redraw()
```

### 7.5 Update Filesystem Root Structure

**File**: `src/frontend/index/files.nim`

Modify `loadFilesystem()` to support multiple root categories:
```nim
proc loadFilesystem*(paths: seq[cstring], traceFilesPath: cstring, selfContained: bool): Future[CodetracerFile] {.async.} =
  # Create root node that can hold multiple categories
  var root = CodetracerFile(
    text: cstring"",  # Invisible root
    children: @[],
    state: js{opened: true},
    index: 0,
    parentIndices: @[],
    original: CodetracerFileData(text: cstring"", path: cstring""))

  # "Workspace" or "source folders" category
  var workspaceGroup = CodetracerFile(
    text: cstring"Workspace",  # Or keep "source folders" for backward compat
    children: @[],
    state: js{opened: true},
    index: 0,
    parentIndices: @[0],
    original: CodetracerFileData(text: cstring"Workspace", path: cstring""))

  for index, path in paths:
    let file = await loadPathContentPartially(path, index, @[0], traceFilesPath, selfContained)
    if not file.isNil:
      workspaceGroup.children.add(file)

  root.children.add(workspaceGroup)
  return root
```

### 7.6 Find Common Ancestor for External Trace Files

When trace files are outside the workspace, group them under their common ancestor path:

**File**: `src/frontend/index/files.nim`

Add helper:
```nim
proc findCommonAncestor(paths: seq[cstring]): cstring =
  if paths.len == 0:
    return cstring""
  if paths.len == 1:
    return paths[0]

  var parts = ($paths[0]).split("/")
  for path in paths[1..^1]:
    let pathParts = ($path).split("/")
    var commonLen = 0
    for i in 0..<min(parts.len, pathParts.len):
      if parts[i] == pathParts[i]:
        commonLen = i + 1
      else:
        break
    parts = parts[0..<commonLen]

  return cstring(parts.join("/"))
```

### 7.7 Preserve Workspace Filesystem on Mode Switch

**File**: `src/frontend/ui_js.nim`

Modify `onUpdateTrace()` to NOT replace filesystem:
```nim
proc onUpdateTrace(sender: js, response: jsobject(trace=Trace)) =
  data.trace = response.trace
  data.ui.readOnly = false

  # KEEP the existing filesystem - don't overwrite
  # The filesystem will be updated by onFilesystemCategoryLoaded if needed

  data.switchToDebug()
  redrawAll()
```

### 7.8 Visual Distinction for Trace Files

**File**: CSS files

Add styling to distinguish "Trace Files" category:
```css
/* Trace Files category styling */
.jstree-node[data-category="trace-files"] > .jstree-anchor {
  color: #a0a0a0;  /* Slightly dimmed */
  font-style: italic;
}

.jstree-node[data-category="trace-files"] > .jstree-icon {
  /* Different folder icon or color */
}
```

### Summary of Filesystem Changes

| Scenario | Behavior |
|----------|----------|
| Edit mode (no trace) | Show workspace folder tree only |
| Replay: trace files inside workspace | Keep workspace tree, no changes |
| Replay: trace files outside workspace | Keep workspace tree + add "Trace Files" category |
| Replay: trace files partially overlap | Keep workspace tree + add "Trace Files" for external only |
| Switch back to edit mode | Remove "Trace Files" category, keep workspace tree |

### Files to Modify

| File | Changes |
|------|---------|
| `src/frontend/types.nim` | Add `workspaceFolder` field |
| `src/frontend/index/startup.nim` | Store workspace folder |
| `src/frontend/index/traces.nim` | Logic to compare workspace vs trace folders |
| `src/frontend/index/files.nim` | `loadFilesystemWithCategory()`, `findCommonAncestor()` |
| `src/frontend/ui_js.nim` | `onFilesystemCategoryLoaded()`, preserve filesystem in `onUpdateTrace()` |
| `src/frontend/ui/filesystem.nim` | Handle multiple root categories |
| CSS files | Styling for "Trace Files" category |
