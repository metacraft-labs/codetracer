## The omnibox's result commands and search, over `ResultCommandsVM`
## (nim-agents-isonim-viewmodels): the caption bar's omnibox field holding
## `/s …`, `/ah…` or an instruction whose last word is a sigil, and under it
## the rows the command answered, grouped by provider.
##
## Built from the composer's parts, so the two read as one omnibox (P2c
## study D40): the field is the palette's `command-input-row`, given the
## sheet's edges while the sheet is open (D36), and the sheet is the
## composer's (`agent_harbor_composer.styl`): a header line that stays above
## a scrolling body, `More below ↓` while the body holds more. The body, top
## to bottom:
##
## - `← All providers` when one group is shown alone (D42);
## - the line that stands in place of the rows (`Nothing matches "…"`, an
##   unknown `/ah` name, Agent Harbor not reachable), with its hint;
## - each group: its title (the section label) with its state at the right
##   (`searching…`, the count, `no results`, `failed: …`), its rows, and
##   `+N more`;
## - a row: its title with the query's matches in bold, what it is, where
##   it is, a quiet tag (a command's or a contributed row's source); under
##   it a command's description, or `Opened outside CodeTracer`; and a rich
##   row's HTML box, sandboxed (D45).
##
## Presses and keys are routed (Input-Routing-And-Keymaps.md §5.1, D48):
## the results are the `results` scope (`data-ct-pane`), and each element a
## press acts on carries its operation (`data-ct-operation`,
## `agent_harbor_results_words`) and its target (`data-ah-target`). The view
## keeps one listener, the field's text input (the operator's typing, not a
## press). Every element names what it is (`data-ah-*`), so a check reads
## the facts off the drawing.
##
## One generic proc for every renderer, as the other Agent Harbor views.

import std/strutils

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import ./ah_cut_text
from ../keymap/scope_path import ResultsScope
from ../input/element_press import OperationAttribute

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

  proc setInputValue(node: isonim_dom.Node; value: cstring) {.importjs: "#.value = #".}
  proc inputValueOf(node: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}
  proc keepFieldEndInView(field: isonim_dom.Node) {.importjs: """
    (function (f) {
      // The field's end, where the caret is, stays in view (P2c D36): the
      // input scrolled to its end, never cut (D32). Again on the next
      // frames, as the field reaches its width only once laid out.
      var n = 0;
      var go = function () {
        f.scrollLeft = f.scrollWidth;
        if (++n < 30) requestAnimationFrame(go);
      };
      go();
    })(#)""".}
  proc followMoreBelow(body: isonim_dom.Node) {.importjs: """
    (function (b) {
      // `data-ah-more` while the body holds more below (the composer's
      // quiet "More below" line, agent_harbor_composer.styl).
      if (b.__ahMore) return;
      var mark = function () {
        var line = b.hasAttribute('data-ah-more') ?
          (parseFloat(getComputedStyle(b, '::after').height) || 0) : 0;
        var more = b.scrollHeight - line - b.scrollTop - b.clientHeight > 4;
        if (more) b.setAttribute('data-ah-more', ''); else b.removeAttribute('data-ah-more');
      };
      b.__ahMore = mark;
      b.addEventListener('scroll', mark);
      if (typeof ResizeObserver !== 'undefined') new ResizeObserver(mark).observe(b);
      var n = 0; var tick = function () { mark(); if (++n < 60) requestAnimationFrame(tick); };
      requestAnimationFrame(tick);
    })(#)""".}
  proc fillRichBox(frame: isonim_dom.Node; html: cstring; trusted: bool;
                   maxHeight: int) {.importjs: """
    (function (f, html, trusted, maxHeight) {
      // A rich row's box (P2c D45, OMNI-AREQ4): a sandboxed frame, never
      // same-origin, scripts only for a trusted source, and a policy that
      // refuses every network request. The page's design-system roles reach
      // the box as custom properties, read from the results' own element,
      // whose stylesheet sets them from the tokens -- once the frame is in
      // the page (a detached element has no computed style).
      // The design system's face, carried in: a sandboxed frame has an
      // opaque origin and a policy that refuses every request, so it can
      // load no font of the page's. Its regular and bold faces are read
      // once from the page's own font-face rules and handed in as data
      // URLs (`font-src data:`), so the box sets its words in CodeTracer's
      // type, not the platform's default face.
      var fontsFor = function () {
        if (window.__ahBoxFonts) return window.__ahBoxFonts;
        var want = {};
        try {
          for (var i = 0; i < document.styleSheets.length; i++) {
            var sheet = document.styleSheets[i], rules;
            try { rules = sheet.cssRules; } catch (e) { continue; }
            for (var j = 0; j < rules.length; j++) {
              var rule = rules[j];
              if (rule.type !== 5) continue;  // CSSFontFaceRule
              var fam = rule.style.getPropertyValue('font-family').replace(/["']/g, '').trim();
              if (fam !== 'SpaceGrotesk') continue;
              var w = rule.style.getPropertyValue('font-weight').trim() || '400';
              if (w !== '400' && w !== '600' && w !== '700') continue;
              var m = /url\(\s*['"]?([^'")]+\.woff2)['"]?\s*\)/.exec(rule.style.getPropertyValue('src'));
              if (m && !want[w]) want[w] = new URL(m[1], sheet.href || document.baseURI).href;
            }
          }
        } catch (e) {}
        var one = function (w) {
          return fetch(want[w]).then(function (r) { return r.ok ? r.blob() : null; })
            .then(function (b) {
              if (!b) return '';
              return new Promise(function (done) {
                var rd = new FileReader();
                rd.onload = function () {
                  // (The at sign spelled by its code: a bare one is a
                  // placeholder in an importjs body.)
                  done(String.fromCharCode(64) + 'font-face{font-family:"SpaceGrotesk";font-weight:' + w +
                       ';src:url(' + rd.result + ') format("woff2")}');
                };
                rd.onerror = function () { done(''); };
                rd.readAsDataURL(b);
              });
            })
            .catch(function () { return ''; });
        };
        window.__ahBoxFonts = typeof fetch === 'function' ?
          Promise.all(Object.keys(want).map(one)).then(function (a) { return a.join(''); }) :
          Promise.resolve('');
        return window.__ahBoxFonts;
      };
      var fill = function (faces) {
        var host = f.closest('.ah-results');
        var cs = getComputedStyle(host || document.documentElement);
        var names = ['body', 'caption', 'label', 'border', 'ground', 'raised',
                     'success', 'warning', 'error', 'action', 'font',
                     'size', 'caption-size', 'line'];
        var vars = names.map(function (n) {
          return '--ct-' + n + ':' + cs.getPropertyValue('--ah-box-' + n).trim() + ';';
        }).join('');
        var policy = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:" +
          (trusted ? "; script-src 'unsafe-inline'" : "");
        // A trusted box says how tall its content is, so the frame takes
        // that height up to the cap; an untrusted one runs no script and
        // keeps the height its source asked for.
        var report = trusted ?
          '<script>(function(){var s=function(){parent.postMessage({ahBox:' +
          'document.body.scrollHeight},"*")};' +
          'new ResizeObserver(s).observe(document.body);s();})()</' + 'script>' : '';
        f.setAttribute('sandbox', trusted ? 'allow-scripts' : '');
        f.setAttribute('srcdoc',
          '<!doctype html><html><head><meta charset="utf-8">' +
          '<meta http-equiv="Content-Security-Policy" content="' + policy + '">' +
          '<style>' + faces + ':root{' + vars + '}html,body{margin:0;background:var(--ct-ground);' +
          'color:var(--ct-body);font-family:var(--ct-font);font-size:var(--ct-size);' +
          'line-height:var(--ct-line)}body{padding:8px 10px}</style></head><body>' +
          html + report + '</body></html>');
      };
      if (trusted && !f.__ahBox) {
        f.__ahBox = function (e) {
          if (e.source !== f.contentWindow || !e.data || typeof e.data.ahBox !== 'number') return;
          f.style.height = Math.min(maxHeight, Math.ceil(e.data.ahBox) + 2) + 'px';
          // Taller than the cap: it scrolls, and the line under it says so.
          var wrap = f.parentElement;
          if (wrap) {
            if (e.data.ahBox + 2 > maxHeight) wrap.setAttribute('data-ah-box-more', '');
            else wrap.removeAttribute('data-ah-box-more');
          }
          if (f.__ahClip) f.__ahClip();
        };
        window.addEventListener('message', f.__ahBox);
      }
      // While the sheet's body cuts the box off, the box's own line is
      // hidden: the body's `More below` says there is more.
      var clip = function () {
        var wrap = f.parentElement;
        var body = f.closest('.ah-composer-body');
        if (!wrap || !body) return;
        var line = body.hasAttribute('data-ah-more') ?
          (parseFloat(getComputedStyle(body, '::after').height) || 0) : 0;
        var cut = wrap.getBoundingClientRect().bottom >
                  body.getBoundingClientRect().bottom - line + 0.5;
        if (cut) wrap.setAttribute('data-ah-box-clipped', '');
        else wrap.removeAttribute('data-ah-box-clipped');
      };
      f.__ahClip = clip;
      var tries = 0;
      var wait = function () {
        if (f.isConnected) {
          fontsFor().then(fill, function () { fill(''); });
          var body = f.closest('.ah-composer-body');
          if (body) {
            body.addEventListener('scroll', clip);
            if (typeof ResizeObserver !== 'undefined') new ResizeObserver(clip).observe(body);
          }
          var n = 0; var tick = function () { clip(); if (++n < 60) requestAnimationFrame(tick); };
          requestAnimationFrame(tick);
        }
        else if (++tries < 120) requestAnimationFrame(wait);
      };
      wait();
    })(#, #, #, #)""".}

import ./agent_harbor_results_words

export signals, computation, components, agent_harbor_results_words

static:
  doAssert OperationAttribute == "data-ct-operation"
  doAssert ResultsTargetAttribute == "data-ah-target"

const
  AgentHarborResultsClass* = "ah-results"

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

proc textNode[R](r: R; class, words: string): auto =
  ui(r):
    tdiv(class = class):
      text words

proc textSpan[R](r: R; class, words: string): auto =
  ui(r):
    span(class = class):
      text words

proc renderTitle[R, N](r: R; host: N; row: ResultRow; query: string) =
  ## The title in parts, the query's matches in bold (one colour: the cut
  ## rule's, `ah_cut_text`).
  for part in titleParts(row, query):
    if part.matched:
      r.appendRendered(host, textSpan(r, "ah-results-match", part.text))
    else:
      r.appendRendered(host, textSpan(r, "ah-results-plain", part.text))

proc renderRow[R, N](r: R; vm: ResultCommandsVM; g: ShownGroup; index: int;
                     row: ResultRow; query: string): N =
  var title, line, after: N
  let selected = vm.isSelected(g, index)
  let detail = vm.rowDetail(row)
  let second = vm.rowSecondLine(row)
  let tag = vm.rowTagText(row)
  let html = vm.showsHtml(row)
  let at = g.first + index
  let (matchStart, matchEnd) = matchedSpan(row, query)
  let node = ui(r):
    tdiv(class = "ah-results-row" & (if selected: " ah-results-row-selected" else: "") &
                 (if html: " ah-results-row-rich" else: ""),
         role = "option", `aria-selected` = (if selected: "true" else: "false"),
         `data-ah-row` = row.id, `data-ah-kind` = $row.kind,
         `data-ct-operation` = ResultsOpenOperation, `data-ah-target` = $at):
      tdiv(ref = line, class = "ah-results-row-line"):
        # A line of the program's text is one line, cut around the match
        # that put it in the list, which stays whole (P2c study D62); its
        # whole text is the tooltip. Any other title is one line, cut by
        # the one rule.
        if row.kind == rkLine:
          span(ref = title, `data-ah-cut` = CutMatchValue,
               `data-ah-match-start` = $matchStart, `data-ah-match-end` = $matchEnd,
               `data-ah-match` = row.title[matchStart ..< matchEnd],
               class = "ah-results-title ah-results-title-code",
               `data-ah-title` = row.title, title = row.title)
        else:
          span(ref = title, `data-ah-cut` = "line", class = "ah-results-title",
               `data-ah-title` = row.title)
        if detail.len > 0:
          span(`data-ah-cut` = "line", class = "ah-results-detail"):
            text detail
        if row.location.len > 0:
          span(`data-ah-cut` = "path", class = "ah-results-location"):
            text row.location
        if tag.len > 0:
          span(class = "ah-results-tag"):
            text tag
        if html:
          span(class = "ah-results-tag ah-results-tag-html"):
            text HtmlTag
      tdiv(ref = after, class = "ah-results-after")
  r.renderTitle(title, row, query)
  if second.len > 0:
    r.appendRendered(after, textNode(r, "ah-results-second" &
      (if vm.openedOutside(row): " ah-results-opened-outside" else: ""), second))
  if html:
    let height = htmlHeightOf(row)
    var frame: N
    # The box: the frame, and under it, inside the box's border, the quiet
    # line that says a trusted box scrolls (shown while the whole box is in
    # the sheet's view: when the sheet cuts it off, the sheet's own `More
    # below` says so).
    let box = ui(r):
      tdiv(class = "ah-results-boxwrap"):
        iframe(ref = frame, class = "ah-results-box", title = row.title & " (HTML)",
               style = "height: " & $height & "px", `data-ah-html` = $row.htmlHeight)
        tdiv(class = "ah-results-boxmore"):
          text BoxMoreBelow
    r.appendRendered(after, box)
    when defined(js):
      when N is isonim_dom.Element:
        fillRichBox(isonim_dom.Node(frame), cstring(boxHtml(row)), row.trusted, height)
    if vm.scriptsBlocked(row):
      r.appendRendered(after, textNode(r, "ah-results-note", ScriptsNotRun))
  node

proc renderAgentHarborResults*[R, N](r: R; vm: ResultCommandsVM): N =
  ## The field and the sheet; the sheet redrawn whenever what it shows
  ## changes.
  mixin clearChildren, setAttribute
  var field, sheet, top: N
  let root = ui(r):
    tdiv(class = "ah-composer " & AgentHarborResultsClass & " command-view",
         `data-ct-pane` = ResultsScope):
      tdiv(class = "command-input-row ah-composer-input-row"):
        input(ref = field, class = "command-input-field ah-composer-input",
              `aria-label` = "Omnibox", spellcheck = "false")
      tdiv(class = "ah-composer-sheet ah-results-sheet", role = "listbox",
           `aria-label` = "Results"):
        tdiv(ref = top, class = "ah-composer-top")
        tdiv(ref = sheet, class = "ah-composer-body ah-results-body")
  when defined(js):
    when N is isonim_dom.Element:
      let target = vm
      isonim_dom.addEventListener(isonim_dom.Node(field), cstring"input",
        proc(ev: isonim_dom.Event) =
          target.setInput($inputValueOf(isonim_dom.Node(field))))
  createRenderEffect proc() =
    let value = vm.input
    when defined(js):
      when N is isonim_dom.Element:
        setInputValue(isonim_dom.Node(field), cstring(value))
        keepFieldEndInView(isonim_dom.Node(field))
    r.setAttribute(field, "value", value)
  createRenderEffect proc() =
    discard vm.revision.val
    discard vm.selected.val
    let alone = vm.alone.val
    discard vm.htmlEnabled.val
    r.clearChildren(sheet)
    r.clearChildren(top)
    r.setAttribute(sheet, "data-ah-kind", $vm.kind)
    let header = vm.headerText
    r.appendRendered(top, textNode(r, "ah-composer-header" &
      (case vm.headerRole
       of "body": " ah-role-body"
       of "error": " ah-role-error"
       else: ""), header))
    if alone.len > 0:
      let back = ui(r):
        tdiv(class = "ah-results-back", `data-ah-action` = "all",
             `data-ct-operation` = ResultsAllOperation, `data-ah-target` = ""):
          text AllProviders
      r.appendRendered(sheet, back)
    let notice = vm.notice
    if notice.text.len > 0:
      var noticeText: N
      let n = ui(r):
        tdiv(class = "ah-results-notice" &
                     (if notice.role == "error": " ah-role-error" else: ""),
             `data-ah-notice` = notice.role):
          span(ref = noticeText, class = "ah-results-notice-text")
          if notice.hint.len > 0:
            span(class = "ah-results-notice-hint"):
              text notice.hint
      # The term a line break must not split (a command's name, the
      # query) is a span of its own that does not wrap.
      let at = if notice.term.len > 0: notice.text.find(notice.term) else: -1
      if at >= 0:
        if at > 0: r.appendRendered(noticeText, textSpan(r, "", notice.text[0 ..< at]))
        r.appendRendered(noticeText, textSpan(r, "ah-results-term", notice.term))
        let rest = notice.text[at + notice.term.len .. ^1]
        if rest.len > 0: r.appendRendered(noticeText, textSpan(r, "", rest))
      else:
        r.appendRendered(noticeText, textSpan(r, "", notice.text))
      r.appendRendered(sheet, n)
    let query = vm.queryText
    let groups = vm.groups
    for gIndex in 0 ..< groups.len:
      let g = groups[gIndex]
      var rows: N
      let stateRole = stateRole(g.group)
      let state = stateWord(g.group)
      let gn = ui(r):
        tdiv(class = "ah-results-group", `data-ah-group` = g.group.id,
             `data-ah-state` = $g.group.state):
          tdiv(class = "ah-results-group-head"):
            span(`data-ah-cut` = "line", class = "ah-composer-section-label ah-results-group-title"):
              text g.group.title
            # A failure's reason wraps; any other state is one line, cut.
            if stateRole == "error":
              span(class = "ah-results-state ah-results-state-" & stateRole):
                text state
            else:
              span(`data-ah-cut` = "line", class = "ah-results-state ah-results-state-" & stateRole):
                text state
          tdiv(ref = rows, class = "ah-results-rows")
      r.appendRendered(sheet, gn)
      for i in 0 ..< g.rows.len:
        r.appendRendered(rows, renderRow[R, N](r, vm, g, i, g.rows[i], query))
      let more = moreLabel(g)
      if more.len > 0:
        let m = ui(r):
          tdiv(class = "ah-results-more", `data-ah-action` = "more",
               `data-ct-operation` = ResultsMoreOperation, `data-ah-target` = g.group.id):
            text more
        r.appendRendered(rows, m)
    # The providers that answered with nothing: one quiet line after the
    # groups, in place of a group each (P2c study D60).
    let empty = emptyProvidersLine(vm)
    if empty.len > 0:
      let e = ui(r):
        tdiv(class = "ah-results-empty", `data-ah-empty-providers` = empty):
          text empty
      r.appendRendered(sheet, e)
  when defined(js):
    when N is isonim_dom.Element:
      followMoreBelow(isonim_dom.Node(sheet))
  root

when defined(js):
  proc mountAgentHarborResults*(container: isonim_dom.Element; vm: ResultCommandsVM) =
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborResults[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
