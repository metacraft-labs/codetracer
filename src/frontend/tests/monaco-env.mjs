/**
 * Bootstrap a minimal browser environment for Monaco in Node.js
 *
 * This must be imported BEFORE monaco-editor to set up the required globals.
 */

import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { JSDOM } = require('../../../node-packages/node_modules/jsdom');

const dom = new JSDOM('<!DOCTYPE html><html><body></body></html>', {
  url: 'http://localhost',
  pretendToBeVisual: true
});

// Use globalThis instead of global for better compatibility
globalThis.window = dom.window;
globalThis.self = dom.window;
globalThis.document = dom.window.document;

// Node 22 has navigator as a getter-only property, so we need to delete it first
// or use Object.defineProperty
try {
  delete globalThis.navigator;
} catch (e) {
  // Ignore if can't delete
}
Object.defineProperty(globalThis, 'navigator', {
  value: dom.window.navigator,
  writable: true,
  configurable: true
});

// DOM types Monaco may reference
globalThis.HTMLElement = dom.window.HTMLElement;
globalThis.Element = dom.window.Element;
globalThis.Node = dom.window.Node;
globalThis.NodeList = dom.window.NodeList;
globalThis.DocumentFragment = dom.window.DocumentFragment;
globalThis.Range = dom.window.Range;
globalThis.DOMParser = dom.window.DOMParser;
globalThis.XMLSerializer = dom.window.XMLSerializer;
globalThis.Event = dom.window.Event;
globalThis.CustomEvent = dom.window.CustomEvent;
globalThis.KeyboardEvent = dom.window.KeyboardEvent;
globalThis.MouseEvent = dom.window.MouseEvent;

// APIs Monaco may touch
globalThis.getComputedStyle = dom.window.getComputedStyle;
globalThis.requestAnimationFrame = (cb) => setTimeout(cb, 16);
globalThis.cancelAnimationFrame = (id) => clearTimeout(id);

// matchMedia needs to be on both globalThis AND window object
const matchMediaStub = () => ({
  matches: false,
  media: '',
  onchange: null,
  addListener: () => {},
  removeListener: () => {},
  addEventListener: () => {},
  removeEventListener: () => {},
  dispatchEvent: () => true,
});

globalThis.matchMedia = matchMediaStub;
// Also add to the window object directly since Monaco imports it as mainWindow = window
dom.window.matchMedia = matchMediaStub;

// ResizeObserver stub
globalThis.ResizeObserver = class ResizeObserver {
  constructor(callback) {}
  observe() {}
  unobserve() {}
  disconnect() {}
};

// IntersectionObserver stub
globalThis.IntersectionObserver = class IntersectionObserver {
  constructor(callback) {}
  observe() {}
  unobserve() {}
  disconnect() {}
};

// MutationObserver (jsdom should have this, but ensure it's global)
globalThis.MutationObserver = dom.window.MutationObserver;

// Performance API
globalThis.performance = dom.window.performance || {
  now: () => Date.now(),
  mark: () => {},
  measure: () => {},
  getEntriesByName: () => [],
  getEntriesByType: () => [],
};

// CSS API that Monaco uses
globalThis.CSS = {
  escape: (str) => str.replace(/([^\w-])/g, '\\$1'),
  supports: () => false,
};

// Clipboard API stub
globalThis.ClipboardEvent = dom.window.ClipboardEvent || class ClipboardEvent extends Event {
  constructor(type, eventInitDict) {
    super(type, eventInitDict);
  }
};

console.log('Monaco browser environment initialized.');
