## A document for headless auto-hide suites — a HOST SHIM, not a test double.
##
## Nothing here replaces or simulates a proc under test.  It supplies the part
## of the browser the `vm-js` lane does not have, so the shipped
## `ui/auto_hide.nim` procs can be called and the tree they build can be read
## back.  Two suites share it rather than keeping a copy each
## (`Verification-Harness-Traps.md` §30 is about duplicated RULES, but a
## duplicated harness drifts the same way and the drift is invisible):
##
## * `auto-hide/auto_hide_restore_mount_test.nim` — issue #691, the restore
##   path in full.
## * `layout/layout_config_roundtrip_test.nim` — issue #608's persistence
##   invariants, whose "a restored auto-hide panel keeps enough config to be
##   re-attached" case used to assert only that the JSON carried the right
##   FIELDS.  It passed while the feature was broken.  It now reveals the
##   restored panel and asserts a mounted container, which needs a document.
##
## WHY A SHIM IS NEEDED AT ALL.  The lane compiles with `-d:nodejs`, and Nim's
## `std/dom` answers that flag with an in-memory emulation: `getElementById`
## becomes a hand-rolled walk over `document.body`, and `createElement` returns
## an element whose `style` and `classList` are NULL.  `showDockedPanel`'s next
## act on a live element is to write four style properties, so the emulation's
## own elements cannot be used as panel content.  `CONTRIBUTING.md`, "Frontend
## JS tests: `-d:nodejs` hands you a DOM that is not the DOM", is the standing
## warning.
##
## The shim therefore supplies elements with a `style`, a `classList`, working
## `setAttribute` / `appendChild`, and an `innerHTML` that CLEARS ITS CHILDREN
## when assigned — that last detail is load-bearing rather than cosmetic:
## `showDockedPanel` opens with `contentEl.innerHTML = ""`, and a shim that
## ignored it would let one case's leftover node satisfy the next case's
## "the pane has content" assertion.
##
## `document.body` (the emulation's) is pointed at the same root the shim
## builds, so `getElementById` resolves against exactly the nodes production
## attached.

when not defined(js):
  {.error: "auto_hide_dom_harness is a JS-backend harness".}

import kdom

{.emit: """
if (typeof globalThis.window === 'undefined') {
  globalThis.window = { dispatchEvent: function () { return true; } };
}
if (typeof globalThis.CustomEvent === 'undefined') {
  globalThis.CustomEvent = function (name) { this.type = name; };
}

function CtHarnessEl(id) {
  this.id = id || '';
  this.nodeType = 1;
  this.childNodes = [];
  this.parentNode = null;
  this.ownerDocument = null;
  this.className = '';
  this.textContent = '';
  this.style = {};
  var self = this;
  this.classList = {
    _set: {},
    add: function (c) { self.classList._set[c] = true; },
    remove: function (c) { delete self.classList._set[c]; },
    contains: function (c) { return self.classList._set[c] === true; }
  };
  this._attrs = {};
}
Object.defineProperty(CtHarnessEl.prototype, 'innerHTML', {
  get: function () { return this.childNodes.length > 0 ? '<children>' : ''; },
  set: function (value) {
    for (var i = 0; i < this.childNodes.length; i++) {
      this.childNodes[i].parentNode = null;
    }
    this.childNodes = [];
  }
});
CtHarnessEl.prototype.appendChild = function (child) {
  if (child.parentNode && child.parentNode.removeChild) {
    child.parentNode.removeChild(child);
  }
  child.parentNode = this;
  child.ownerDocument = this.ownerDocument;
  this.childNodes.push(child);
  return child;
};
CtHarnessEl.prototype.removeChild = function (child) {
  var at = this.childNodes.indexOf(child);
  if (at >= 0) { this.childNodes.splice(at, 1); }
  child.parentNode = null;
  return child;
};
CtHarnessEl.prototype.setAttribute = function (name, value) {
  this._attrs[name] = value;
  if (name === 'id') { this.id = value; }
  if (name === 'class') { this.className = value; }
};
CtHarnessEl.prototype.removeAttribute = function (name) {
  delete this._attrs[name];
};
CtHarnessEl.prototype.getAttribute = function (name) {
  return Object.prototype.hasOwnProperty.call(this._attrs, name)
    ? this._attrs[name] : null;
};

globalThis.__ctHarnessNewElement = function (id) {
  return new CtHarnessEl(id);
};

// `ui/auto_hide.nim`'s `jsCreatePanelHost` builds its element through the
// AMBIENT document, for exactly this reason: in the renderer that is the real
// one, and here it is the shim.
globalThis.document = {
  createElement: function (tag) { return new CtHarnessEl(''); },
  addEventListener: function () {}
};
""".}

const
  ## The container ids `ui/auto_hide.nim` looks up, mirrored from its
  ## `dockedContainerId` / `dockedContentId` (both private) and from the
  ## overlay markup in `public/index.html`.  A suite that builds the wrong ids
  ## would make `showDockedPanel` bail at its `contentEl.isNil` guard and every
  ## "the pane is empty" control would pass for the wrong reason — so each
  ## suite carries a case that turns this mirror into a measurement.
  DockedBottomId* = cstring"auto-hide-docked-bottom"
  DockedBottomContentId* = cstring"auto-hide-docked-bottom-content"
  DockedLeftId* = cstring"auto-hide-docked-left"
  DockedLeftContentId* = cstring"auto-hide-docked-left-content"
  DockedRightId* = cstring"auto-hide-docked-right"
  DockedRightContentId* = cstring"auto-hide-docked-right-content"
  OverlayId* = cstring"auto-hide-overlay"
  OverlayTitleId* = cstring"auto-hide-overlay-title"
  OverlayContentId* = cstring"auto-hide-overlay-content"

proc newStubElement*(id: cstring): Element
  {.importjs: "globalThis.__ctHarnessNewElement(#)".}
  ## An element of the kind the shim's `document.createElement` returns.

# The four readers below are NULL-SAFE on purpose, and it is a red-measurement
# property rather than defensive habit.  When a case fails, the node it wanted
# is usually absent, and `el.childNodes[0].className` on an absent node throws
# a native TypeError that ABORTS the case at its first failing check and takes
# every assertion after it with it — `Verification-Harness-Traps.md` §33, an
# arm dying upstream of its own subject.  Measured: before this, two red cases
# reported one failure each instead of three.
proc stubChildCount*(el: Element): int
  {.importjs: "((# || {}).childNodes || []).length".}
proc stubChildAt*(el: Element, index: int): Element
  {.importjs: "((((# || {}).childNodes) || [])[#] || null)".}
proc stubClassOf*(el: Element): cstring {.importjs: "((# || {}).className || '')".}
proc stubTextOf*(el: Element): cstring {.importjs: "((# || {}).textContent || '')".}

proc installAutoHideDocument*() =
  ## Build a document carrying the containers `public/index.html` provides.
  ## Call once per case, so no node survives into the next one.
  let root = newStubElement(cstring"BODY")
  document.body = root
  for id in [DockedBottomId, DockedLeftId, DockedRightId, OverlayId,
             DockedBottomContentId, DockedLeftContentId, DockedRightContentId,
             OverlayContentId, OverlayTitleId]:
    root.appendChild(newStubElement(id))
