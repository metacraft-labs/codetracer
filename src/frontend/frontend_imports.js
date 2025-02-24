import * as monaco from 'monaco-editor';
window.monaco = monaco;

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
