import { expect } from "@storybook/test";

declareMount();

let loadPromise = null;

function declareMount() {
  if (typeof window !== "undefined" && !window.__codetracerStorybookLoaded) {
    window.__codetracerStorybookLoaded = false;
  }
}

function ensureComponentsLoaded() {
  if (typeof mountCodeTracerStory !== "undefined") {
    return Promise.resolve();
  }

  if (!loadPromise) {
    loadPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "./dist/components.js";
      script.onload = () => {
        window.__codetracerStorybookLoaded = true;
        resolve();
      };
      script.onerror = () =>
        reject(
          new Error(
            "Failed to load storybook/dist/components.js. Run: just build-storybook-components",
          ),
        );
      document.head.appendChild(script);
    });
  }

  return loadPromise;
}

function tick() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function titleize(name) {
  return name
    .split("-")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function injectSurfaceStyles(container) {
  const style = document.createElement("style");
  style.textContent = `
    .ct-storybook-surface {
      box-sizing: border-box;
      min-height: 0;
      padding: 0;
      background: #1b1b1b;
    }

    .ct-storybook-frame {
      box-sizing: border-box;
      width: 100%;
      height: 100%;
      min-height: 100%;
      overflow: auto;
    }

    .ct-storybook-root-container {
      top: 0 !important;
      height: 100vh !important;
    }

    .ct-storybook-karax-root-container {
      top: 2.27em !important;
      height: calc(100vh - 2.27em - 2em) !important;
      width: auto !important;
      max-width: none !important;
    }

    .ct-storybook-karax-root-container #ROOT {
      flex: 0 0 auto !important;
      width: calc(100vw - 0.5em) !important;
      min-width: 0;
    }

    .ct-storybook-karax-root-container #main.ct-storybook-frame {
      min-height: 0;
      height: 0;
      overflow: hidden;
    }

    .ct-storybook-golden-panel {
      box-sizing: border-box;
      display: flex;
      flex: 1 1 100%;
      flex-direction: column;
      width: 100%;
      min-width: 0;
      min-height: 0;
      height: 100%;
      font-size: 16px;
      line-height: 24px;
    }

    .ct-storybook-golden-panel .lm_stack {
      box-sizing: border-box;
      display: flex;
      flex: 1 1 100%;
      flex-direction: column;
      min-width: 0;
      min-height: 0;
      width: 100%;
      height: 100%;
    }

    .ct-storybook-golden-panel .lm_header {
      box-sizing: border-box;
      display: flex;
      align-items: flex-end;
      flex: 0 0 30px;
      min-height: 30px;
      height: 30px !important;
      overflow: visible;
    }

    .ct-storybook-golden-panel .lm_tabs {
      box-sizing: border-box;
      align-items: flex-end;
      height: 30px;
      margin: 0;
      padding: 0 30px 0 0;
    }

    .ct-storybook-golden-panel .lm_controls {
      box-sizing: border-box;
      display: flex !important;
      align-items: center !important;
      height: 30px !important;
      top: 0 !important;
      right: 0 !important;
    }

    .ct-storybook-golden-panel .lm_controls > * {
      box-sizing: border-box;
      width: 16px !important;
      height: 16px !important;
      margin-top: 0 !important;
    }

    .ct-storybook-default-layout {
      box-sizing: border-box;
      display: block;
      min-height: 0;
      font-size: 16px;
      line-height: 24px;
    }

    .ct-storybook-default-layout .lm_row,
    .ct-storybook-default-layout .lm_column {
      box-sizing: border-box;
      min-width: 0;
      min-height: 0;
      overflow: visible;
    }

    .ct-storybook-default-layout > .lm_row {
      overflow: visible;
    }

    .ct-storybook-default-layout .lm_stack {
      box-sizing: border-box;
      min-width: 0;
      min-height: 0;
      overflow: hidden;
    }

    .ct-storybook-default-layout .lm_header {
      box-sizing: border-box;
      height: 32px !important;
      min-height: 32px;
      overflow: visible;
    }

    .ct-storybook-default-layout .lm_items {
      box-sizing: border-box;
      min-height: 0;
      overflow: hidden;
    }

    .ct-storybook-default-layout .lm_items > div,
    .ct-storybook-default-layout .lm_content,
    .ct-storybook-default-layout .ct-storybook-panel-content {
      box-sizing: border-box;
      width: 100%;
      height: 100%;
      min-width: 0;
      min-height: 0;
    }

    .ct-storybook-default-layout .lm_hidden_item {
      display: none;
    }

    .ct-storybook-default-layout .lm_splitter {
      box-sizing: border-box;
      display: block;
      position: relative;
      min-width: 0;
      min-height: 0;
    }

    .ct-storybook-default-layout .lm_splitter.lm_horizontal {
      float: left;
      height: 100%;
      width: 4px !important;
    }

    .ct-storybook-default-layout .lm_splitter.lm_vertical {
      height: 4px !important;
      width: 100%;
      clear: both;
    }

    .ct-storybook-default-layout .lm_drag_handle {
      position: absolute;
    }

    .ct-storybook-default-layout .lm_splitter.lm_horizontal .lm_drag_handle {
      left: -0.5px !important;
      width: 5px !important;
      height: 100%;
    }

    .ct-storybook-default-layout .lm_splitter.lm_vertical .lm_drag_handle {
      top: -0.5px !important;
      height: 5px !important;
      width: 100%;
    }

    .ct-storybook-default-layout .ct-storybook-panel-content > .component-container,
    .ct-storybook-default-layout .ct-storybook-panel-content > .build-panel,
    .ct-storybook-default-layout .ct-storybook-panel-content > .panel {
      box-sizing: border-box;
      width: 100%;
      height: 100%;
      min-width: 0;
      min-height: 0;
    }

    .ct-storybook-golden-panel .lm_items {
      box-sizing: border-box;
      display: flex;
      flex: 1 1 auto;
      min-height: 0;
      width: 100%;
    }

    .ct-storybook-golden-panel .lm_content {
      box-sizing: border-box;
      display: flex;
      flex: 1 1 100%;
      min-width: 0;
      min-height: 0;
      width: 100%;
      height: 100%;
    }

    .ct-storybook-panel-content {
      box-sizing: border-box;
      display: flex;
      flex: 1 1 100%;
      min-width: 0;
      min-height: 0;
      width: 100%;
      height: 100%;
    }

    .ct-storybook-panel-content > .component-container,
    .ct-storybook-panel-content > .component-container.terminal,
    .ct-storybook-panel-content > .terminal,
    .ct-storybook-panel-content > .build-panel,
    .ct-storybook-panel-content > .panel {
      box-sizing: border-box;
      flex: 1 1 100%;
      width: 100%;
      min-width: 0;
      height: 100%;
      min-height: 0;
    }

    .ct-storybook-frame > .component-container,
    .ct-storybook-frame > .component-container.terminal,
    .ct-storybook-frame > .terminal,
    .ct-storybook-frame > .build-panel,
    .ct-storybook-frame > .panel,
    .ct-storybook-frame > .isonim-app-shell {
      box-sizing: border-box;
      flex: 1 1 100%;
      width: 100%;
      min-width: 0;
      min-height: 100vh;
    }

    .ct-storybook-default-layout .code-editor {
      box-sizing: border-box;
      width: 100% !important;
      height: 100% !important;
      min-width: 0;
      min-height: 0;
      overflow: hidden !important;
      background: transparent;
    }

    .ct-storybook-editor-fixture {
      box-sizing: border-box;
      position: relative;
      width: 100%;
      height: 100%;
      overflow: hidden;
      color: #d8d8d8;
      font-family: "FiraCode", monospace;
      font-size: 16px;
      line-height: 25px;
      background: transparent !important;
    }

    .ct-storybook-editor-fixture .overflow-guard {
      box-sizing: border-box;
      position: absolute;
      inset: 0;
      overflow: hidden;
    }

    .ct-storybook-editor-fixture .margin {
      box-sizing: border-box;
      position: absolute;
      left: 0;
      top: 0;
      width: 91px;
      height: 100%;
      contain: strict;
    }

    .ct-storybook-editor-fixture .margin-view-overlays {
      box-sizing: border-box;
      position: absolute;
      inset: 0;
      font-family: "FiraCode", monospace;
      font-size: 16px;
      line-height: 22px;
    }

    .ct-storybook-editor-fixture .monaco-scrollable-element {
      box-sizing: border-box;
      position: absolute;
      inset: 0;
      overflow: hidden;
    }

    .ct-storybook-editor-fixture .lines-content {
      box-sizing: border-box;
      position: absolute;
      left: 91px;
      top: 0;
      min-width: max-content;
      height: 100%;
    }

    .ct-storybook-editor-fixture .view-lines {
      box-sizing: border-box;
      display: flex;
      flex-direction: column;
      min-width: max-content;
    }

    .ct-storybook-editor-fixture .view-line {
      box-sizing: border-box;
      height: 22px;
      line-height: 22px;
      white-space: pre;
      color: #e3e3e3;
      font-family: "FiraCode", monospace !important;
      font-weight: 400;
      min-width: 38em;
    }

    .ct-storybook-editor-fixture .margin-view-overlays > div {
      box-sizing: border-box;
      position: relative;
      height: 22px;
      line-height: 22px;
    }

    .ct-storybook-editor-fixture .line-numbers {
      box-sizing: border-box;
      position: absolute;
      left: 0;
      width: 39px !important;
      color: #858585;
      text-align: right;
      user-select: none;
    }

    .ct-storybook-editor-fixture .gutter {
      width: 39px !important;
    }

    .ct-storybook-editor-fixture .gutter .gutter-line {
      width: 39px !important;
      margin-left: 0 !important;
      margin-right: 0 !important;
      padding-right: 0.15em !important;
    }

    .ct-storybook-editor-fixture .active-line-number {
      color: #d3d3d3;
    }

    .ct-storybook-editor-fixture .folding {
      color: #c4c4c4;
      display: inline-flex !important;
      position: absolute !important;
      left: 39px;
      width: 52px !important;
      height: 22px;
      align-items: center;
      justify-content: center;
      text-align: center;
      user-select: none;
    }

    .ct-storybook-editor-fixture .gutter-highlight-active {
      position: absolute;
      inset: 0;
    }

    .ct-storybook-editor-fixture .gutter-highlight-active:before {
      content: "";
      position: absolute;
      top: 50%;
      left: 2px;
      width: 0;
      height: 0;
      border-top: 6px solid transparent;
      border-bottom: 6px solid transparent;
      border-left: 10px solid #ffd23f;
      transform: translateY(-50%);
      z-index: 2;
    }

    .ct-storybook-editor-fixture .current-line {
      background: #555;
    }

    .ct-storybook-editor-fixture .current-arrow {
      color: #ffd23f;
      display: inline-block;
      width: 1.1em;
      margin-left: -1.1em;
      padding-right: 0.35em;
    }

    .ct-storybook-editor-fixture .token-keyword,
    .ct-storybook-editor-fixture .token-function {
      color: #4fa8e8;
    }

    .ct-storybook-editor-fixture .token-comment {
      color: #72ad6b;
    }

    .ct-storybook-editor-fixture .token-string {
      color: #d79d7f;
    }

    .ct-storybook-editor-fixture .token-number,
    .ct-storybook-editor-fixture .token-type {
      color: #b6e8c4;
    }

    .ct-storybook-editor-fixture .token-punctuation {
      color: #f0cb4b;
    }

    .ct-storybook-editor-fixture .token-operator {
      color: #9d72ff;
    }

    .ct-storybook-editor-fixture .indent-guide {
      position: absolute;
      top: 264px;
      bottom: 0;
      left: 194px;
      width: 1px;
      background: rgba(142, 142, 142, 0.35);
      pointer-events: none;
    }

    .ct-storybook-editor-fixture .selected-text {
      background: rgba(96, 96, 96, 0.82);
    }

    .ct-storybook-editor-fixture .scrollbar.vertical {
      position: absolute;
      top: 0;
      right: 0;
      width: 0.875rem;
      height: 100%;
      background: transparent;
    }

    .ct-storybook-editor-fixture .scrollbar.vertical .slider {
      position: absolute;
      top: 62px;
      right: 0;
      width: 0.875rem;
      height: 22%;
      background: rgba(123, 123, 123, 0.72);
    }

  `;
  container.appendChild(style);
}

const storybookEditorLines = [
  [{ t: "mod", c: "token-keyword" }, { t: " shield;" }],
  [],
  [{ t: "// We are on a space ship, moving through an asteroid field.", c: "token-comment" }],
  [{ t: "// We are about to pass through an asteroid field.", c: "token-comment" }],
  [{ t: "// We have to prove to everyone we can survive.", c: "token-comment" }],
  [],
  [{ t: "// We need to have at least 1 unit of shield after passing the field.", c: "token-comment" }],
  [],
  [{ t: "// We can not reveal how much shield we still have.", c: "token-comment" }],
  [{ t: "// The space pirates can track our diagnostics channel.", c: "token-comment" }],
  [],
  [
    { t: "fn", c: "token-keyword" },
    { t: " main(initial_shield: Field, shield_regen_percentage: Field) {" },
  ],
  [
    { t: "    " },
    { t: "println", c: "token-function" },
    { t: "(" },
    { t: "\"Positive Test Case\"", c: "token-string" },
    { t: ")" },
  ],
  [],
  [{ t: "    " }, { t: "let", c: "token-keyword" }, { t: " did_survive_positive = shield::iterate_asteroids(" }],
  [{ t: "    " }, { t: "if", c: "token-keyword" }, { t: "(did_survive_positive)" }, { t: "{", c: "token-operator" }],
  [
    { t: "        " },
    { t: "println", c: "token-function" },
    { t: "(" },
    { t: "\"shields will hold as expected\"", c: "token-string" },
    { t: ")" },
  ],
  [{ t: "    " }, { t: "}", c: "token-operator" }],
  [{ t: "    " }, { t: "else", c: "token-keyword" }, { t: "{", c: "token-operator" }],
  [
    { t: "        " },
    { t: "println", c: "token-function" },
    { t: "(" },
    { t: "\"shields will not hold as expected\"", c: "token-string" },
    { t: ")" },
  ],
  [{ t: "    " }, { t: "}", c: "token-operator" }],
  [],
  [{ t: "    " }, { t: "println", c: "token-function" }, { t: "(\"------------------\")", c: "token-string" }],
  [{ t: "    " }, { t: "println", c: "token-function" }, { t: "(\"Negative Test Case\")", c: "token-string" }],
  [{ t: "    " }, { t: "println", c: "token-function" }, { t: "(\"------------------\")", c: "token-string" }],
  [],
  [{ t: "    " }, { t: "let", c: "token-keyword" }, { t: " did_survive_negative = shield::iterate_asteroids(" }],
  [{ t: "    " }, { t: "if", c: "token-keyword" }, { t: "(did_survive_negative)" }, { t: "{", c: "token-operator" }],
  [
    { t: "        " },
    { t: "println", c: "token-function" },
    { t: "(" },
    { t: "\"shields will hold, but should not\"", c: "token-string" },
    { t: ")" },
  ],
  [{ t: "    " }, { t: "}", c: "token-operator" }],
  [{ t: "    " }, { t: "else", c: "token-keyword" }, { t: "{", c: "token-operator" }],
  [
    { t: "        " },
    { t: "println", c: "token-function" },
    { t: "(" },
    { t: "\"shields will not hold as expected\"", c: "token-string" },
    { t: ")" },
  ],
  [{ t: "    " }, { t: "}", c: "token-operator" }],
  [],
  [{ t: "    assert(did_survive_positive == true);" }],
  [{ t: "    assert(did_survive_negative == false);" }],
  [{ t: "    did_survive_positive & !did_survive_negative" }],
  [{ t: "}", c: "token-punctuation" }],
  [],
  [{ t: "fn", c: "token-keyword" }, { t: " calculate_remaining_shield_pct(initial_shield: Field) -> Field {" }],
  [{ t: "  initial_shield / 100", c: "token-number" }],
  [{ t: "}", c: "token-punctuation" }],
];

function appendToken(parent, token) {
  const span = document.createElement("span");
  if (token.c) span.className = token.c;
  span.textContent = token.t;
  parent.appendChild(span);
}

function installStorybookEditorFixture(mount) {
  const host = mount.querySelector(".code-editor");
  if (!host || host.querySelector(".ct-storybook-editor-fixture")) return;
  host.id = "editorComponent-0";
  host.dataset.label = "/home/zahary/metacraft/codetracer-main/test-programs/noir_space_ship/src/main.nr";

  const editor = document.createElement("div");
  editor.className =
    "monaco-editor no-user-select showUnused showDeprecated vs-dark ct-storybook-editor-fixture";
  editor.setAttribute("role", "code");
  editor.dataset.uri = "inmemory://model/storybook-default-layout";

  const guard = document.createElement("div");
  guard.className = "overflow-guard";
  guard.dataset.mprt = "3";

  const margin = document.createElement("div");
  margin.className = "margin";
  margin.setAttribute("role", "presentation");
  margin.setAttribute("aria-hidden", "true");
  const marginOverlays = document.createElement("div");
  marginOverlays.className = "margin-view-overlays";
  marginOverlays.setAttribute("role", "presentation");
  marginOverlays.setAttribute("aria-hidden", "true");

  const scrollable = document.createElement("div");
  scrollable.className = "monaco-scrollable-element";
  const lines = document.createElement("div");
  lines.className = "lines-content";
  const viewLines = document.createElement("div");
  viewLines.className = "view-lines";

  storybookEditorLines.forEach((tokens, index) => {
    const lineNumber = index + 1;
    const marginRow = document.createElement("div");
    if (lineNumber === 13) {
      const currentMargin = document.createElement("div");
      currentMargin.className = "current-line current-line-margin-both";
      marginRow.appendChild(currentMargin);
    }
    const number = document.createElement("div");
    number.className = `line-numbers lh-even${lineNumber === 13 ? " active-line-number" : ""}`;
    const gutter = document.createElement("div");
    gutter.className = "gutter";
    gutter.dataset.line = String(lineNumber);
    if (lineNumber === 13) {
      const activeMarker = document.createElement("div");
      activeMarker.className = "gutter-highlight-active";
      gutter.appendChild(activeMarker);
    }
    const gutterLine = document.createElement("div");
    gutterLine.className = "gutter-line";
    gutterLine.textContent = String(lineNumber);
    gutter.appendChild(gutterLine);
    number.appendChild(gutter);
    marginRow.appendChild(number);

    const folding = document.createElement("div");
    folding.className = "folding";
    if ([12, 16, 19, 28, 32, 39].includes(lineNumber)) folding.textContent = "v";
    marginRow.appendChild(folding);
    marginOverlays.appendChild(marginRow);

    const code = document.createElement("div");
    code.className = `view-line${lineNumber === 13 ? " current-line" : ""}`;
    code.style.height = "22px";
    code.style.lineHeight = "22px";
    if (lineNumber === 13) {
      const selected = document.createElement("span");
      selected.className = "selected-text";
      for (const token of tokens) appendToken(selected, token);
      code.appendChild(selected);
    } else {
      for (const token of tokens) appendToken(code, token);
    }
    viewLines.appendChild(code);
  });

  const indentGuide = document.createElement("div");
  indentGuide.className = "indent-guide";
  const scrollbar = document.createElement("div");
  scrollbar.className = "scrollbar vertical";
  const slider = document.createElement("div");
  slider.className = "slider";
  scrollbar.appendChild(slider);

  lines.appendChild(viewLines);
  scrollable.appendChild(lines);
  margin.appendChild(marginOverlays);
  guard.appendChild(margin);
  guard.appendChild(scrollable);
  guard.appendChild(indentGuide);
  guard.appendChild(scrollbar);
  editor.appendChild(guard);
  host.appendChild(editor);
}

function createGoldenPanelHost(frame, title) {
  const layout = document.createElement("div");
  layout.className = "lm_goldenlayout lm_item lm_root ct-storybook-golden-panel";

  const stack = document.createElement("div");
  stack.className = "lm_item lm_stack";

  const header = document.createElement("div");
  header.className = "lm_header";

  const tabs = document.createElement("ul");
  tabs.className = "lm_tabs";

  const tab = document.createElement("li");
  tab.className = "lm_tab lm_active";

  const tabTitle = document.createElement("span");
  tabTitle.className = "lm_title";
  tabTitle.textContent = title;
  tab.appendChild(tabTitle);

  const closeTab = document.createElement("div");
  closeTab.className = "lm_close_tab";
  tab.appendChild(closeTab);
  tabs.appendChild(tab);
  header.appendChild(tabs);

  const controls = document.createElement("div");
  controls.className = "lm_controls";
  for (const controlClass of ["lm_maximise", "lm_close"]) {
    const control = document.createElement("div");
    control.className = controlClass;
    controls.appendChild(control);
  }
  header.appendChild(controls);

  const items = document.createElement("div");
  items.className = "lm_items";

  const content = document.createElement("div");
  content.className = "lm_item lm_content";

  const mount = document.createElement("div");
  mount.className = "ct-storybook-panel-content";
  content.appendChild(mount);
  items.appendChild(content);
  stack.appendChild(header);
  stack.appendChild(items);
  layout.appendChild(stack);
  frame.appendChild(layout);

  return mount;
}

function createGoldenStack(tabsConfig) {
  const tabsData = Array.isArray(tabsConfig) ? tabsConfig : [{ title: tabsConfig }];
  const stack = document.createElement("div");
  stack.className = "lm_item lm_stack";

  const header = document.createElement("section");
  header.className = "lm_header";

  const tabs = document.createElement("section");
  tabs.className = "lm_tabs";

  const mounts = [];
  tabsData.forEach((tabData, index) => {
    const tab = document.createElement("div");
    tab.className = `lm_tab${index === 0 ? " lm_active" : ""}`;
    tab.title = tabData.title;

    const tabTitle = document.createElement("span");
    tabTitle.className = "lm_title";
    tabTitle.textContent = tabData.title;
    tab.appendChild(tabTitle);

    const closeTab = document.createElement("div");
    closeTab.className = "lm_close_tab";
    tab.appendChild(closeTab);
    tabs.appendChild(tab);
  });

  const layoutButtons = document.createElement("div");
  layoutButtons.className = "layout-buttons-container";
  layoutButtons.tabIndex = 0;
  const layoutDropdown = document.createElement("div");
  layoutDropdown.id = "layout-dropdown-toggle";
  layoutDropdown.className = "layout-dropdown hidden";
  for (const label of ["Close all", "Maximise container"]) {
    const node = document.createElement("div");
    node.className = "layout-dropdown-node";
    node.textContent = label;
    layoutDropdown.appendChild(node);
  }
  layoutButtons.appendChild(layoutDropdown);
  tabs.appendChild(layoutButtons);
  header.appendChild(tabs);

  const controls = document.createElement("section");
  controls.className = "lm_controls";
  header.appendChild(controls);

  const dropdownList = document.createElement("section");
  dropdownList.className = "lm_tabdropdown_list";
  dropdownList.style.display = "none";
  header.appendChild(dropdownList);

  const items = document.createElement("section");
  items.className = "lm_items";

  tabsData.forEach((tabData, index) => {
    const item = document.createElement("div");
    if (index !== 0) item.className = "lm_hidden_item";
    const content = document.createElement("div");
    content.className = "lm_content";
    const mount = document.createElement("div");
    mount.className = "ct-storybook-panel-content";
    content.appendChild(mount);
    item.appendChild(content);
    items.appendChild(item);
    mounts.push({
      name: tabData.name,
      mount,
      item,
      content,
      active: index === 0,
    });
  });
  stack.appendChild(header);
  stack.appendChild(items);

  return { stack, items, mounts };
}

function createSplitter(orientation) {
  const splitter = document.createElement("div");
  splitter.className = `lm_splitter lm_${orientation}`;

  const handle = document.createElement("div");
  handle.className = "lm_drag_handle";
  splitter.appendChild(handle);

  return splitter;
}

function setBox(element, width, height) {
  element.style.width = `${Math.max(0, Math.round(width))}px`;
  element.style.height = `${Math.max(0, Math.round(height))}px`;
}

function sizeStack(stack, items, width, height) {
  const headerHeight = 32;
  const contentHeight = Math.max(0, height - headerHeight);
  setBox(stack, width, height);
  stack.querySelector(".lm_header").style.height = `${headerHeight}px`;
  setBox(items, width, contentHeight);
  for (const item of items.children) {
    if (item.classList.contains("lm_hidden_item")) continue;
    setBox(item, width, contentHeight);
    const content = item.querySelector(".lm_content");
    if (content) setBox(content, width, contentHeight);
  }
}

function syncDefaultLayoutGeometry(root) {
  const layout = root.querySelector(".ct-storybook-default-layout");
  if (!layout) return;

  const width = root.getBoundingClientRect().width;
  const height = root.getBoundingClientRect().height;
  const splitterSize = 4;
  setBox(layout, width, height);

  const outerRow = layout.querySelector(":scope > .lm_row");
  setBox(outerRow, width, height);

  const leftWidth = Math.max(120, Math.round(width * 0.133));
  const editorWidth = Math.max(240, Math.round(width * 0.331));
  const rightWidth = Math.max(
    240,
    width - leftWidth - editorWidth - splitterSize * 2,
  );
  const rightTopHeight = Math.floor((height - splitterSize) / 2);
  const rightBottomHeight = height - rightTopHeight - splitterSize;
  const rightTopLeftWidth = Math.floor((rightWidth - splitterSize) / 2);
  const rightTopRightWidth = rightWidth - rightTopLeftWidth - splitterSize;

  const boxes = {
    sidebar: { width: leftWidth, height },
    editor: { width: editorWidth, height },
    right: { width: rightWidth, height },
    rightTop: { width: rightWidth, height: rightTopHeight },
    rightTopLeft: { width: rightTopLeftWidth, height: rightTopHeight },
    rightTopRight: { width: rightTopRightWidth, height: rightTopHeight },
    rightBottom: { width: rightWidth, height: rightBottomHeight },
  };

  for (const [name, box] of Object.entries(boxes)) {
    const element = layout.querySelector(`[data-layout-box="${name}"]`);
    if (element) setBox(element, box.width, box.height);
  }

  for (const stack of layout.querySelectorAll(".lm_stack")) {
    const box = boxes[stack.dataset.layoutBox];
    if (box) sizeStack(stack, stack.querySelector(".lm_items"), box.width, box.height);
  }

  for (const splitter of layout.querySelectorAll(".lm_splitter.lm_horizontal")) {
    const parentHeight = splitter.parentElement.getBoundingClientRect().height || height;
    setBox(splitter, splitterSize, parentHeight);
  }
  for (const splitter of layout.querySelectorAll(".lm_splitter.lm_vertical")) {
    const parentWidth = splitter.parentElement.getBoundingClientRect().width || rightWidth;
    setBox(splitter, parentWidth, splitterSize);
  }
}

function appendDefaultDebugLayout(shellRoot) {
  const layoutRoot = document.createElement("div");
  layoutRoot.className = "lm_goldenlayout lm_item lm_root ct-storybook-default-layout";

  const row = document.createElement("div");
  row.className = "lm_item lm_row";

  const leftColumn = document.createElement("div");
  leftColumn.className = "lm_item lm_column ct-storybook-layout-sidebar";
  leftColumn.dataset.layoutBox = "sidebar";

  const editorStackParent = document.createElement("div");
  editorStackParent.className = "lm_item ct-storybook-layout-editor";
  editorStackParent.dataset.layoutBox = "editor";

  const rightColumn = document.createElement("div");
  rightColumn.className = "lm_item lm_column ct-storybook-layout-right";
  rightColumn.dataset.layoutBox = "right";

  const rightTop = document.createElement("div");
  rightTop.className = "lm_item lm_row ct-storybook-layout-right-top";
  rightTop.dataset.layoutBox = "rightTop";

  const rightTopLeft = document.createElement("div");
  rightTopLeft.className = "lm_item";
  rightTopLeft.dataset.layoutBox = "rightTopLeft";

  const rightTopRight = document.createElement("div");
  rightTopRight.className = "lm_item";
  rightTopRight.dataset.layoutBox = "rightTopRight";

  const rightBottom = document.createElement("div");
  rightBottom.className = "lm_item lm_column ct-storybook-layout-right-bottom";
  rightBottom.dataset.layoutBox = "rightBottom";

  const panels = [
    {
      parent: leftColumn,
      layoutBox: "sidebar",
      tabs: [{ title: "FILESYSTEM", name: "filesystem" }],
    },
    {
      parent: editorStackParent,
      layoutBox: "editor",
      tabs: [{ title: "src/main.nr", name: "editor" }],
    },
    {
      parent: rightTopLeft,
      layoutBox: "rightTopLeft",
      fixture: "empty",
      tabs: [
        { title: "STATE", name: "state" },
        { title: "SCRATCHPAD", name: "scratchpad" },
      ],
    },
    {
      parent: rightTopRight,
      layoutBox: "rightTopRight",
      fixture: "reference",
      tabs: [
        { title: "CALLTRACE", name: "calltrace" },
        { title: "AGENT ACTIVITY", name: null },
      ],
    },
    {
      parent: rightBottom,
      layoutBox: "rightBottom",
      tabs: [
        { title: "EVENT LOG", name: "event-log" },
        { title: "TERMINAL OUTPUT", name: "terminal-output" },
      ],
    },
  ];

  const mounts = [];
  for (const panel of panels) {
    const { stack, mounts: stackMounts } = createGoldenStack(panel.tabs);
    stack.dataset.layoutBox = panel.layoutBox;
    stack.dataset.panelName = panel.tabs.map((tab) => tab.name).filter(Boolean).join(" ");
    panel.parent.appendChild(stack);
    mounts.push(...stackMounts.filter(({ name }) => name).map((mountInfo) => ({
      ...mountInfo,
      fixture: panel.fixture,
    })));
  }

  rightTop.appendChild(rightTopLeft);
  rightTop.appendChild(createSplitter("horizontal"));
  rightTop.appendChild(rightTopRight);
  rightColumn.appendChild(rightTop);
  rightColumn.appendChild(createSplitter("vertical"));
  rightColumn.appendChild(rightBottom);
  row.appendChild(leftColumn);
  row.appendChild(createSplitter("horizontal"));
  row.appendChild(editorStackParent);
  row.appendChild(createSplitter("horizontal"));
  row.appendChild(rightColumn);
  layoutRoot.appendChild(row);
  shellRoot.appendChild(layoutRoot);
  syncDefaultLayoutGeometry(shellRoot);
  window.requestAnimationFrame(() => syncDefaultLayoutGeometry(shellRoot));

  return mounts;
}

function createKaraxReferenceShell(container) {
  document.body.classList.add("monaco-workbench", "linux", "web", "enable-motion");

  const menu = document.createElement("div");
  menu.id = "menu";

  const navigation = document.createElement("div");
  navigation.id = "navigation-menu";
  navigation.tabIndex = 0;
  const menuRoot = document.createElement("div");
  menuRoot.id = "menu-root";
  const logo = document.createElement("div");
  logo.id = "menu-logo-img";
  menuRoot.appendChild(logo);
  navigation.appendChild(menuRoot);
  menu.appendChild(navigation);

  const debug = document.createElement("div");
  debug.id = "debug";
  debug.className = "ct-header";
  const debugItems = [
    "history-back-image",
    "history-forward-image",
    "reverse-next-image",
    "next-image",
    "reverse-step-in-image",
    "step-in-image",
    "reverse-step-out-image",
    "step-out-image",
    "debug-run-to-entry-image",
    "run-to-exit-image",
    "run-to-cursor-image",
    "toggle-current-line-breakpoint-image",
    "restart-image",
  ];
  for (const id of debugItems) {
    if (debug.children.length % 5 === 0) {
      const separator = document.createElement("div");
      separator.className = "separate-bar";
      debug.appendChild(separator);
    }
    const button = document.createElement("button");
    button.id = id;
    button.className = "ct-button-image-md-secondary ct-button-no-border";
    debug.appendChild(button);
  }
  const commandView = document.createElement("div");
  commandView.id = "command-view";
  commandView.className = "command-view";
  const commandSurface = document.createElement("div");
  commandSurface.className = "command-surface";
  const commandInput = document.createElement("input");
  commandInput.id = "command-query-text";
  commandInput.className = "mousetrap ct-input-com-pal ct-input-search-image";
  commandInput.type = "text";
  commandInput.name = "command-query";
  commandInput.placeholder = "Navigate to file or run a :command";
  commandSurface.appendChild(commandInput);
  commandView.appendChild(commandSurface);
  debug.appendChild(commandView);
  menu.appendChild(debug);

  const windowMenu = document.createElement("div");
  windowMenu.className = "window-menu";
  for (const className of ["minimize", "maximize", "close"]) {
    const button = document.createElement("div");
    button.className = `menu-button-svg ${className}`;
    windowMenu.appendChild(button);
  }
  menu.appendChild(windowMenu);
  container.appendChild(menu);

  const welcome = document.createElement("div");
  welcome.id = "welcomeScreen";
  container.appendChild(welcome);
  const deepreview = document.createElement("div");
  deepreview.id = "deepreview";
  container.appendChild(deepreview);

  const rootContainer = document.createElement("div");
  rootContainer.id = "root-container";
  rootContainer.className = "container ct-storybook-root-container ct-storybook-karax-root-container";

  const root = document.createElement("div");
  root.id = "ROOT";

  const contextMenu = document.createElement("div");
  contextMenu.id = "context-menu-container";
  contextMenu.style.display = "none";
  root.appendChild(contextMenu);

  const fixedSearch = document.createElement("div");
  fixedSearch.id = "fixed-search";
  fixedSearch.className = "fixed-search-non-active";
  root.appendChild(fixedSearch);

  const frame = document.createElement("section");
  frame.id = "main";
  frame.className = "ct-storybook-frame";
  root.appendChild(frame);

  rootContainer.appendChild(root);
  container.appendChild(rootContainer);

  const footer = document.createElement("footer");
  const status = document.createElement("div");
  status.id = "status";
  const activeNotifications = document.createElement("div");
  activeNotifications.id = "active-notifications";
  status.appendChild(activeNotifications);
  const statusBase = document.createElement("div");
  statusBase.id = "status-base";
  const fileInfo = document.createElement("div");
  fileInfo.id = "file-info-status";
  for (const label of ["Noir", "UTF-8"]) {
    const span = document.createElement("span");
    span.className = "status-inline";
    span.textContent = label;
    fileInfo.appendChild(span);
    const separator = document.createElement("div");
    separator.className = "separate-bar";
    fileInfo.appendChild(separator);
  }
  const operation = document.createElement("span");
  operation.id = "operation-status";
  const stable = document.createElement("span");
  stable.id = "stable-status";
  stable.className = "ready-status";
  stable.textContent = "stable: ready";
  operation.appendChild(stable);
  fileInfo.appendChild(operation);
  statusBase.appendChild(fileInfo);
  const movement = document.createElement("span");
  movement.className = "test-movement";
  movement.textContent = "1";
  statusBase.appendChild(movement);
  const statusRight = document.createElement("span");
  statusRight.className = "status-right";
  const location = document.createElement("span");
  location.id = "location-status";
  const locationPath = document.createElement("span");
  locationPath.className = "location-path status-inline";
  locationPath.textContent =
    "/home/zahary/metacraft/codetracer-main/test-programs/noir_space_ship/src/main.nr:13#0";
  location.appendChild(locationPath);
  statusRight.appendChild(location);
  statusBase.appendChild(statusRight);
  status.appendChild(statusBase);
  footer.appendChild(status);
  container.appendChild(footer);

  return root;
}

function createAppShell(container, kind, name) {
  if (kind === "view" || kind === "component") {
    const frame = document.createElement("div");
    frame.className = "ct-storybook-frame";
    container.appendChild(frame);
    return frame;
  }

  const rootContainer = document.createElement("div");
  rootContainer.id = "root-container";
  rootContainer.className = "ct-storybook-root-container";

  const layoutRow = document.createElement("div");
  layoutRow.id = "auto-hide-layout-row";

  const leftStrip = document.createElement("div");
  leftStrip.id = "auto-hide-strip-left";

  const root = document.createElement("div");
  root.id = "ROOT";

  const contextMenu = document.createElement("div");
  contextMenu.id = "context-menu-container";
  contextMenu.style.display = "none";
  root.appendChild(contextMenu);

  const fixedSearch = document.createElement("div");
  fixedSearch.id = "fixed-search";
  root.appendChild(fixedSearch);

  const session = document.createElement("div");
  session.id = "session-container-0";
  session.className = "session-container";

  const frame = document.createElement("section");
  frame.id = "main";
  frame.className = "ct-storybook-frame";
  session.appendChild(frame);
  root.appendChild(session);

  const rightStrip = document.createElement("div");
  rightStrip.id = "auto-hide-strip-right";

  layoutRow.appendChild(leftStrip);
  layoutRow.appendChild(root);
  layoutRow.appendChild(rightStrip);
  rootContainer.appendChild(layoutRow);
  container.appendChild(rootContainer);

  if (kind === "panel") {
    return createGoldenPanelHost(frame, titleize(name));
  }

  return frame;
}

function renderDefaultDebugLayout(container) {
  const root = createKaraxReferenceShell(container);
  const mounts = appendDefaultDebugLayout(root);

  ensureComponentsLoaded().then(() => {
    const disposes = [];
    for (const { name, mount, fixture } of mounts) {
      try {
        disposes.push(mountCodeTracerStory(mount, "panel", name, fixture ?? "populated"));
        if (name === "editor") {
          window.requestAnimationFrame(() => installStorybookEditorFixture(mount));
        }
      } catch (error) {
        console.error(`Failed to mount default layout panel "${name}"`, error);
      }
    }
    container.__dispose = () => {
      for (const dispose of disposes) {
        if (typeof dispose === "function") dispose();
      }
    };
  });
}

function renderSurface(kind, name, fixture = "populated") {
  const container = document.createElement("div");
  container.className = "ct-storybook-surface";
  container.dataset.kind = kind;
  container.dataset.surface = name;
  injectSurfaceStyles(container);

  if (kind === "layout" && name === "default-debug") {
    renderDefaultDebugLayout(container);
    return container;
  }

  const frame = createAppShell(container, kind, name);

  ensureComponentsLoaded().then(() => {
    const dispose = mountCodeTracerStory(frame, kind, name, fixture);
    container.__dispose = dispose;
  });

  return container;
}

export function story(kind, name, fixture = "populated", storyName = null) {
  return {
    name: storyName ?? titleize(name),
    render: () => renderSurface(kind, name, fixture),
    play: async ({ canvasElement }) => {
      await ensureComponentsLoaded();
      await tick();
      const surface = canvasElement.querySelector(".lm_goldenlayout, .ct-storybook-frame > *");
      expect(surface).toBeTruthy();
    },
  };
}

const meta = {
  title: "CodeTracer/Panels",
  includeStories: /^[A-Z]/,
  parameters: {
    layout: "fullscreen",
  },
};

export default meta;

export const AgentActivity = story("panel", "agent-activity", "populated", "Agent Activity");
export const AgentActivityDeepReview = story(
  "panel",
  "agent-activity-deepreview",
  "populated",
  "Agent Activity Deep Review",
);
export const AgentWorkspace = story("panel", "agent-workspace", "populated", "Agent Workspace");
export const Build = story("panel", "build", "populated", "Build");
export const Calltrace = story("panel", "calltrace", "populated", "Calltrace");
export const CalltraceEditor = story("panel", "calltrace-editor", "populated", "Calltrace Editor");
export const CommandPalette = story("panel", "command-palette", "populated", "Command Palette");
export const DebugControls = story("panel", "debug-controls", "populated", "Debug Controls");
export const DeepReview = story("panel", "deepreview", "populated", "Deep Review");
export const Editor = story("panel", "editor", "populated", "Editor");
export const Errors = story("panel", "errors", "populated", "Errors");
export const EventLog = story("panel", "event-log", "populated", "Event Log");
export const Filesystem = story("panel", "filesystem", "populated", "Filesystem");
export const Flow = story("panel", "flow", "populated", "Flow");
export const LowLevelCode = story("panel", "low-level-code", "populated", "Low Level Code");
export const NoSource = story("panel", "no-source", "populated", "No Source");
export const PointList = story("panel", "point-list", "populated", "Point List");
export const Repl = story("panel", "repl", "populated", "Repl");
export const RequestPanel = story("panel", "request-panel", "populated", "Request Panel");
export const Scratchpad = story("panel", "scratchpad", "populated", "Scratchpad");
export const Search = story("panel", "search", "populated", "Search");
export const SearchResults = story("panel", "search-results", "populated", "Search Results");
export const Shell = story("panel", "shell", "populated", "Shell");
export const State = story("panel", "state", "populated", "State");
export const StepList = story("panel", "step-list", "populated", "Step List");
export const TerminalOutput = story("panel", "terminal-output", "populated", "Terminal Output");
export const Timeline = story("panel", "timeline", "populated", "Timeline");
export const TraceLog = story("panel", "trace-log", "populated", "Trace Log");
export const Vcs = story("panel", "vcs", "populated", "VCS");
export const WelcomeScreen = story("panel", "welcome-screen", "populated", "Welcome Screen");
