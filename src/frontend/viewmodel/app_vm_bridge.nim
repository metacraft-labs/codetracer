## Runtime bridge for gradually adapting the legacy renderer to CodeTracerAppVM.
##
## This module is intentionally tiny: legacy UI modules can report production
## operations here without importing the full renderer or Electron code. The
## behavior lives in app_vm.nim and is covered by native headless tests.

import session_vm
import app_vm

var activeAppVM*: CodeTracerAppVM

proc resetAppVMBridgeForTests*() =
  activeAppVM = nil

proc initAppVMBridge*(initialSession: SessionViewModel) =
  if activeAppVM.isNil:
    activeAppVM = createCodeTracerAppVMWithInitialSession(initialSession)

proc noteWelcomeTabCreated*(): int =
  if activeAppVM.isNil:
    return -1
  activeAppVM.createWelcomeTab()

proc noteSessionSwitched*(index: int): bool =
  if activeAppVM.isNil:
    return false
  activeAppVM.switchSession(index)

proc noteFolderOpened*(folderPath: string; indexedFiles: seq[string] = @[]): bool =
  if activeAppVM.isNil:
    return false
  if indexedFiles.len > 0:
    let previousIndexer = activeAppVM.indexFolder
    activeAppVM.indexFolder = proc(path: string): seq[string] = indexedFiles
    result = activeAppVM.openFolder(folderPath)
    activeAppVM.indexFolder = previousIndexer
  else:
    result = activeAppVM.openFolder(folderPath)

proc noteFileOpened*(path: string): bool =
  if activeAppVM.isNil:
    return false
  activeAppVM.openFile(path)

proc dispatchDebugAction*(actionId: string): bool =
  if activeAppVM.isNil:
    return false
  activeAppVM.invokeDebugAction(actionId)

proc dispatchShortcut*(shortcut: string): bool =
  if activeAppVM.isNil:
    return false
  activeAppVM.dispatchShortcut(shortcut)
