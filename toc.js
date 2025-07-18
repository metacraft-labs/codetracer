// Populate the sidebar
//
// This is a script, and not included directly in the page, to control the total size of the book.
// The TOC contains an entry for each page, so if each page includes a copy of the TOC,
// the total size of the page becomes O(n**2).
class MDBookSidebarScrollbox extends HTMLElement {
    constructor() {
        super();
    }
    connectedCallback() {
        this.innerHTML = '<ol class="chapter"><li class="chapter-item expanded "><a href="introduction.html"><strong aria-hidden="true">1.</strong> Introduction</a></li><li class="chapter-item expanded "><a href="installation.html"><strong aria-hidden="true">2.</strong> Installation</a></li><li class="chapter-item expanded "><a href="usage_guide/intro_to_usage.html"><strong aria-hidden="true">3.</strong> Intro to usage guide</a></li><li class="chapter-item expanded "><a href="usage_guide/CLI.html"><strong aria-hidden="true">4.</strong> CLI</a></li><li class="chapter-item expanded "><a href="usage_guide/basic_gui.html"><strong aria-hidden="true">5.</strong> Basic GUI</a></li><li class="chapter-item expanded "><a href="usage_guide/tracepoints.html"><strong aria-hidden="true">6.</strong> Tracepoints</a></li><li class="chapter-item expanded "><a href="usage_guide/codetracer_shell.html"><strong aria-hidden="true">7.</strong> CodeTracer Shell</a></li><li class="chapter-item expanded "><a href="backends/db_backend.html"><strong aria-hidden="true">8.</strong> DB backend</a></li><li><ol class="section"><li class="chapter-item expanded "><a href="backends/db-backend/noir.html"><strong aria-hidden="true">8.1.</strong> Noir</a></li><li class="chapter-item expanded "><a href="backends/db-backend/ruby.html"><strong aria-hidden="true">8.2.</strong> Ruby</a></li><li class="chapter-item expanded "><a href="backends/db-backend/py.html"><strong aria-hidden="true">8.3.</strong> Python</a></li><li class="chapter-item expanded "><a href="backends/db-backend/lua.html"><strong aria-hidden="true">8.4.</strong> Lua</a></li><li class="chapter-item expanded "><a href="backends/db-backend/small.html"><strong aria-hidden="true">8.5.</strong> small</a></li><li class="chapter-item expanded "><a href="usage_guide/stylus_and_wasm.html"><strong aria-hidden="true">8.6.</strong> Stylus and WASM</a></li></ol></li><li class="chapter-item expanded "><a href="backends/rr_backend.html"><strong aria-hidden="true">9.</strong> RR backend</a></li><li><ol class="section"><li class="chapter-item expanded "><a href="backends/rr-backend/c_and_cpp.html"><strong aria-hidden="true">9.1.</strong> C &amp; C++</a></li><li class="chapter-item expanded "><a href="backends/rr-backend/rust.html"><strong aria-hidden="true">9.2.</strong> Rust</a></li><li class="chapter-item expanded "><a href="backends/rr-backend/nim.html"><strong aria-hidden="true">9.3.</strong> Nim</a></li><li class="chapter-item expanded "><a href="backends/rr-backend/go.html"><strong aria-hidden="true">9.4.</strong> Go</a></li></ol></li><li class="chapter-item expanded "><a href="building_and_packaging/build_systems.html"><strong aria-hidden="true">10.</strong> Build systems</a></li><li class="chapter-item expanded "><a href="CONTRIBUTING.html"><strong aria-hidden="true">11.</strong> Contributing</a></li><li class="chapter-item expanded "><a href="misc/troubleshooting.html"><strong aria-hidden="true">12.</strong> Troubleshooting</a></li><li class="chapter-item expanded "><a href="misc/environment_variables.html"><strong aria-hidden="true">13.</strong> Environment variables</a></li><li class="chapter-item expanded "><a href="misc/building_docs.html"><strong aria-hidden="true">14.</strong> Building the documentation</a></li></ol>';
        // Set the current, active page, and reveal it if it's hidden
        let current_page = document.location.href.toString();
        if (current_page.endsWith("/")) {
            current_page += "index.html";
        }
        var links = Array.prototype.slice.call(this.querySelectorAll("a"));
        var l = links.length;
        for (var i = 0; i < l; ++i) {
            var link = links[i];
            var href = link.getAttribute("href");
            if (href && !href.startsWith("#") && !/^(?:[a-z+]+:)?\/\//.test(href)) {
                link.href = path_to_root + href;
            }
            // The "index" page is supposed to alias the first chapter in the book.
            if (link.href === current_page || (i === 0 && path_to_root === "" && current_page.endsWith("/index.html"))) {
                link.classList.add("active");
                var parent = link.parentElement;
                if (parent && parent.classList.contains("chapter-item")) {
                    parent.classList.add("expanded");
                }
                while (parent) {
                    if (parent.tagName === "LI" && parent.previousElementSibling) {
                        if (parent.previousElementSibling.classList.contains("chapter-item")) {
                            parent.previousElementSibling.classList.add("expanded");
                        }
                    }
                    parent = parent.parentElement;
                }
            }
        }
        // Track and set sidebar scroll position
        this.addEventListener('click', function(e) {
            if (e.target.tagName === 'A') {
                sessionStorage.setItem('sidebar-scroll', this.scrollTop);
            }
        }, { passive: true });
        var sidebarScrollTop = sessionStorage.getItem('sidebar-scroll');
        sessionStorage.removeItem('sidebar-scroll');
        if (sidebarScrollTop) {
            // preserve sidebar scroll position when navigating via links within sidebar
            this.scrollTop = sidebarScrollTop;
        } else {
            // scroll sidebar to current active section when navigating via "next/previous chapter" buttons
            var activeSection = document.querySelector('#sidebar .active');
            if (activeSection) {
                activeSection.scrollIntoView({ block: 'center' });
            }
        }
        // Toggle buttons
        var sidebarAnchorToggles = document.querySelectorAll('#sidebar a.toggle');
        function toggleSection(ev) {
            ev.currentTarget.parentElement.classList.toggle('expanded');
        }
        Array.from(sidebarAnchorToggles).forEach(function (el) {
            el.addEventListener('click', toggleSection);
        });
    }
}
window.customElements.define("mdbook-sidebar-scrollbox", MDBookSidebarScrollbox);
