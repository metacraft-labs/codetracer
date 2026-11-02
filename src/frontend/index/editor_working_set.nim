## Carry the live editor working set between independently arranged mode layouts.
## Both inputs are unresolved GoldenLayout configs; neither is modified. Only
## editor components travel: auxiliary panes belong to the entering layout.
import std/jsffi
import ./layout_config_repair

proc projectEditors(entering, live: js; editorContent: int;
                    activePath: cstring; unclaimed: int): js {.importjs: """
  (function(entering, live, editorContent, activePath, unclaimed) {
    const clone = value => JSON.parse(JSON.stringify(value));
    const result = clone(entering);
    const rootOf = config => config.root || config;
    const isEditor = node => node && node.type === 'component' &&
      Number((node.componentState || {}).content) === editorContent;
    const children = node => node && Array.isArray(node.content) ? node.content : [];
    const pathOf = node => (node.componentState || {}).fullPath ||
      (node.componentState || {}).label;
    const editors = [];

    // Filter the source down to its editor area, retaining split orientation,
    // tab order and each stack's active tab. Collapse only redundant ancestors.
    const extract = node => {
      if (!node) return null;
      if (isEditor(node)) {
        const editor = clone(node);
        editors.push(editor);
        return editor;
      }
      if (node.type === 'component') return null;
      const picked = [];
      let active = 0;
      children(node).forEach((child, index) => {
        const item = extract(child);
        if (!item) return;
        if (index === (node.activeItemIndex || 0)) active = picked.length;
        picked.push(item);
      });
      if (!picked.length) return null;
      if (node.type !== 'stack' && picked.length === 1) return picked[0];
      const copy = {...clone(node), content: picked};
      if (node.type === 'stack') {
        const selected = picked.findIndex(item => pathOf(item) === activePath);
        copy.activeItemIndex = selected >= 0 ? selected : Math.min(active, picked.length - 1);
      }
      return copy;
    };
    const workingSet = extract(rootOf(live));
    const pureEditors = node => isEditor(node) ||
      (children(node).length > 0 && children(node).every(pureEditors));
    const hasEditor = node => isEditor(node) || children(node).some(hasEditor);
    const geometry = (item, slot) => {
      for (const key of ['size', 'sizeUnit', 'minSize', 'minSizeUnit']) {
        delete item[key];
        if (slot[key] !== undefined) item[key] = slot[key];
      }
      return item;
    };
    let placed = false;

    const rewrite = node => {
      if (!node || !hasEditor(node)) return node;
      if (pureEditors(node)) {
        if (!placed && workingSet) {
          placed = true;
          return geometry(clone(workingSet), node);
        }
        return null;
      }
      if (node.type === 'component') return node;
      const previous = children(node);
      const kept = [];
      let active = 0;
      // An editor sharing a stack with auxiliary tabs keeps that arrangement.
      // A stack accepts components, so its editor slot receives the ordered
      // live tabs rather than a nested stack (which GoldenLayout rejects).
      const mixedSlot = node.type === 'stack' && previous.some(isEditor) &&
        !placed && workingSet;
      let inserted = false;
      previous.forEach((child, index) => {
        if (mixedSlot && isEditor(child)) {
          if (!inserted) {
            placed = inserted = true;
            const selected = editors.findIndex(item => pathOf(item) === activePath);
            active = kept.length + Math.max(0, selected);
            kept.push(...clone(editors));
          }
          return;
        }
        const item = rewrite(child);
        if (!item) return;
        if (!mixedSlot && index === (node.activeItemIndex || 0)) active = kept.length;
        kept.push(item);
      });
      if (!kept.length) return null;
      node.content = kept;
      if (node.type === 'stack') node.activeItemIndex = Math.min(active, kept.length - 1);
      return node;
    };
    let root = rewrite(rootOf(result));
    if (workingSet && !placed) {
      const area = clone(workingSet);
      // Same insertion point as openNewLayoutContainer: after Files, using
      // the space this mode deliberately left unclaimed for the editor.
      if (unclaimed > 0) { area.size = String(unclaimed) + '%'; delete area.sizeUnit; }
      if (root && (root.type === 'row' || root.type === 'column')) {
        root.content.splice(Math.min(1, root.content.length), 0, area);
      } else if (root) {
        root = {type: 'row', content: [root, area]};
      } else root = area;
    }
    if (result.root !== undefined) result.root = root || undefined;
    else return root;
    return result;
  })(#, #, #, #, #)
""".}

proc carryEditorWorkingSet*(entering, live: js; editorContent: int;
                           activePath: cstring): js =
  projectEditors(entering, live, editorContent, activePath,
                 unclaimedTopLevelPercent(entering))
