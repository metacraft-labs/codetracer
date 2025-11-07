import * as monaco from 'monaco-editor';
window.monaco = monaco;

import 'vscode/localExtensionHost';

import { MonacoLanguageClient } from 'monaco-languageclient';
window.MonacoLanguageClient = MonacoLanguageClient;
import { MonacoVscodeApiWrapper } from 'monaco-languageclient/vscodeApiWrapper';
window.MonacoVscodeApiWrapper = MonacoVscodeApiWrapper;
import { useWorkerFactory } from 'monaco-languageclient/workerFactory';
import { toSocket, WebSocketMessageReader, WebSocketMessageWriter } from 'vscode-ws-jsonrpc';
window.VscodeWsJsonrpc = { toSocket, WebSocketMessageReader, WebSocketMessageWriter };

const monacoWorkerFactory = () => {
  const toWorker = (relativePath) =>
    new Worker(new URL(relativePath, window.location.href), { type: 'module' });

  useWorkerFactory({
    workerLoaders: {
      TextEditorWorker: () => toWorker('../node_modules/monaco-editor/esm/vs/editor/editor.worker.js'),
      json: () => toWorker('../node_modules/monaco-editor/esm/vs/language/json/json.worker.js')
    }
  });
};

window.monacoServicesReadyFlag = false;
window.monacoServicesReady = (async () => {
  try {
    window.monacoApiWrapper = new MonacoVscodeApiWrapper({
      $type: 'classic',
      viewsConfig: { $type: 'EditorService' },
      monacoWorkerFactory
    });
    await window.monacoApiWrapper.start();
    window.monacoServicesReadyFlag = true;
  } catch (error) {
    console.error('[monaco services] initialization failed', error);
    window.monacoServicesReadyFlag = false;
  }
})();

import { GoldenLayout, VirtualLayout, LayoutManager, LayoutConfig, ItemConfig } from 'golden-layout';
window.GoldenLayout = GoldenLayout;
window.VirtualLayout = VirtualLayout;
window.LayoutManager = LayoutManager;
window.LayoutConfig = LayoutConfig;
window.ItemConfig = ItemConfig;

import fuzzysort from 'fuzzysort';
window.fuzzysort = fuzzysort;

import wNumb from 'wnumb';
window.wNumb = wNumb;

import * as ansi_up from 'ansi_up';
window.AnsiUp = ansi_up.AnsiUp;

let tippy_library = require('tippy.js');
window.tippy = tippy_library.default;

let nouislider_library = require('nouislider');
window.noUiSlider = nouislider_library.default;
// TODO popper?

window.jQuery = require('jquery');

window.Chart = require('chart.js');
window.xtermLib = require('xterm');
window.fitAddonLib = require('xterm-addon-fit');
require('datatables.net');
require('datatables.net-scroller');
window.Mousetrap = require('mousetrap');
// window.io = require('socket.io');

console.log(monaco);
