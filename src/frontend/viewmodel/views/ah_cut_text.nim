## views/ah_cut_text.nim — the Agent Harbor web views' cut text: one line of
## text cut at its box's edge in code, by the views' one rule for a cut
## (`agent_harbor_words.trimBeforeEllipsis`), where the stylesheet's
## `text-overflow: ellipsis` would keep a space or a separator before the
## "…" (CTF-P1c D6).
##
## ## Why in code
##
## CSS cuts a line at the last glyph that fits before the ellipsis and drops
## nothing (CSS Overflow 3, `text-overflow`,
## https://www.w3.org/TR/css-overflow-3/#text-overflow), so a meta line cut
## just past a separator reads `5ca1ab1e ·…`. Where the cut falls is known
## only once the line is laid out, so this module cuts after layout: the
## same place CSS would cut (the last glyph whose right edge, plus the
## ellipsis, fits the content box, stepped back while that glyph is shaped
## together with the next, since Chromium breaks a shaped run only where it
## is safe to), then trimmed by the shared rule. The
## terminal (`ah_tui_canvas.elide`) and GPUI (isonim-gpui's text element,
## handed `CutSeparators`) apply the same rule.
##
## ## How a view uses it
##
## A view marks a one-line text element with `CutTextAttribute`
## (`data-ah-cut`); its stylesheet rule keeps `white-space: nowrap` and
## `overflow: hidden` and has no `text-overflow`. One document-wide
## observer (installed once, when a view that imports this module is
## loaded) watches every such element: on insertion, on a resize, on a
## change of its text and when a web font loads, it measures the line
## (a DOM `Range` over the text, the laid-out glyphs,
## https://drafts.csswg.org/cssom-view/#dom-range-getboundingclientrect)
## and, when it overflows, writes the cut text to `CutShownAttribute`
## (`data-ah-shown`).
##
## The element keeps its whole text in the DOM. The stylesheet
## (`agent_harbor.styl`, `[data-ah-shown]`) makes that text transparent and
## draws the cut text over it from the attribute (`::after`, at the text's
## own start). So the element's size, its flex basis and every box around
## it are the laid-out size of its whole text, exactly as under CSS's
## ellipsis: cutting never feeds back into the layout it was measured from,
## a reader and the regions records still read the whole text, and a
## resize observer never sees the element change because of a cut.
##
## A marked element may name its floor, `CutFloorAttribute`
## (`data-ah-floor`): the least it is cut to. Its box is then kept at least
## as wide as that text (an inline `min-width`), and its line is told what
## its other parts and that floor take (`--ah-floor-rest`), so that on a
## line too short for everything the line's other cut texts give way first
## (CTF-P1c D7, a tree node's counts: `1…`; the title reads it in
## `agent_harbor.styl`).
##
## A marked element whose value is `path` (`data-ah-cut="path"`,
## `CutPathValue`) holds a file path, cut in its middle (CTF-P1c D6, amended
## for paths): the first of the shared `pathCutCandidates` whose width fits
## the content box (`src/…/retry/client.py`, `src/…/client.py`,
## `…/client.py`), and when none fits, the end cut above. The terminal
## (`elidePath`) and GPUI (isonim-gpui's middle cut, `ah_theme.pathText`)
## cut a path the same way.
##
## A marked element whose value is `input` (`data-ah-cut="input"`,
## `CutInputValue`) holds a one-line input's value (a form field's), cut in
## its middle by the views' one rule for an input (`cutInputValueInFace`,
## the P2c study's D35): its start, at most its first 8 characters, then
## "…", then as much of its end as fits, so `Asteroid fields generated from
## seeds, end to end` keeps its end and a plan file its file name. The rule
## is run here, in the page, measuring each candidate in the element's face
## (the hidden span below) in 1/64 px, the browser's layout unit
## (https://drafts.csswg.org/css-values-4/#absolute-lengths and LayoutNG's
## `LayoutUnit`), so it cuts where it would cut in GPUI (pixels) and the
## terminal (cells). The terminal (`elideMiddle`) and GPUI
## (`ah_composer.inputValueShown`) cut a form field the same way.
##
## A marked element whose value is `match` (`data-ah-cut="match"`,
## `CutMatchValue`) holds a line of the program's text that a search
## matched; `data-ah-match-start` and `data-ah-match-end` name the match
## (byte offsets of the text). It is cut around the match, which stays whole
## (`cut_text_rules.cutAroundMatch`, the P2c study's D62), measured in the
## element's face in layout units as an input is. The terminal and GPUI cut
## a matched line the same way.
##
## Every element marked must hold its text in one colour: the drawn cut is
## one string. A line made of spans in different colours keeps CSS's
## ellipsis (`agent_harbor.styl` says which, and why).
##
## `ahCutTextDangles` is exported to the page for the StoryBook render check
## (`storybook/scripts/story-render-judge.mjs`), which holds every drawn cut
## to `danglesBeforeEllipsis`.

{.used.}

import std/strutils
import ./agent_harbor_words

const
  CutTextAttribute* = "data-ah-cut"
    ## Marks a one-line text element this module cuts.
  CutFloorAttribute* = "data-ah-floor"
    ## The least a marked text is cut to (a tree node's counts: `1…`,
    ## `countsFloor`, CTF-P1c D7): its box is kept at least that wide.
  CutShownAttribute* = "data-ah-shown"
    ## The cut text drawn over the element, present only while it is cut.
  CutPathValue* = "path"
    ## `CutTextAttribute`'s value on a file path: cut in its middle.
  CutInputValue* = "input"
    ## `CutTextAttribute`'s value on a one-line input's value: cut in its
    ## middle by the one-line input rule (D35).
  CutMatchValue* = "match"
    ## `CutTextAttribute`'s value on a matched line of the program's text:
    ## cut around its match (D62).
  LayoutUnitsPerPx = 64
    ## The browser's layout unit, 1/64 px: the unit the input rule is run in
    ## on the page, fine enough that rounding never moves a cut by a glyph.

when defined(js):
  proc ahCutTextTrim(kept: cstring): cstring {.exportc.} =
    ## The shared rule, for the observer below: the kept start of a cut,
    ## trimmed, with its "…".
    cstring(trimBeforeEllipsis($kept) & CutEllipsis)

  proc ahCutTextDangles(shown: cstring): bool {.exportc.} =
    ## The shared rule's check, for the render check: on both sides of a
    ## middle cut's "…".
    danglesAroundEllipsis($shown)

  proc ahCutTextPathCandidates(path: cstring): cstring {.exportc.} =
    ## The shared middle cuts of a path, longest first, one a line.
    cstring(pathCutCandidates($path).join("\n"))

  proc ahCutTextInputCut(value: cstring; roomPx: float;
                         measure: proc(text: cstring): float): cstring {.exportc.} =
    ## The one-line input rule, for the observer below: `value` in `roomPx`,
    ## `measure` giving a text's advance in px in the element's face; run in
    ## layout units (`LayoutUnitsPerPx`). The room is rounded down and each
    ## width up, so a text is said to fit only when it does.
    let room = int(roomPx * float(LayoutUnitsPerPx))
    let widthOf = proc(text: string): int =
      let units = measure(cstring(text)) * float(LayoutUnitsPerPx)
      # Up to the next whole unit; a hair under one is taken as that one,
      # since the advance itself is a float sum of whole units.
      let whole = int(units)
      if units - float(whole) > 0.001: whole + 1 else: whole
    cstring(cutInputValueInFace($value, room, widthOf))

  proc ahCutTextMatchCut(value: cstring; matchStart, matchEnd: int; roomPx: float;
                         measure: proc(text: cstring): float): cstring {.exportc.} =
    ## The matched-line rule, for the observer below, in layout units as
    ## `ahCutTextInputCut` runs the input rule.
    let room = int(roomPx * float(LayoutUnitsPerPx))
    let widthOf = proc(text: string): int =
      let units = measure(cstring(text)) * float(LayoutUnitsPerPx)
      let whole = int(units)
      if units - float(whole) > 0.001: whole + 1 else: whole
    cstring(cutAroundMatch($value, matchStart, matchEnd, room, widthOf,
                           widthOf(CutEllipsis)))

  proc installCutText(trim: proc(kept: cstring): cstring;
                      dangles: proc(shown: cstring): bool;
                      pathCuts: proc(path: cstring): cstring;
                      inputCut: proc(value: cstring; roomPx: float;
                                     measure: proc(text: cstring): float): cstring;
                      matchCut: proc(value: cstring; matchStart, matchEnd: int; roomPx: float;
                                     measure: proc(text: cstring): float): cstring) {.importjs: """
    (function (trim, dangles, pathCuts, inputCut, matchCut) {
      // Every rule must reach the page: a rule the call drops would fail
      // only at the first element that needs it.
      if (typeof trim !== 'function' || typeof dangles !== 'function' ||
          typeof pathCuts !== 'function' || typeof inputCut !== 'function' ||
          typeof matchCut !== 'function')
        throw new TypeError('ah_cut_text: a shared cut rule did not reach the page');
      if (typeof document === 'undefined' || typeof ResizeObserver === 'undefined' ||
          globalThis.__ahCutText) return;
      globalThis.__ahCutText = true;
      globalThis.ahCutTextDangles = function (s) { return dangles(String(s)); };
      var ATTR = 'data-ah-cut', SHOWN = 'data-ah-shown', FLOOR = 'data-ah-floor';
      var watched = new Set();
      var measurer = null;

      function px(v) { return parseFloat(v) || 0; }

      // A text's advance in the element's face, from a hidden span that
      // copies the face (font, its features, letter spacing).
      function textWidth(cs, text) {
        if (!measurer) {
          measurer = document.createElement('span');
          measurer.setAttribute('aria-hidden', 'true');
          measurer.style.cssText = 'position:absolute;left:-10000px;top:0;' +
            'visibility:hidden;white-space:pre;pointer-events:none';
        }
        if (!measurer.isConnected) document.body.appendChild(measurer);
        measurer.textContent = text;
        var s = measurer.style;
        s.font = cs.font;
        s.fontFeatureSettings = cs.fontFeatureSettings;
        s.fontVariantNumeric = cs.fontVariantNumeric;
        s.fontKerning = cs.fontKerning;
        s.letterSpacing = cs.letterSpacing;
        s.textTransform = cs.textTransform;
        return measurer.getBoundingClientRect().width;
      }

      // Whether two characters shape together (a ligature or a contextual
      // alternate): set without kerning, the pair is not as wide as its
      // two characters set alone. Kerning alone moves glyphs, and Chromium
      // breaks a kerned pair; it does not break a substituted one.
      function shapedTogether(cs, pair) {
        if (pair.length !== 2) return false;
        var noKern = { font: cs.font, fontFeatureSettings: cs.fontFeatureSettings,
                       fontVariantNumeric: cs.fontVariantNumeric, fontKerning: 'none',
                       letterSpacing: cs.letterSpacing, textTransform: cs.textTransform };
        var both = textWidth(noKern, pair);
        // Each width is in layout units (1/64 px), so a pair that does not
        // shape together can differ from its parts by a unit or two.
        return Math.abs(both - textWidth(noKern, pair[0]) - textWidth(noKern, pair[1])) > 0.1;
      }

      // The element's own text: never the overlay a matched line's cut is
      // drawn in.
      function textNodes(el) {
        var out = [];
        var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, {
          acceptNode: function (n) {
            return n.parentElement && n.parentElement.closest('.ah-cut-overlay') ?
              NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
          }
        });
        for (var n = walker.nextNode(); n; n = walker.nextNode()) out.push(n);
        return out;
      }

      // The right edge of the first `k` UTF-16 units of the element's text,
      // as laid out.
      function prefixRight(nodes, k, left) {
        if (k <= 0) return left;
        var range = document.createRange();
        range.setStart(nodes[0], 0);
        for (var i = 0; i < nodes.length; i++) {
          var len = nodes[i].data.length;
          if (k <= len || i === nodes.length - 1) {
            range.setEnd(nodes[i], Math.min(k, len));
            break;
          }
          k -= len;
        }
        return range.getBoundingClientRect().right;
      }

      // A text's floor (`data-ah-floor`, CTF-P1c D7): the least it is cut
      // to. Its box is kept at least that wide, a pixel over its words so
      // the cut keeps them, and the line's other cut texts give way
      // instead: the line's room for them beside its fixed parts and this
      // floor is `--ah-floor-rest` on the line (its other parts, the floor
      // and the gaps), which their stylesheet rules read.
      function keepFloor(el) {
        var floor = el.getAttribute(FLOOR);
        if (!floor) return;
        var cs = getComputedStyle(el);
        var floorW = Math.ceil(textWidth(cs, floor) + px(cs.paddingLeft) + px(cs.paddingRight) +
                               px(cs.borderLeftWidth) + px(cs.borderRightWidth)) + 1;
        if (el.style.minWidth !== floorW + 'px') el.style.minWidth = floorW + 'px';
        var line = el.parentElement;
        if (!line) return;
        var items = Array.prototype.filter.call(line.children, function (c) {
          var s = getComputedStyle(c);
          return s.display !== 'none' && s.position !== 'absolute' && s.position !== 'fixed';
        });
        var rest = floorW + px(getComputedStyle(line).columnGap) * Math.max(0, items.length - 1);
        items.forEach(function (c) {
          if (!c.hasAttribute(ATTR)) rest += c.getBoundingClientRect().width;
        });
        var want = Math.ceil(rest) + 'px';
        if (line.style.getPropertyValue('--ah-floor-rest') !== want) {
          line.style.setProperty('--ah-floor-rest', want);
        }
      }

      function cut(el) {
        if (!el.isConnected) return;
        keepFloor(el);
        var nodes = textNodes(el);
        var full = nodes.map(function (n) { return n.data; }).join('');
        var box = el.getBoundingClientRect();
        if (nodes.length === 0 || full.length === 0 || box.width <= 0) {
          el.removeAttribute(SHOWN);
          return;
        }
        var cs = getComputedStyle(el);
        var contentLeft = box.left + px(cs.borderLeftWidth) + px(cs.paddingLeft);
        var isPath = el.getAttribute(ATTR) === 'path';
        var isInput = el.getAttribute(ATTR) === 'input';
        var isMatch = el.getAttribute(ATTR) === 'match';
        var contentRight = box.right - px(cs.borderRightWidth) - px(cs.paddingRight);
        var all = document.createRange();
        all.setStart(nodes[0], 0);
        all.setEnd(nodes[nodes.length - 1], nodes[nodes.length - 1].data.length);
        var text = all.getBoundingClientRect();
        if (text.right <= contentRight + 0.01) {
          el.removeAttribute(SHOWN);
          return;
        }
        // A path: the first middle cut that fits the content box.
        if (isPath) {
          var room = contentRight - text.left + 0.01;
          var cuts = String(pathCuts(full)).split('\n');
          for (var c = 0; c < cuts.length; c++) {
            if (cuts[c].length > 0 && textWidth(cs, cuts[c]) <= room) {
              el.style.setProperty('--ah-cut-indent', Math.max(0, text.left - contentLeft) + 'px');
              if (el.getAttribute(SHOWN) !== cuts[c]) el.setAttribute(SHOWN, cuts[c]);
              return;
            }
          }
        }
        // A one-line input's value: cut in its middle by the shared rule,
        // each candidate measured in the element's face (memoised: the rule
        // measures every start and end it tries).
        if (isInput) {
          var widths = new Map();
          var measure = function (t) {
            t = String(t);
            if (!widths.has(t)) widths.set(t, textWidth(cs, t));
            return widths.get(t);
          };
          var middle = String(inputCut(full, contentRight - text.left + 0.01, measure));
          el.style.setProperty('--ah-cut-indent', Math.max(0, text.left - contentLeft) + 'px');
          if (el.getAttribute(SHOWN) !== middle) el.setAttribute(SHOWN, middle);
          return;
        }
        // A matched line: cut around its match, which stays whole.
        if (isMatch) {
          var mwidths = new Map();
          var mmeasure = function (t) {
            t = String(t);
            if (!mwidths.has(t)) mwidths.set(t, textWidth(cs, t));
            return mwidths.get(t);
          };
          var around = String(matchCut(full, parseInt(el.getAttribute('data-ah-match-start'), 10) || 0,
                                       parseInt(el.getAttribute('data-ah-match-end'), 10) || 0,
                                       contentRight - text.left + 0.01, mmeasure));
          el.style.setProperty('--ah-cut-indent', Math.max(0, text.left - contentLeft) + 'px');
          // The overlay the cut is drawn in, its match bold (written only
          // when the cut changes, so the observer's own record settles).
          var ov = el.querySelector(':scope > .ah-cut-overlay');
          if (!ov) {
            ov = document.createElement('span');
            ov.className = 'ah-cut-overlay';
            ov.setAttribute('aria-hidden', 'true');
            el.appendChild(ov);
          }
          if (ov.getAttribute('data-text') !== around) {
            ov.setAttribute('data-text', around);
            ov.textContent = '';
            // Every match in view bold (ASCII case ignored, as the query
            // matches; the uncut line bolds them all too).
            var matchText = (el.getAttribute('data-ah-match') || '').toLowerCase();
            var hay = around.toLowerCase(), from = 0;
            var at = matchText ? hay.indexOf(matchText) : -1;
            while (at >= 0) {
              if (at > from) ov.appendChild(document.createTextNode(around.slice(from, at)));
              var b = document.createElement('b');
              b.textContent = around.slice(at, at + matchText.length);
              ov.appendChild(b);
              from = at + matchText.length;
              at = hay.indexOf(matchText, from);
            }
            if (from < around.length) ov.appendChild(document.createTextNode(around.slice(from)));
          }
          if (el.getAttribute(SHOWN) !== around) el.setAttribute(SHOWN, around);
          return;
        }
        // CSS's cut: the most text whose last glyph, and the ellipsis after
        // it, end inside the content box.
        var limit = contentRight - textWidth(cs, '…') + 0.01;
        var lo = 0, hi = full.length - 1;
        while (lo < hi) {
          var mid = (lo + hi + 1) >> 1;
          if (prefixRight(nodes, mid, text.left) <= limit) lo = mid; else hi = mid - 1;
        }
        var k = lo;
        var code = k > 0 ? full.charCodeAt(k - 1) : 0;
        if (code >= 0xD800 && code <= 0xDBFF) k -= 1;   // never half a pair
        // Chromium cuts only where the shaped run may be broken: not inside
        // two characters the font shapes together (HarfBuzz's
        // unsafe-to-break, which LayoutNG's truncation honours through
        // `ShapeResult::PreviousSafeToBreakOffset`); step back over them.
        while (k > 0 && k < full.length && shapedTogether(cs, full.slice(k - 1, k + 1))) k -= 1;
        var shown = trim(full.slice(0, k));
        el.style.setProperty('--ah-cut-indent', Math.max(0, text.left - contentLeft) + 'px');
        if (el.getAttribute(SHOWN) !== shown) el.setAttribute(SHOWN, shown);
      }

      var resizes = new ResizeObserver(function (entries) {
        entries.forEach(function (e) { cut(e.target); });
      });
      function watch(el) {
        if (watched.has(el)) return;
        watched.add(el);
        resizes.observe(el);
      }
      function unwatch(el) {
        if (!watched.has(el)) return;
        watched.delete(el);
        resizes.unobserve(el);
      }
      function each(node, fn) {
        if (node.nodeType !== 1) return;
        if (node.hasAttribute(ATTR)) fn(node);
        node.querySelectorAll('[' + ATTR + ']').forEach(fn);
      }
      function owner(node) {
        var el = node.nodeType === 1 ? node : node.parentElement;
        return el ? el.closest('[' + ATTR + ']') : null;
      }
      new MutationObserver(function (records) {
        records.forEach(function (rec) {
          if (rec.type === 'childList') {
            rec.removedNodes.forEach(function (n) { each(n, unwatch); });
            rec.addedNodes.forEach(function (n) { each(n, watch); });
            var o = owner(rec.target);
            if (o) cut(o);
          } else if (rec.type === 'characterData') {
            var o2 = owner(rec.target);
            if (o2) cut(o2);
          } else if (rec.type === 'attributes') {
            if (rec.target.hasAttribute(ATTR)) watch(rec.target);
            else { unwatch(rec.target); rec.target.removeAttribute(SHOWN); }
          }
        });
      }).observe(document.documentElement, {
        childList: true, subtree: true, characterData: true,
        attributes: true, attributeFilter: [ATTR]
      });
      each(document.documentElement, watch);
      if (document.fonts) {
        var again = function () { watched.forEach(cut); };
        document.fonts.addEventListener('loadingdone', again);
        document.fonts.ready.then(again);
      }
    })(#, #, #, #, #)""".}

  installCutText(ahCutTextTrim, ahCutTextDangles, ahCutTextPathCandidates,
                 ahCutTextInputCut, ahCutTextMatchCut)
