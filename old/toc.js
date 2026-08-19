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
        this.innerHTML = '<ol class="chapter"><li class="chapter-item expanded "><a href="introduction.html"><strong aria-hidden="true">1.</strong> Introduction</a></li><li class="chapter-item expanded "><a href="installation.html"><strong aria-hidden="true">2.</strong> Installation</a></li><li class="chapter-item expanded "><a href="getting_started/overview.html"><strong aria-hidden="true">3.</strong> Getting Started</a></li><li><ol class="section"><li class="chapter-item expanded "><a href="getting_started/python.html"><strong aria-hidden="true">3.1.</strong> Python</a></li><li class="chapter-item expanded "><a href="getting_started/ruby.html"><strong aria-hidden="true">3.2.</strong> Ruby</a></li><li class="chapter-item expanded "><a href="getting_started/javascript.html"><strong aria-hidden="true">3.3.</strong> JavaScript / TypeScript</a></li><li class="chapter-item expanded "><a href="getting_started/wasm.html"><strong aria-hidden="true">3.4.</strong> WASM</a></li><li class="chapter-item expanded "><a href="getting_started/noir.html"><strong aria-hidden="true">3.5.</strong> Noir</a></li><li class="chapter-item expanded "><a href="getting_started/circom.html"><strong aria-hidden="true">3.6.</strong> Circom</a></li><li class="chapter-item expanded "><a href="getting_started/miden.html"><strong aria-hidden="true">3.7.</strong> Miden</a></li><li class="chapter-item expanded "><a href="getting_started/leo.html"><strong aria-hidden="true">3.8.</strong> Leo (Aleo)</a></li><li class="chapter-item expanded "><a href="getting_started/solidity.html"><strong aria-hidden="true">3.9.</strong> Solidity (EVM)</a></li><li class="chapter-item expanded "><a href="getting_started/stylus.html"><strong aria-hidden="true">3.10.</strong> Stylus</a></li><li class="chapter-item expanded "><a href="getting_started/cairo.html"><strong aria-hidden="true">3.11.</strong> Cairo (StarkNet)</a></li><li class="chapter-item expanded "><a href="getting_started/aiken.html"><strong aria-hidden="true">3.12.</strong> Aiken (Cardano)</a></li><li class="chapter-item expanded "><a href="getting_started/cadence.html"><strong aria-hidden="true">3.13.</strong> Cadence (Flow)</a></li><li class="chapter-item expanded "><a href="getting_started/move.html"><strong aria-hidden="true">3.14.</strong> Move (Sui / Aptos)</a></li><li class="chapter-item expanded "><a href="getting_started/solana.html"><strong aria-hidden="true">3.15.</strong> Solana</a></li><li class="chapter-item expanded "><a href="getting_started/sway.html"><strong aria-hidden="true">3.16.</strong> Sway (FuelVM)</a></li><li class="chapter-item expanded "><a href="getting_started/polkavm.html"><strong aria-hidden="true">3.17.</strong> PolkaVM (ink!)</a></li><li class="chapter-item expanded "><a href="getting_started/tolk.html"><strong aria-hidden="true">3.18.</strong> Tolk (TON)</a></li></ol></li><li class="chapter-item expanded "><a href="usage_guide/overview.html"><strong aria-hidden="true">4.</strong> Usage Guide</a></li><li><ol class="section"><li class="chapter-item expanded "><a href="usage_guide/cli.html"><strong aria-hidden="true">4.1.</strong> Command-line interface</a></li><li class="chapter-item expanded "><a href="usage_guide/gui.html"><strong aria-hidden="true">4.2.</strong> Graphical interface</a></li><li class="chapter-item expanded "><a href="usage_guide/visual_recordings.html"><strong aria-hidden="true">4.3.</strong> Visual recordings</a></li><li class="chapter-item expanded "><a href="usage_guide/tracepoints.html"><strong aria-hidden="true">4.4.</strong> Tracepoints</a></li><li class="chapter-item expanded "><a href="usage_guide/incremental-testing.html"><strong aria-hidden="true">4.5.</strong> Incremental Testing</a></li><li class="chapter-item expanded "><a href="usage_guide/value-origin-tracking.html"><strong aria-hidden="true">4.6.</strong> Value Origin Tracking</a></li><li class="chapter-item expanded "><a href="usage_guide/cross-tracer-demo.html"><strong aria-hidden="true">4.7.</strong> Cross-Tracer Demo</a></li><li class="chapter-item expanded "><a href="usage_guide/variable-rename-list.html"><strong aria-hidden="true">4.8.</strong> Variable Rename List</a></li><li class="chapter-item expanded "><a href="usage_guide/codetracer_shell.html"><strong aria-hidden="true">4.9.</strong> CodeTracer Shell</a></li><li class="chapter-item expanded "><a href="usage_guide/omniscient-db-size-bench.html"><strong aria-hidden="true">4.10.</strong> Omniscient-DB size benchmark</a></li><li class="chapter-item expanded "><a href="usage_guide/native-omniscient-timing-bench.html"><strong aria-hidden="true">4.11.</strong> Native omniscient timing benchmark</a></li><li class="chapter-item expanded "><a href="usage_guide/slice-prep-speed-bench.html"><strong aria-hidden="true">4.12.</strong> Slice prep speed benchmark</a></li><li class="chapter-item expanded "><a href="usage_guide/gui-ops-latency-bench.html"><strong aria-hidden="true">4.13.</strong> GUI-ops latency matrix benchmark</a></li></ol></li><li class="chapter-item expanded "><a href="reference/ct_cli.html"><strong aria-hidden="true">5.</strong> ct CLI Reference</a></li><li class="chapter-item expanded "><a href="reference/mcp-tools.html"><strong aria-hidden="true">6.</strong> MCP Tool Reference</a></li><li class="chapter-item expanded "><a href="reference/origin-kinds.html"><strong aria-hidden="true">7.</strong> Origin Kinds Reference</a></li><li class="chapter-item expanded "><a href="reference/recorders.html"><strong aria-hidden="true">8.</strong> Recorder CLI Reference</a></li><li class="chapter-item expanded "><a href="building_and_packaging/build_systems.html"><strong aria-hidden="true">9.</strong> Build systems</a></li><li class="chapter-item expanded "><a href="CONTRIBUTING.html"><strong aria-hidden="true">10.</strong> Contributing</a></li><li class="chapter-item expanded "><a href="misc/logs.html"><strong aria-hidden="true">11.</strong> Logs and Diagnostics</a></li><li class="chapter-item expanded "><a href="misc/troubleshooting.html"><strong aria-hidden="true">12.</strong> Troubleshooting</a></li><li class="chapter-item expanded "><a href="misc/environment_variables.html"><strong aria-hidden="true">13.</strong> Environment variables</a></li><li class="chapter-item expanded "><a href="misc/building_docs.html"><strong aria-hidden="true">14.</strong> Building the documentation</a></li></ol>';
        // Set the current, active page, and reveal it if it's hidden
        let current_page = document.location.href.toString().split("#")[0].split("?")[0];
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
