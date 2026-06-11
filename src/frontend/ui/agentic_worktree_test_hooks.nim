## Test bridge for the M7 worktree-isolated agentic workflow.
##
## The hook only supplies deterministic test configuration and native external
## actions.  The product-visible launch/open/switch/evidence/cancel lifecycle
## is owned by ``agentic_session_launcher`` on the active ``ReplayDataStore``.

import std/json

import ui_imports
import ../viewmodel/store/replay_data_store
import agentic_session_launcher

var
  installed = false
  sharedStore: ReplayDataStore

when defined(js):
  proc runExternalAction(command, inputRaw: cstring): cstring {.importjs: """
    (function(command, inputRaw) {
      var input = JSON.parse(String(inputRaw || '{}'));
      var fs = require('fs');
      var path = require('path');
      var childProcess = require('child_process');
      var artifactDir = String(input.artifactDir || '');
      if (!artifactDir) throw new Error('artifactDir is required');
      if (!input.bridgeExecutable) throw new Error('bridgeExecutable is required');
      fs.mkdirSync(artifactDir, { recursive: true });
      var payloadPath = path.join(artifactDir, 'frontend-bridge-payload.json');
      fs.writeFileSync(payloadPath, JSON.stringify(input, null, 2), 'utf8');
      return childProcess.execFileSync(
        String(input.bridgeExecutable),
        [String(command), payloadPath],
        {
          cwd: String(input.repoRoot || process.cwd()),
          encoding: 'utf8',
          timeout: 120000
        });
    })(#, #)
  """.}

  proc runExternalActionAdapter(command, inputRaw: cstring): cstring =
    runExternalAction(command, inputRaw)

  proc dispatchProductLauncher(command, inputRaw: cstring): cstring =
    if sharedStore.isNil:
      raise newException(ValueError,
        "M7 test hook was installed without the active ReplayDataStore")
    if currentAgenticSessionLauncher.isNil:
      discard installAgenticSessionLauncher(sharedStore, runExternalActionAdapter)

    case $command
    of "start":
      currentAgenticSessionLauncher.startWorktreeAgentSession(inputRaw)
    of "open":
      currentAgenticSessionLauncher.openAgentTab()
    of "user":
      currentAgenticSessionLauncher.restoreUserWorkspace()
    of "evidence":
      currentAgenticSessionLauncher.waitForEvidenceDeepReview()
    of "cancel-recover":
      currentAgenticSessionLauncher.cancelAndRecover(inputRaw)
    else:
      raise newException(ValueError, "unknown M7 product bridge command: " &
        $command)

  proc installJsHook(dispatch: proc(command, inputRaw: cstring): cstring) {.importjs: """
    (function(dispatch) {
      window.__CODETRACER_TEST__ = window.__CODETRACER_TEST__ || {};
      var lastInput = null;
      function call(command, input) {
        if (input) lastInput = input;
        var payload = input || lastInput || {};
        return JSON.parse(String(dispatch(command, JSON.stringify(payload))));
      }
      window.__CODETRACER_TEST__.agenticWorktree = {
        productLauncher: 'CodeTracerAgenticSessionLauncher',
        startWorktreeAgentSession: function(input) { return call('start', input); },
        openAgentTab: function(input) { return call('open', input); },
        switchToUserWorkspace: function(input) { return call('user', input); },
        waitForEvidenceDeepReview: function(input) { return call('evidence', input); },
        cancelAndRecover: function(input) { return call('cancel-recover', input); }
      };
    })(#)
  """.}

proc installAgenticWorktreeTestHooks*(store: ReplayDataStore) =
  when defined(js):
    if installed or not data.startOptions.inTest:
      return
    sharedStore = store
    discard installAgenticSessionLauncher(sharedStore, runExternalActionAdapter)
    installJsHook(dispatchProductLauncher)
    installed = true

proc agenticWorktreeLauncherState*(): JsonNode =
  if currentAgenticSessionLauncher.isNil:
    return %*{"installed": false}
  %*{
    "installed": true,
    "productLauncher": ProductLauncherName,
    "hasLastSnapshot": not currentAgenticSessionLauncher.lastSnapshot.isNil
  }
