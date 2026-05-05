## viewmodel/app_vm.nim
##
## CodeTracerAppVM is the app-level ViewModel above SessionViewModel.
##
## SessionViewModel owns one replay/edit session's panel ViewModels. This
## AppVM owns the operations that span sessions and caption chrome:
## creating/switching tabs, entering edit mode from a folder, opening files,
## and routing toolbar/keyboard debug actions to the active session.
##
## Electron, GoldenLayout and native file dialogs should be thin adapters
## around this API, not the source of application behavior.

import std/[sequtils, strutils]
when not defined(js):
  import std/os

import isonim/core/[signals, owner]
import isonim/viewmodel

import backend/mock_backend
import session_vm
import store/types
import viewmodels/[debug_controls_vm, editor_vm, welcome_screen_vm]

type
  AppSessionKind* = enum
    askWelcome
    askEdit
    askReplay

  AppSessionVM* = ref object
    ## App-owned state for one tab/session. The ``session`` field is the full
    ## per-session ViewModel composition used by panel views.
    session*: SessionViewModel
    welcomeVM*: WelcomeScreenVM
    kind*: Signal[AppSessionKind]
    title*: Signal[string]
    editFolderPath*: Signal[string]
    indexedFiles*: Signal[seq[string]]
    openFiles*: Signal[seq[string]]

  SessionFactory* = proc(): SessionViewModel {.closure.}
  FolderIndexer* = proc(folderPath: string): seq[string] {.closure.}

  CodeTracerAppVM* = ref object of ViewModel
    sessions*: Signal[seq[AppSessionVM]]
    activeSessionIndex*: Signal[int]
    createSession*: SessionFactory
    indexFolder*: FolderIndexer

# ---------------------------------------------------------------------------
# Factory helpers
# ---------------------------------------------------------------------------

proc defaultFolderIndexer(folderPath: string): seq[string] =
  ## Native fallback used by headless tests and non-Electron adapters.
  ## Production Electron can inject an indexer backed by the existing
  ## async Node/Git path if desired.
  when defined(js):
    return @[]
  else:
    let root = folderPath.normalizedPath
    if root.len == 0 or not dirExists(root):
      return @[]
    for path in walkDirRec(root):
      let name = path.extractFilename
      if name.len == 0:
        continue
      if path.splitPath.head.split(DirSep).anyIt(it in [
        ".git", ".hg", ".svn", "node_modules", ".direnv", ".devenv",
        "result", "dist", "build", ".next", ".cache"]):
        continue
      if fileExists(path):
        result.add(path)

proc basename(path: string): string =
  when defined(js):
    let normalized = path.replace('\\', '/').strip(leading = false, chars = {'/'})
    let parts = normalized.split('/')
    if parts.len == 0: "" else: parts[^1]
  else:
    path.extractFilename

proc defaultSessionFactory(): SessionViewModel =
  let mock = newMockBackendService(autoRespond = true)
  createSessionVM(mock.toBackendService())

proc defaultSessionFactoryClosure(): SessionViewModel =
  defaultSessionFactory()

proc defaultFolderIndexerClosure(folderPath: string): seq[string] =
  defaultFolderIndexer(folderPath)

proc newAppSession(
    session: SessionViewModel;
    kind: AppSessionKind;
    title: string): AppSessionVM =
  AppSessionVM(
    session: session,
    welcomeVM: createWelcomeScreenVM(session.store),
    kind: createSignal(kind),
    title: createSignal(title),
    editFolderPath: createSignal(""),
    indexedFiles: createSignal(newSeq[string]()),
    openFiles: createSignal(newSeq[string]()),
  )

proc normalizeFactory(createSession: SessionFactory): SessionFactory =
  if createSession.isNil:
    result = proc(): SessionViewModel = defaultSessionFactoryClosure()
  else:
    result = createSession

proc normalizeIndexer(indexFolder: FolderIndexer): FolderIndexer =
  if indexFolder.isNil:
    result = proc(folderPath: string): seq[string] =
      defaultFolderIndexerClosure(folderPath)
  else:
    result = indexFolder

proc createCodeTracerAppVM*(
    createSession: SessionFactory = nil;
    indexFolder: FolderIndexer = nil): CodeTracerAppVM =
  ## Create the app-level ViewModel. By default it starts with one welcome
  ## session and uses in-memory/mock services so every operation is executable
  ## without Electron.
  let sessionFactory = normalizeFactory(createSession)
  let folderIndexer = normalizeIndexer(indexFolder)

  withViewModel proc(dispose: proc()): CodeTracerAppVM =
    let first = newAppSession(sessionFactory(), askWelcome, "Welcome")
    CodeTracerAppVM(
      sessions: createSignal(@[first]),
      activeSessionIndex: createSignal(0),
      createSession: sessionFactory,
      indexFolder: folderIndexer,
      disposeProc: dispose,
    )

proc createCodeTracerAppVMWithInitialSession*(
    initialSession: SessionViewModel;
    indexFolder: FolderIndexer = nil): CodeTracerAppVM =
  ## Production adapter constructor: wrap the already-real initial
  ## SessionViewModel, while future tabs can still use the default/mock
  ## session factory until their real per-session ViewModels are wired.
  let folderIndexer = normalizeIndexer(indexFolder)
  withViewModel proc(dispose: proc()): CodeTracerAppVM =
    let first = newAppSession(initialSession, askWelcome, "Welcome")
    CodeTracerAppVM(
      sessions: createSignal(@[first]),
      activeSessionIndex: createSignal(0),
      createSession: proc(): SessionViewModel = defaultSessionFactoryClosure(),
      indexFolder: folderIndexer,
      disposeProc: dispose,
    )

# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

proc activeSession*(vm: CodeTracerAppVM): AppSessionVM =
  let sessions = vm.sessions.val
  let index = vm.activeSessionIndex.val
  if index < 0 or index >= sessions.len:
    return nil
  sessions[index]

proc sessionCount*(vm: CodeTracerAppVM): int =
  vm.sessions.val.len

# ---------------------------------------------------------------------------
# App actions
# ---------------------------------------------------------------------------

proc createWelcomeTab*(vm: CodeTracerAppVM): int =
  ## Create a new welcome tab and switch to it.
  var sessions = vm.sessions.val
  let index = sessions.len
  sessions.add(newAppSession(vm.createSession(), askWelcome,
    "New Trace " & $(index + 1)))
  vm.sessions.val = sessions
  vm.activeSessionIndex.val = index
  index

proc switchSession*(vm: CodeTracerAppVM; index: int): bool =
  ## Switch active tab/session. Returns false for invalid indexes.
  if index < 0 or index >= vm.sessions.val.len:
    return false
  vm.activeSessionIndex.val = index
  true

proc openFile*(vm: CodeTracerAppVM; path: string): bool =
  ## Open/select a file in the active session. This is the headless equivalent
  ## of the Files panel click and command-palette file result.
  let appSession = vm.activeSession
  if appSession.isNil or path.len == 0:
    return false

  var files = appSession.openFiles.val
  if path notin files:
    files.add(path)
    appSession.openFiles.val = files

  var dbg = appSession.session.store.debugger.val
  dbg.location = Location(file: path, line: max(1, dbg.location.line), column: 0)
  appSession.session.store.debugger.val = dbg
  appSession.session.editorVM.switchTab(files.find(path))
  true

proc openFolder*(vm: CodeTracerAppVM; folderPath: string): bool =
  ## Enter edit mode for a folder and open the first indexed file if present.
  let appSession = vm.activeSession
  if appSession.isNil or folderPath.len == 0:
    return false

  let files = vm.indexFolder(folderPath)
  appSession.kind.val = askEdit
  appSession.title.val = basename(folderPath)
  appSession.editFolderPath.val = folderPath
  appSession.indexedFiles.val = files
  appSession.welcomeVM.enterEditMode(folderPath)

  if files.len > 0:
    discard vm.openFile(files[0])
  true

proc invokeDebugAction*(vm: CodeTracerAppVM; actionId: string): bool =
  ## Route a toolbar/menu debug action through the active session VM.
  let appSession = vm.activeSession
  if appSession.isNil:
    return false
  appSession.session.debugControlsVM.invokeToolbarStep(actionId)
  true

proc dispatchShortcut*(vm: CodeTracerAppVM; shortcut: string): bool =
  ## Headless keyboard shortcut dispatcher for app-level tests. The renderer
  ## should call this same operation after converting browser events to strings.
  case shortcut.toLowerAscii
  of "f10":
    vm.invokeDebugAction("next")
  of "shift+f10":
    vm.invokeDebugAction("reverse-next")
  of "f11":
    vm.invokeDebugAction("step-in")
  of "shift+f11":
    vm.invokeDebugAction("step-out")
  of "f5":
    vm.invokeDebugAction("continue")
  of "shift+f5":
    vm.invokeDebugAction("reverse-continue")
  else:
    false
