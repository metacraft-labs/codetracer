## codetracer/docs/book-isonim -- client JS mount entry (M1).
##
## The compiled `nim js` bundle every book page loads (via
## `bookDocsConfig().appScriptHref` -> `/assets/app.js`, injected in `<head>`
## by the framework's `shell.renderSecureDocumentHeadHtml`). It is strict
## PROGRESSIVE ENHANCEMENT: the SSR HTML is already a complete, navigable page
## (plain `<a>` sidebar links, default-expanded sections), and this bundle only
## ADDS live behaviour on top of the DOM the server already rendered --
##
##   * the header theme toggle (`#docs-theme-toggle`) flips + persists the
##     theme, sharing the exact `theme_vm` storage key/precedence the `<head>`
##     no-flash bootstrap uses;
##   * the header search box (`#docs-search-input`) filters this site's own
##     compile-time-embedded content index and renders results in place;
##   * each sidebar section title toggles its section's collapse state.
##
## Unlike a full client re-render, nothing here rebuilds the page tree or needs
## a `#root` mount node: it binds to the real SSR elements by their stable ids/
## classes, so a JS failure can never blank a server-rendered page. This site's
## own `content/` is embedded at compile time (there is no filesystem in the
## browser) so the search index matches exactly what the server rendered.

when not defined(js):
  {.error: "main.nim requires the JS backend: nim js -o:app.js src/main.nim".}

import std/[os, tables]
import isonim/web/dom_api
import isonim/web/web_renderer
import core/content
import core/content_embed
import core/routes
import core/search_vm
import core/theme_vm
import components/search_view
import components/theme_toggle

const embeddedContent = embedContentDir(currentSourcePath().parentDir() / "../content")
  ## Every `.md` file under this book's own `content/` dir, embedded at
  ## compile time via the framework's generic `content_embed.embedContentDir`.

proc loadEmbeddedContentEntry(contentPath: string): ContentEntry =
  parseContentEntry(embeddedContent[contentPath], contentPath)

proc siteSearchIndex(): SearchIndex =
  ## The real, site-wide search index built from this book's own embedded
  ## content graph -- the JS-target counterpart to the SSR/SSG search index,
  ## fed from the compile-time `embeddedContent` table instead of a filesystem
  ## walk (a draft page is skipped, exactly like the SSG manifest default).
  var entries: seq[ContentEntry] = @[]
  for contentPath, raw in embeddedContent:
    let entry = parseContentEntry(raw, contentPath)
    if not entry.front.draft:
      entries.add entry
  sortContentEntries(entries)
  buildSearchIndex(buildManifestFromEntries(entries), loadEmbeddedContentEntry)

# --- importcpp glue (same idioms as isonim-docs/src/main_web.nim) ----------
proc getInputValue(e: Element): cstring {.importcpp: "#.value".}
proc eventKey(e: Event): cstring {.importcpp: "#.key".}
proc elemIsNil(e: Element): bool {.importcpp: "(function(x){return x==null||x==undefined;})(#)".}
proc navigateTo(path: cstring) {.importcpp:
  "(typeof window !== 'undefined' && window.location) && (window.location.href = #)".}
proc documentElement(d: Document): Element {.importcpp: "#.documentElement".}
proc localStorageGetItem(key: cstring): cstring {.importcpp:
  "(function(){try{var v=localStorage.getItem(#);return (v===null||v===undefined)?'':v;}catch(e){return '';}})()".}
proc localStorageSetItem(key, value: cstring) {.importcpp:
  "(function(){try{localStorage.setItem(#, #);}catch(e){}})()".}
proc prefersDarkColorScheme(): bool {.importcpp:
  "(typeof window !== 'undefined' && window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches === true)".}

# --- live search (binds by id to the SSR search box) -----------------------
proc wireSearch(r: WebRenderer; index: SearchIndex) =
  let inputEl = getElementById(document, cstring(searchInputId))
  if elemIsNil(inputEl): return
  let wrapperEl = getElementById(document, cstring(searchResultsWrapperId))
  if elemIsNil(wrapperEl): return

  var vm = newSearchViewModel()

  proc rerenderResults() =
    r.clearChildren(wrapperEl)
    r.appendChild(wrapperEl, renderSearchResultsContent[WebRenderer, Node](r, vm))

  proc onInput(ev: Event) =
    vm = setQuery(vm, index, $getInputValue(inputEl))
    rerenderResults()

  proc onKeydown(ev: Event) =
    case $eventKey(ev)
    of "ArrowDown":
      vm = moveCursor(vm, 1); rerenderResults()
    of "ArrowUp":
      vm = moveCursor(vm, -1); rerenderResults()
    of "Enter":
      let selected = selectedResult(vm)
      if selected.routePath.len > 0: navigateTo(cstring(selected.routePath))
    else: discard

  r.addEventListener(inputEl, "input", onInput)
  r.addEventListener(inputEl, "keydown", onKeydown)

# --- live theme toggle (binds by id to the SSR toggle button) --------------
proc wireThemeToggle(r: WebRenderer) =
  let btn = getElementById(document, cstring(themeToggleId))
  if elemIsNil(btn): return
  let docEl = documentElement(document)
  var vm = newThemeViewModel($localStorageGetItem(cstring(themeStorageKey)), prefersDarkColorScheme())

  proc applyTheme() =
    ## Bind the theme string to a PLAIN LOCAL before handing it to the
    ## IIFE-wrapped `localStorageSetItem`: Nim's JS backend reaches a captured
    ## closure var (`vm.theme`) via `this.vm`, but inside `localStorageSetItem`'s
    ## `(function(){...})()` IIFE `this` rebinds, so splicing `this.vm.theme`
    ## straight in throws (caught by its own try/catch -> a silent no-op).
    ## A local stays reachable through the IIFE's normal lexical closure.
    let themeStr = themeToString(vm.theme)
    let otherStr = themeToString(otherTheme(vm.theme))
    setAttribute(docEl, cstring(themeAttrName), cstring(themeStr))
    localStorageSetItem(cstring(themeStorageKey), cstring(themeStr))
    setAttribute(btn, "data-theme", cstring(themeStr))
    setAttribute(btn, "aria-pressed", cstring(if vm.theme == thDark: "true" else: "false"))
    setAttribute(btn, "aria-label", cstring("Switch to " & otherStr & " theme"))

  applyTheme()
  proc onClick(ev: Event) =
    vm = toggle(vm)
    applyTheme()
  r.addEventListener(btn, "click", onClick)

# --- sidebar click-to-collapse (self-contained JS over the SSR markup) -----
proc wireSidebarCollapse() {.importcpp: """
(function(){
  try {
    var toggles = document.querySelectorAll('.docs-nav-section-title');
    for (var i = 0; i < toggles.length; i++) {
      (function(btn){
        btn.addEventListener('click', function(){
          var section = btn.parentNode;
          if (!section) return;
          var open = section.classList.contains('docs-nav-section-expanded');
          if (open) {
            section.classList.remove('docs-nav-section-expanded');
            btn.setAttribute('aria-expanded', 'false');
          } else {
            section.classList.add('docs-nav-section-expanded');
            btn.setAttribute('aria-expanded', 'true');
          }
        });
      })(toggles[i]);
    }
  } catch (e) {}
})()
""".}

when isMainModule:
  let r = WebRenderer()
  wireSearch(r, siteSearchIndex())
  wireThemeToggle(r)
  wireSidebarCollapse()
