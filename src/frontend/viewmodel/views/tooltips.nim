## tooltips.nim — the one tooltip of the desktop's panels
## (docs/UI-Design-Decisions.md, D-28).
##
## A control states its tooltip as a plain `title`. This module shows that text in
## the design system's Tooltip (`.ct-tooltip`, tooltip.styl) instead of the
## operating system's, after a short rest on the control or when the keyboard
## reaches it:
##
##   * a `title` is taken off its element and its ancestors only while that element
##     is the tooltip's source, because the system's tooltip cannot be turned off any
##     other way; it is back as soon as the pointer or focus leaves;
##   * a `title` that repeats the text on screen shows nothing, unless that text is
##     cut off;
##   * text cut off with an ellipsis shows its full value, with no `title` needed;
##   * a `.custom-tooltip` child keeps its own hover rule (the debug toolbar's tests
##     read it there); only the keyboard reads its text from here.
##
## THE LISTENERS ARE ON THE DOCUMENT, ONCE, because views rebuild their elements.
## Nothing runs until the pointer crosses into another element or focus moves, and
## no element is measured until the tooltip is about to show.

when defined(js):
  proc installTooltips() {.importjs: """
    (function () {
      if (typeof document === 'undefined' || globalThis.__ctTooltips) return;
      globalThis.__ctTooltips = true;
      var DELAY = 200, GAP = 8, EDGE = 8, CUT_DEPTH = 3;
      // The editor shows its own hovers; a tracepoint's box inside it is ours.
      var OWN_TOOLTIPS = '.monaco-editor, [data-ct-cell]', OURS_INSIDE = '.trace';
      var BUILT_IN = [['.jstree-ocl', 'Show or hide the folder']];
      var box = null, current = null, timer = 0;

      function isOwn(el) {
        return !!el.closest(OWN_TOOLTIPS) && !el.closest(OURS_INSIDE);
      }
      function words(s) { return (s || '').replace(/\s+/g, ' ').trim(); }
      function isCut(el) {
        return el.scrollWidth > el.clientWidth &&
          getComputedStyle(el).textOverflow === 'ellipsis';
      }
      function restore() {
        if (!current) return;
        current.saved.forEach(function (one) {
          if (!one.el.hasAttribute('title')) one.el.setAttribute('title', one.title);
        });
        if (current.named) current.el.removeAttribute('aria-label');
      }
      function hide() {
        clearTimeout(timer);
        if (box) box.classList.remove('ct-tooltip--shown');
        if (current) current.el.removeAttribute('aria-describedby');
      }
      function leave() { hide(); restore(); current = null; }
      function place() {
        if (!current || !current.text || !current.el.isConnected) return;
        if (!box) {
          box = document.createElement('div');
          box.className = 'ct-tooltip';
          box.id = 'ct-tooltip';
          box.setAttribute('role', 'tooltip');
          document.body.appendChild(box);
        }
        box.textContent = current.text;
        // Measured from the corner: at its last place, near an edge, it would wrap.
        box.style.left = '0';
        box.style.top = '0';
        box.classList.remove('ct-tooltip--lg');
        box.classList.add('ct-tooltip--shown');
        box.classList.toggle('ct-tooltip--lg',
          box.offsetHeight > 2 * parseFloat(getComputedStyle(box).lineHeight));
        var r = current.el.getBoundingClientRect();
        var w = box.offsetWidth, h = box.offsetHeight;
        var above = r.bottom + GAP + h > innerHeight - EDGE && r.top - GAP - h >= EDGE;
        var left = Math.max(EDGE, Math.min(r.left + r.width / 2 - w / 2, innerWidth - w - EDGE));
        box.style.left = left + 'px';
        box.style.top = (above ? r.top - GAP - h : r.bottom + GAP) + 'px';
        current.el.setAttribute('aria-describedby', 'ct-tooltip');
      }
      function enter(found, how) {
        leave();
        var el = found.el, title = el.getAttribute('title'), named = false, saved = [];
        if (title !== null && !el.hasAttribute('aria-label') && !words(el.innerText)) {
          el.setAttribute('aria-label', title);
          named = true;
        }
        // Up to the root: with its own `title` gone, the system's tooltip would
        // fall back to the nearest ancestor's.
        for (var up = el; up; up = up.parentElement) {
          if (up.hasAttribute('title')) {
            saved.push({ el: up, title: up.getAttribute('title') });
            up.removeAttribute('title');
          }
        }
        current = { el: el, text: found.text, saved: saved, named: named, how: how };
        if (found.text) timer = setTimeout(place, DELAY);
      }
      function fromTitle(el, target) {
        var title = el.getAttribute('title');
        var repeats = words(title) === words(el.innerText);
        return { el: el, text: repeats && !isCut(el) && !isCut(target) ? '' : title };
      }
      function builtIn(el) {
        for (var i = 0; i < BUILT_IN.length; i++) {
          if (el.matches(BUILT_IN[i][0])) return { el: el, text: BUILT_IN[i][1] };
        }
        return null;
      }
      function sourceOf(target) {
        if (!target || !target.closest || isOwn(target)) return null;
        var titled = target.closest('[title]');
        if (titled) return fromTitle(titled, target);
        var el = target;
        for (var i = 0; el && i < CUT_DEPTH; i++, el = el.parentElement) {
          if (el.querySelector(':scope > .custom-tooltip')) return null;
          var known = builtIn(el);
          if (known) return known;
          if (isCut(el)) return { el: el, text: words(el.textContent) };
        }
        return null;
      }
      function focusSource(el) {
        var own = el.querySelector(':scope > .custom-tooltip');
        if (own) return { el: el, text: words(own.textContent) };
        if (el.hasAttribute('title')) return fromTitle(el, el);
        var known = builtIn(el);
        if (known) return known;
        return isCut(el) ? { el: el, text: words(el.textContent) } : null;
      }

      document.addEventListener('pointerover', function (ev) {
        var found = sourceOf(ev.target);
        if (found && current && current.el === found.el) return;
        if (found) enter(found, 'pointer');
        else if (current) leave();
      }, { capture: true, passive: true });
      document.addEventListener('pointerout', function (ev) {
        if (!ev.relatedTarget && current && current.how === 'pointer') leave();
      }, { capture: true, passive: true });
      document.addEventListener('focusin', function (ev) {
        var el = ev.target;
        if (!el.matches || !el.matches(':focus-visible')) return;
        if (document.documentElement.getAttribute('data-focus-mode') === 'mouse') return;
        if (isOwn(el)) return;
        var found = focusSource(el);
        if (found) enter(found, 'focus');
        else if (current) leave();
      });
      document.addEventListener('focusout', function () {
        if (current && current.how === 'focus') leave();
      });
      window.addEventListener('keydown', function (ev) { // ir1-gate: not a key: any key but Tab hides it
        if (ev.key !== 'Tab') hide();
      }, true);
      document.addEventListener('pointerdown', hide, { capture: true, passive: true });
      document.addEventListener('scroll', function (ev) {
        if (current && ev.target.contains && ev.target.contains(current.el)) hide();
      }, { capture: true, passive: true });
      window.addEventListener('blur', hide);
    })()""".}

  installTooltips()
