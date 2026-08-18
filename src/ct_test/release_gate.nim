import std/[algorithm, os, sequtils, strutils, tables]

import contracts
import discovery

type
  ProviderGateEntry* = object
    providerId*: string
    fixturePath*: string
    researchDoc*: string
    providerTest*: string
    sourceFiles*: seq[string]
    heavy*: bool

  GuiActionGateEntry* = object
    action*: string
    visibleSurface*: string
    mockCoverage*: string
    nonMockCoverage*: string
    unsupportedDiagnostic*: string

const
  SupportMatrixPath* = "docs/ct-test-support-matrix.md"
  EditorControlsVmTest =
    "src/frontend/viewmodel/tests/unit/test_editor_test_controls_m4.nim"
  LanguageSmokeMockTest =
    "src/tests/gui/tests/integration/language_smoke_mock_test.nim"
  LanguageSmokeTest =
    "src/tests/gui/tests/integration/language_smoke_test.nim"
  SmartHarnessResearchDoc =
    "src/ct_test/framework_research/smart-contract-vm-harnesses.md"
  SmartHarnessProviderTest =
    "src/ct_test/m13_smart_contract_harnesses_test.nim"
  SmartHarnessSourceFiles = @[
    "src/ct_test/frameworks/smart_contract_harnesses.nim",
    "src/ct_test/frameworks/smart_contract_common.nim"]
  UnsupportedRecordDiagnostic =
    "recording capability remains unsupported with explicit diagnostic"

  CoreViewModelGateTests* = [
    EditorControlsVmTest,
    "src/frontend/viewmodel/tests/unit/test_test_explorer_vm.nim",
    "src/tests/gui/tests/editor/editor_vm_test.nim",
    "src/tests/gui/tests/welcome-screen/welcome_screen_vm_test.nim",
    "src/tests/gui/tests/views/isonim_views_test.nim",
    # RS-M3: the Request Panel's live span-delta path.  Registered here
    # because this array IS the CI gate — a ViewModel test that exists but
    # is not listed runs nowhere (a gap this campaign found repeatedly).
    "src/tests/gui/tests/request-panel/request_panel_live_vm_test.nim",
    # RS-M4: the GUI demo launch path.  `demo_recipe_produces_populated_session`
    # runs `just demo-request-panel`'s container-production step headlessly and
    # asserts meta.dat bit 13 plus the rendered rows, so the recipe cannot rot
    # unnoticed.  Native-only (real container bytes through a zstd FFI), hence
    # excluded from `just test-vm-js` and listed here.
    "src/tests/gui/tests/request-panel/demo_recipe_vm_test.nim",
    # RS-M5: the Python row of the language matrix.  `vm_python_request_panel_rows`
    # drives the panel from a container the Python recorder produced while a real
    # Flask app served real HTTP requests, and asserts the rows, the status
    # colouring and the double-click seek into the handler.  Native-only (real
    # container bytes through a zstd FFI), hence excluded from `just test-vm-js`
    # and listed here.
    "src/tests/gui/tests/request-panel/python_request_panel_vm_test.nim",
    # RS-M6: the Ruby row of the language matrix.  `vm_ruby_request_panel_rows`
    # drives the panel from a container the Ruby recorder produced while a real
    # Sinatra app served real HTTP requests through the Rack middleware, and
    # asserts the rows, the status colouring and the double-click seek into the
    # handler.  Native-only (real container bytes through a zstd FFI), hence
    # excluded from `just test-vm-js` and listed here.
    "src/tests/gui/tests/request-panel/ruby_request_panel_vm_test.nim",
    # RS-M7: the PHP row of the language matrix.
    # `vm_php_request_panel_rows_and_seek` drives the panel from a container the
    # PHP recorder produced while a real `php -S` process served real HTTP
    # requests, and asserts the rows plus that activating a row seeks into that
    # request's own step range.  PHP is the milestone that moved the writer from
    # per-request to per-worker lifetime, so this is also the GUI-side guard that
    # eight requests are eight intervals of ONE recording.  Native-only (real
    # container bytes through a zstd FFI), hence excluded from `just test-vm-js`
    # and listed here.
    "src/tests/gui/tests/request-panel/php_request_panel_vm_test.nim",
    # RS-M8: the Elixir/Erlang row of the language matrix.
    # `vm_elixir_request_panel_rows` drives the panel from a container the BEAM
    # recorder produced while a real Cowboy listener served real HTTP requests
    # to a real `Plug.Router`.  It is the row where a request is a *thread* of
    # the recording rather than a slice of one thread's timeline — Cowboy
    # serves each request on its own BEAM process — so this is also the
    # GUI-side guard that concurrent, genuinely overlapping requests still
    # render as twelve distinct rows with twelve distinct seek targets.
    # Native-only (real container bytes through a zstd FFI), hence excluded
    # from `just test-vm-js` and listed here.
    "src/tests/gui/tests/request-panel/elixir_request_panel_vm_test.nim",
    # RS-M9: the JavaScript/Node row of the language matrix.
    # `vm_js_request_panel_rows` drives the panel from a container the JS
    # recorder produced while a real Express app on a real `http.Server`
    # served real HTTP requests over loopback.  Node is the row where a
    # request is a slice of ONE event loop, so this is the GUI-side guard
    # that `contiguous_on_one_thread` is measured rather than declared: the
    # handlers that never yield are contiguous, the POST (whose body parser
    # awaits) and the `await`ing handler are not, and the fixture requires
    # both values to appear.  It also asserts that every row's step range
    # covers ITS OWN handler's lines, which is what makes a double-click
    # land in the source rather than merely at a distinct coordinate.
    # Native-only (real container bytes through a zstd FFI), hence excluded
    # from `just test-vm-js` and listed here.
    "src/tests/gui/tests/request-panel/js_request_panel_vm_test.nim",
    # RS-M10: the native/MCR row of the language matrix.
    # `vm_native_request_panel_rows` drives the panel from a container
    # `ct-mcr record` produced while a real nginx served real HTTP requests
    # over loopback.  It is the row where NOTHING in the recorded program
    # knows what a request is — nginx has no middleware seam and the recorder
    # records syscalls — so the spans are DISCOVERED from the recording's own
    # `recv` / `writev` payloads and appended to the container afterwards.
    # That makes this the GUI-side guard for two things no other row covers:
    # that a post-pass stamps `meta.dat` bit 13 on an already-closed
    # container, and that a stream of settled-only records (no open/settled
    # pair, because a post-pass has no in-flight moment) still renders.
    # Native-only (real container bytes through a zstd FFI), hence excluded
    # from `just test-vm-js` and listed here.
    "src/tests/gui/tests/request-panel/native_request_panel_vm_test.nim",
    # RS-M11: the remote row.  `vm_remote_request_panel_rows` drives the panel
    # from the payloads the production remote tail emitted over a real HTTP
    # socket while a growing container was served with byte-range requests
    # (captured by `src/db-backend/tests/remote_span_tail_http_test.rs`, which
    # re-derives and re-checks the capture on every run).  It is the GUI-side
    # guard for the milestone's central claim — that a remote live session
    # needs NO new protocol, so the panel renders it with no remote code path
    # at all.  Excluded from `just test-vm-js` because it reads the capture and
    # the span-stream ground truth from disk, which `std/os` cannot do on the
    # `nim js` backend.
    "src/tests/gui/tests/request-panel/remote_request_panel_vm_test.nim",
    # RS-M12: the CROSS-language row.  `request_span_conformance_all_languages`
    # runs ONE assertion set over all six recorded fixtures — Python, Ruby,
    # PHP, Elixir, JavaScript and native — and asserts it against a per-
    # language capability declaration (`request_span_languages.nim`).  The six
    # tests above each know their own session by heart, which is what makes
    # them good regression tests and also what made them blind to a recorder
    # drifting away from the others: nothing forced the six to agree.  This is
    # that agreement, and it fails per language naming the field, so one run
    # says WHICH recorder broke and WHICH key it broke on.  The declaration is
    # what keeps it honest: the genuine differences (native publishes no open
    # records and has no step stream, Elixir's step ranges hold no application
    # source position, `contiguous_on_one_thread` legitimately varies) are
    # asserted as declared values rather than waived, so an unintended change
    # in any of them still fails.  Native-only (real container bytes through a
    # zstd FFI), hence excluded from `just test-vm-js` and listed here.
    #
    # The milestone's other required test,
    # `no_recorder_writes_sidecar_manifests`, is deliberately NOT here: it
    # drives a real recording per language through the recorder siblings, so
    # it belongs in the sibling-gated `just test-no-sidecar-manifests` lane
    # rather than in this toolchain-free one.
    "src/tests/gui/tests/request-panel/request_span_conformance_test.nim",
    # pxor bug campaign (2026-08).  Each of these pins a defect that had
    # previously been reported fixed and was not, so the gate is the point:
    # an ungated ViewModel test is how three of these regressed unnoticed in
    # the first place.
    #
    # #612 (M44) — the Scratchpad merges repeat captures of one expression
    # instead of appending a duplicate row.  Guards the spec behaviour in
    # `GUI/Core-Panes/Scratchpad-Pane.md` that was never implemented.
    # (The event-bus teardown half of #612 is guarded by
    # `src/frontend/tests/scratchpad_add_dispatch_test.nim`, which runs in
    # the `just test-frontend-js` lane because `communication.nim` is
    # JS-only and cannot compile on this array's native backend.)
    "src/tests/gui/tests/scratchpad/scratchpad_vm_test.nim",
    # #576 (M22) — auto-expansion to the active file.  The feature did not
    # exist; the test that was cited as its verification exercised the
    # unrelated single-child chain collapse and never set an active file.
    # #574 (M20) — `traceFilesRootFor` returning "" when no trace is loaded,
    # the nil dereference that left the tree on "Loading..." forever.
    "src/tests/gui/tests/filesystem/filesystem_vm_test.nim",
    # #558 (M6) — value history rendering into the MOUNTED panel.  The prior
    # test re-rendered a fresh panel, which is exactly what let a one-shot
    # `for` inside `ui()` pass as reactive.
    "src/frontend/viewmodel/tests/unit/test_state_value_history_toggle.nim",
    # #608 (M41) — the saved layout breaking on the next open.  The persisted
    # config was stripped of its editor tabs on every replay-mode save
    # without remapping the enclosing stack's `activeItemIndex`, so
    # GoldenLayout threw `ActiveItemIndex out of range` at restore and only
    # `just reset-layout` recovered it.  The JS branch drives the real
    # sanitiser/repair logic (`src/frontend/index/layout_config_repair.nim`)
    # headlessly; the native branch asserts the production call sites still
    # route through it and that the auto-hide state is persisted, handled and
    # restored.  Listed here because the GUI-level `layout_resilience.spec.ts`
    # is NOT coverage: every shape it writes is rejected by
    # `isValidLayoutConfig` before GoldenLayout ever sees it, which is how
    # this defect stayed invisible.
    "src/tests/gui/tests/layout/layout_config_roundtrip_test.nim",
    # #610 (M42a) and DR-R8 — what starting a review does to the layout.
    # Launching `ct review` pasted a hard-coded three-panel preset over
    # `data.ui.resolvedConfig`, so FILES, STATE, SCRATCHPAD, AGENT ACTIVITY,
    # EVENT LOG, TIMELINE and TERMINAL OUTPUT were gone for the session and
    # the user's own layout was ignored.  M42a made placement additive; DR-R8
    # removed the thing being placed, because DeepReview has no panel of its
    # own (DeepReview-GUI.md §7), leaving only Layout-System.md's "focus, not
    # relocation" obligation.  The behavioural half asserts that a review
    # keeps every panel of the REAL bundled `src/config/default_layout.json`,
    # adds none, re-shapes no container, and focuses the VCS and Agent
    # Activity panels; the native-only source-contract half asserts the
    # startup path is actually wired through that helper and that the deleted
    # panel is really gone, which is the part no layout test could catch —
    # the old code called no layout helper at all.  It also carries
    # Layout-System.md obligation 4 — an absent Agent Activity panel is
    # materialised rather than left missing — including the placement rule
    # that keeps the materialised pillar out of the stack hosting the VCS
    # panel, since two tabs of one stack cannot both be the visible one.
    "src/tests/gui/tests/layout/deepreview_layout_test.nim",
    # RV-2 — a review over a dataset opens the EDITOR layout, not the
    # debugging one.  `ct review <PATH>` loads no recording at all, so the
    # debugging layout's EVENT LOG, CALLTRACE, TIMELINE and TERMINAL OUTPUT
    # panels came up present but EMPTY, which reads as missing data
    # (DeepReview-GUI.md §1.1).  The behavioural half runs the real hidden-set
    # rule and the real sanitiser over the real bundled
    # `src/config/default_layout.json`; the native-only source-contract half
    # asserts the wiring the rule alone cannot catch — the editor layout and
    # its loader both already existed and the review launch simply did not use
    # them.  It also pins the two boundaries RV-2 must not cross: launch
    # methods 2 and 3 (which HAVE a recording) keep the debugging layout, and
    # the review still enters through the one shared routine.
    #
    # Separate from `deepreview_layout_test.nim` because that file's subject
    # is what a review does to whatever layout it is given ("focus, not
    # relocation"); this one's subject is WHICH layout it is given.
    #
    # It also carries the follow-up RV-2's own suites could not see, because
    # every one of them asserted over the BUNDLED layout: the file a review
    # actually reads is `default_edit_layout.json`, which edit mode WRITES
    # through a sanitiser that deletes `Content.AgentActivity`.  A hidden set
    # can decline to remove a panel; it cannot restore one the file never had.
    # The "PERSISTED edit layout" suite runs the whole chain — the bytes edit
    # mode saves, read back by the review loader, prepared by the renderer —
    # and asserts all three pillars come out of it visible at once.  Every
    # stage was individually correct, which is why asserting on stages missed
    # it.
    "src/tests/gui/tests/layout/review_layout_test.nim",
    # DR-R1 (DeepReview-GUI.milestones.org) — a review must be navigable:
    # clicking a changed file opens it, a review opens its first file on
    # startup, and the view-mode toggle is reachable in review mode.  The
    # decision lives in `VCSVM.openActionFor` and the entry step in
    # `viewmodels/review_entry` precisely so those three are assertable
    # without a browser; `vcs_vm_test.nim` covers the resolver (including the
    # deleted-file rule), `vcs_view_test.nim` the review-mode render branch,
    # and the review-entry suite of `deepreview_vm_test.nim` the startup step
    # over the same `sample-review.json` fixture the Playwright suite uses.
    #
    # DR-R2 grew the same two VCS files rather than adding new ones: the
    # review's trace-context selector and stats moved out of the standalone
    # panel into the VCS panel header, so `vcs_vm_test.nim` also covers the
    # header's trace-context state and `vcs_view_test.nim` also covers the
    # selector's rendering, its change handler, and the guard that neither
    # element appears in a normal version-control session.
    "src/tests/gui/tests/vcs/vcs_vm_test.nim",
    "src/tests/gui/tests/vcs/vcs_view_test.nim",
    "src/tests/gui/tests/deepreview/deepreview_vm_test.nim",
    # DR-R4 — the unified diff became a real Monaco tab.  The whole point of
    # extracting `viewmodel/viewmodels/diff_document.nim` is that the diff's
    # appearance stops being CSS on `tdiv` elements and becomes data: which
    # lines are added / removed / context, where the `@@` dividers go, which
    # `+` / `-` gutter marker each line carries, and what the dual old/new
    # line numbers read.  This file asserts all of it headlessly, including
    # VCS-Panel.md's rule that the builder never consults the mode.
    #
    # DR-R4 also grew `vcs_vm_test.nim` (already listed above) with the hunk
    # editor: selection, shift-click ranges, ctrl-click toggling and a
    # checked-in copy-as-patch golden.  That model used to live in
    # `ui/vcs.nim`, where no headless test could reach it, so porting the
    # renderer could have deleted a specified capability silently.
    "src/tests/gui/tests/vcs/vcs_diff_decorations_test.nim",
    # DR-R5 — context expansion in the diff tab.  Until it landed the whole
    # capability was private procs inside `ui/deepreview.nim`, a JS-only
    # module with no importable entry point, so the boundary arithmetic that
    # decides how many lines exist above a hunk near the top of a file — the
    # arithmetic that produces blank lines numbered 0 and -1 when it is wrong
    # — was asserted by nothing.  This file asserts the window computation,
    # its clamping at both file boundaries, the fetch-once-per-(revision,path)
    # cache the normal-git content source needs, and that a revealed line is a
    # plain context line of the document rather than a fourth, inert kind.
    #
    # DR-R5 also grew `vcs_vm_test.nim` (already listed above) with the
    # per-hunk expansion counters, which used to be a JS-side `JsAssoc` on the
    # component and therefore unreachable headlessly and lost on every
    # re-render.
    "src/tests/gui/tests/vcs/vcs_context_expansion_test.nim",
    # DR-R3 — the Agent Activity panel as DeepReview's third pillar.  The
    # panel's ViewModel, view and component all existed and were all wired to
    # nothing: the only caller of `setCoverageSummary` / `setTestResults` /
    # `setFileCoverage` in the repository was a storybook fixture, so the
    # section rendered an empty shell in every real review.  The suite added
    # here drives review entry over the same `sample-review.json` fixture the
    # Playwright suites use and asserts the coverage summary, the per-file
    # table, the honest "no test results in this dataset" state, and that the
    # coverage table and the VCS panel's Changed Files list stay one
    # selection.  The file existed before DR-R3 and was NOT listed here, so it
    # was gated by nothing at all — the same gap DR-R1 kept finding.
    #
    # The view half rides in `isonim_views_test.nim` (already listed above):
    # the section now renders *inside* the Agent Activity panel, per
    # DeepReview-GUI.md §2.1, so its rendering is that panel's business.  The
    # focus half rides in `deepreview_layout_test.nim` (also listed).
    #
    # DR-R8 added its deletion guard here rather than to a new file:
    # `Content.AgentActivityDeepReview` is a DIFFERENT id from the deleted
    # `Content.DeepReview` and the names are nearly identical, so the suite
    # that owns this pane is where "we deleted the other one" belongs.  It
    # asserts the pane still populates from a dataset after the deletion, and
    # — as a native-only source contract — that its content id, registration,
    # component and whole module stack survive while the standalone panel's
    # id and modules are the ones that went.
    "src/tests/gui/tests/agent-activity-deepreview/agent_activity_deepreview_vm_test.nim",
    # DR-R7 — one review-entry routine for all three launch paths.  The three
    # ways into a review (`ct review`, a trace with an associated diff,
    # the agentic handoff) used to configure review state their own way, and
    # the agentic one additionally reached into the standalone DeepReview
    # panel.  This file drives each path's *production* projection over the
    # same `sample-review.json` fixture, feeds each result to the one entry
    # routine, and asserts the three review states agree; it also pins
    # Layout-System.md's idempotence obligation (re-entry opens no second tab
    # and does not override the reviewer's own file selection), which matters
    # because `syncProductPanels` re-enters on every sync.
    #
    # It also carries the per-file half of a review dataset, which DR-R7 fixed
    # but did not test: `deepReviewHunks` took only the ViewModel, so every
    # file of a review was handed whichever file the editor happened to be
    # showing — a reviewer opening a deleted `config.rs` was shown `main.rs`'s
    # modification, and context expansion revealed `main.rs`'s text inside it.
    # `test_every_review_file_gets_its_own_diff` drives a three-file changeset
    # (a modification, an addition and a deletion) through the projection that
    # rule now lives in and asserts each file gets its own hunks, its own
    # source content, and none of its neighbours'.  A one-file changeset cannot
    # distinguish those, which is why the only end-to-end assertion that
    # existed (`agentic-worktree.spec.ts`, and it needs a live Harbor server)
    # did not guard it.
    #
    # Its second suite is a source contract, native only: the launch paths
    # live in `ui_js.nim` / `ui/vcs.nim` / `ui/agentic_session_launcher.nim`,
    # which need Electron and GoldenLayout, so reading them is the only way to
    # assert headlessly that they call the shared routine rather than
    # re-implementing review entry.  Same reason `deepreview_layout_test.nim`
    # (listed above) carries one.
    "src/tests/gui/tests/deepreview/deepreview_entry_test.nim",
    # #603 (M38) — the re-record queue's decision model.  Both encode the two
    # "never hang" invariants: a failed save must abort loudly, and dirty files
    # with nothing in flight is unreachable-by-waiting.  Note
    # `file_conflicts_vm_test.nim` already existed and was NOT listed here, so
    # it was gated by nothing at all.
    "src/tests/gui/tests/welcome-screen/file_conflicts_vm_test.nim",
    "src/tests/gui/tests/welcome-screen/re_record_queue_vm_test.nim",
    # #594 (M33) — the flow decoration layer must survive the window between
    # `loadFlow` and `ct/updated-flow`, during which the flow data is nil and
    # the computed decoration set is empty.  Replacing it with that empty set
    # is what wiped the branch colours on every step.
    "src/tests/gui/tests/editor/editor_decorations_test.nim",
    # #566 (M4) — a live tracepoint results grid is refreshed in place, never
    # rebuilt.  Rebuilding wiped the `<table>` the DataTables instance holds a
    # reference to, on every completed move, including the jump the grid's own
    # row click emits.
    "src/tests/gui/tests/editor/trace_redraw_policy_test.nim",
    # #568 (M19) — the recent-traces list was fetched only in the
    # welcome-screen branch of `index/startup.nim`, so a process started with
    # `ct run <program>` reached the tab bar's "+" with an empty cache and the
    # new tab's Recent Traces panel stayed blank.  The test asserts the
    # delivery contract exhaustively over every startup path, so a new path
    # cannot be added without deciding how it gets its lists.
    "src/tests/gui/tests/welcome-screen/recent_items_startup_vm_test.nim",
    # RV-1 (Review-Command.milestones.org) — `ct review` is DeepReview's whole
    # command-line surface, and the two older spellings are retired outright.
    # Registered here because this array IS the gate: the dispatch it asserts
    # is pure argv handling in `src/ct/review_cli.nim`, which no Playwright
    # suite can reach (they exercise the *launch*, and only its success path),
    # and an unregistered ViewModel test runs nowhere.  It carries a
    # native-only source-contract suite for the same reason
    # `deepreview_layout_test.nim` and `deepreview_entry_test.nim` do: the
    # wiring lives in confutils declarations and a pre-parser interception
    # that only exist in a linked `ct`, so reading the sources is the only
    # headless way to assert the retired option is really gone rather than
    # merely unused.
    #
    # RV-3 added the routing layer to the same file: `collect` inspects the
    # recordings it was given and chooses the collector that can read them
    # (DeepReview-GUI.md §1.1, "a collector is chosen by inspecting the
    # recording, never by the user naming a backend").  It belongs here for
    # the same reason the dispatch does — the rules and the route are pure
    # functions no Playwright suite can reach — and it guards a failure that
    # was silent rather than loud: `ct review collect` over a directory of
    # Python recordings used to print "Review dataset ready" and exit 0 over
    # a dataset with nothing in it.
    "src/tests/gui/tests/deepreview/ct_review_cli_test.nim",
    # RV-6 — a review loads the agent session that produced it.
    # DeepReview-GUI.md §2.1: "The primary thing the panel shows in a review
    # is the agent session that produced it."  Three of the milestone's five
    # verification entries live here (the other two are `nim-acp`'s
    # `session/load` and `nim-agents`' `loadSession`, in those repositories'
    # own suites): a dataset with no reference reviews normally, an
    # unresolvable reference renders an explicit state, and a resolvable one
    # renders the session's messages.
    #
    # It belongs in this array rather than in the Playwright lane because the
    # decision it guards is a *projection* — three different empty message
    # lists that must not read alike — and the failure it prevents is silent:
    # a pruned session rendering as a blank panel says "the agent did
    # nothing", which §2.1 names a defect.  The collect-side half (what the
    # agent's environment means, and what stamping a reference does) is pure
    # for the same reason `ct review`'s dispatch is, and is asserted here too.
    "src/tests/gui/tests/deepreview/review_session_vm_test.nim",
    # RV-4 — the materialized-trace collector, at the end the GUI reads.
    # DeepReview-GUI.md §1.1: "DeepReview is not an rr-only feature. Every
    # language that produces a materialized trace ... must be reviewable."
    # RV-3 named the second collector and refused; RV-4 implements it in the
    # db-backend, and this suite is the claim that its output is a dataset the
    # GUI reader accepts: both collectors' datasets go through ONE decode
    # (`deepreview/lib/review_dataset_json.nim`, the renderer's
    # `cast[DeepReviewData](JSON.parse(...))` written out) and ONE production
    # projection (`review_entry`), and both must arrive at a usable review.
    # The fixture is real collector output over a real Noir recording
    # (`fixtures/regenerate-materialized-review.sh`), so the coverage and flow
    # numbers it asserts are the recording's, not a shape someone invented.
    #
    # Registered here because this array IS the gate and nothing else reaches
    # it: the Rust side asserts the collector's own numbers
    # (`src/db-backend/tests/deepreview_materialized_collector_test.rs`) but
    # cannot see the reader, and the Playwright suites launch a review without
    # asserting what is in the dataset.
    "src/tests/gui/tests/deepreview/materialized_review_dataset_test.nim",
    # RV-5 — the flow overlay, from the dataset (superseding DR-R6).  Two
    # subjects, one milestone:
    #
    #   1. `flowStyleLines` indexed `branchesTaken[0][0]` with no bounds or nil
    #      check, so an empty seq was an `IndexDefect` that aborted
    #      `applyEventualStylesLines` before a single decoration was applied —
    #      a latent crash with nothing to do with DeepReview, which is why it
    #      is tested on its own terms in `editor/flow_line_styles_test.nim`
    #      over hand-built `FlowViewUpdate` values rather than through a
    #      review.
    #   2. The adapter that turns a review dataset's per-invocation flow into
    #      the per-view `FlowUpdate` the editor's `ct/updated-flow`
    #      subscription already consumes.  DeepReview-GUI.md §7: "the adapter,
    #      not the replay backend, is the thing standing between a dataset and
    #      a flow overlay".
    #
    # Registered here because the adapter is where every judgement is made —
    # the synthesised `Location`, the well-formed empty `branchesTaken`, the
    # derived step counts, the loop mapping and the value synthesis — and none
    # of it is observable from Playwright, which can see only the classes that
    # came out the far end.
    "src/tests/gui/tests/editor/flow_line_styles_test.nim",
    "src/tests/gui/tests/deepreview/deepreview_flow_adapter_test.nim",
    # RV-5's other half: the mapping of a source line onto the diff tab's
    # synthetic document (§4.4's "restrict rendering to lines currently loaded
    # into the diff tab", which is a property of that mapping), the **inline
    # values** §4.4 requires alongside it, and the two in-editor controls that
    # decide which execution those values describe — the invocation selector
    # (§7's "Monaco view zone anchored immediately above the relevant lines",
    # whose anchor is arithmetic and so assertable headlessly) and the loop
    # iteration control.
    #
    # The value cases assert the fixture's own values **by content**, which is
    # what the Playwright suite can also do but the ViewModel layer must:
    # a strip of the wrong invocation's — or the wrong loop pass's — values has
    # exactly the same count as the right one's, so a count-only assertion
    # cannot tell them apart.  RV-5's first version rendered no values at all
    # and its e2e coverage did not notice.
    #
    # It also carries RV-4's gap 8: a function the changeset only *calls* has a
    # `callCount` and no flow, and the control must say so rather than offer an
    # invocation it cannot render.
    "src/tests/gui/tests/deepreview/review_flow_overlay_test.nim",
    # RV-7 — the agent handoff is two ordinary commands.
    # Agentic-Coding-Integration.md §4.4: "`ct agent evidence` takes the
    # dataset path and nothing else in the common case.  The session it
    # belongs to, the task, and the workspace are read from the environment
    # variables the agent already runs under."
    #
    # Three of the milestone's four verification entries have their pure half
    # here — the environment is resolved, explicit flags override it, and a
    # missing environment produces an error rather than an invented id — plus
    # the flag shrink itself: every one of the nine retired flags is refused
    # with a diagnostic naming its replacement, and every field they used to
    # assert is shown being read out of a real collector's dataset instead.
    #
    # It belongs in this array rather than in a CLI lane because all of it is
    # a *decision* — what an environment means, what a dataset says, what a
    # hook would run — and the failure it prevents is silent by construction:
    # an id invented here attaches a review to the wrong conversation and
    # nothing downstream can tell.  The shipped binary's half, and the fourth
    # entry (the hook really produces a loadable dataset), are
    # `src/tests/cli/agent_cli_test.nim`.
    "src/tests/gui/tests/deepreview/agent_evidence_vm_test.nim",
  ]

  CliRecordGateTests* = [
    # The `ct record` CLI dispatch lane.  Same contract as
    # `CoreViewModelGateTests` above — this array is the registry that says
    # these files must exist and must not be skip-disabled — but a DIFFERENT
    # runner: they are not ViewModel tests, so `just test-vm-native`'s
    # `find src/tests/gui/tests` glob does not reach them.  `just
    # test-cli-record` is what compiles and runs them.
    #
    # They exist because language detection and recorder dispatch were two
    # unconnected tables: `common/lang.nim` mapped `.php` → LangPhp, `.ex`/
    # `.exs` → LangElixir and `.erl` → LangErlang and marked all three
    # `usesMaterializedTraces`, while the dispatch chain in
    # `src/ct/db_backend_record.nim` had an arm for none of them — so
    # `ct record app.php` printed "ERROR: unsupported trace kind db" and
    # exited **0**.  The same chain spawned several recorders without
    # checking the PATH lookup had succeeded, so a missing recorder produced
    # a registered trace for a recording that never ran.
    #
    # The pure table test asserts the selection and the argv for every
    # materialized-trace language, including the invariant that closes the
    # gap (a language that claims `usesMaterializedTraces` must have a
    # dispatch arm).  Because a wrong-but-consistent table would pass that,
    # the other two run the SHIPPED `ct` binary: one with the recorders
    # removed from its environment, asserting the failure is non-zero and
    # names both the language and the remedy; one against the real recorder
    # siblings, asserting a real CTFS container comes out.
    "src/tests/cli/record_dispatch_test.nim",
    "src/tests/cli/record_missing_recorder_test.nim",
    "src/tests/cli/record_dispatch_e2e_test.nim",
  ]

  CliReviewGateTests* = [
    # RV-1: the `ct review` CLI lane.  Same contract and the same runner as
    # `CliRecordGateTests` above — `just test-cli-record` globs the whole of
    # `src/tests/cli`, so this file is compiled and run by it — but a
    # different subject, kept in its own array so the record lane's rationale
    # is not diluted.
    #
    # It exists because the two halves of RV-1 fail in different places.  The
    # dispatch is pure and is gated in `CoreViewModelGateTests`; whether the
    # SHIPPED binary is wired to it is not, and cannot be: the wiring is a
    # confutils declaration plus an interception that runs before confutils,
    # neither of which exists outside a linked `ct`.  Against the pre-RV-1
    # binary every case in this file fails — `ct review …` answered "ct has
    # no such subcommand" and the retired global option was still accepted —
    # which is exactly the gap it now guards.
    #
    # RV-3 added the routing cases, which are here rather than only in the
    # ViewModel lane because the property they assert is an ORDER inside the
    # linked executor — the recordings are surveyed before any backend is
    # looked up — and because the recordings they route on are real
    # directories with real marker files.  Six of the seven failed against
    # the pre-RV-3 binary by producing "Review dataset ready" and exit 0;
    # the seventh pins the native route, which must survive the seam
    # unchanged.
    "src/tests/cli/review_cli_test.nim",
  ]

  CliAgentGateTests* = [
    # RV-7: the `ct agent` CLI lane.  Same contract and the same runner as
    # `CliReviewGateTests` above — `just test-cli-record` globs the whole of
    # `src/tests/cli` — kept in its own array because its subject is the
    # agent handoff rather than the review command group.
    #
    # Two things live here that no ViewModel test can reach.  The first is the
    # wiring: `ct agent …` is intercepted before confutils parses argv, and
    # against the pre-RV-7 binary `ct agent --help` was answered by the
    # evidence command with a notification rather than a usage screen.  The
    # second is the milestone's fourth verification entry, which is not an
    # assertion about argv at all: the end-of-turn hook is run for real, over
    # a real git repository and a real Noir recording, through the real
    # `replay-server` collector, and the `review.json` it produces is then
    # OPENED and read.  A hook that reports success over a file nothing can
    # load is precisely the failure that entry exists to catch.
    "src/tests/cli/agent_cli_test.nim",
  ]

  GuiActionGateEntries*: array[5, GuiActionGateEntry] = [
    GuiActionGateEntry(
      action: "ct.test.run",
      visibleSurface: "editor gutter / above-line ct-test control",
      mockCoverage: EditorControlsVmTest,
      nonMockCoverage: "src/ct_test/contracts_test.nim",
      unsupportedDiagnostic: ""),
    GuiActionGateEntry(
      action: "ct.test.record",
      visibleSurface: "editor gutter / above-line ct-test control",
      mockCoverage: EditorControlsVmTest,
      nonMockCoverage:
        "src/tests/gui/tests/welcome-screen/launch_config.spec.ts",
      unsupportedDiagnostic: ""),
    GuiActionGateEntry(
      action: "ct.test.openLastTrace",
      visibleSurface: "editor gutter / above-line ct-test control",
      mockCoverage: EditorControlsVmTest,
      nonMockCoverage: "src/tests/gui/tests/cross-platform-replay.spec.ts",
      unsupportedDiagnostic: ""),
    GuiActionGateEntry(
      action: "record unsupported provider diagnostic",
      visibleSurface: "hidden record action for run-only providers",
      mockCoverage: "src/ct_test/playwright_provider_test.nim",
      nonMockCoverage: "",
      unsupportedDiagnostic: UnsupportedRecordDiagnostic),
    GuiActionGateEntry(
      action: "mock language smoke alternatives",
      visibleSurface: "Mock-driven per-language smoke ViewModel tests",
      mockCoverage: LanguageSmokeMockTest,
      nonMockCoverage: LanguageSmokeTest,
      unsupportedDiagnostic: ""),
  ]

const ProviderGateEntries*: array[38, ProviderGateEntry] = [
  ProviderGateEntry(providerId: "ada-fallback",
    fixturePath: "src/ct_test/fixtures/m12_ada_project",
    researchDoc: "src/ct_test/framework_research/ada-aunit-fallback.md",
    providerTest: "src/ct_test/m12_fallback_languages_test.nim",
    sourceFiles: @["src/ct_test/frameworks/ada_fallback.nim",
      "src/ct_test/frameworks/m12_fallback_common.nim"]),
  ProviderGateEntry(providerId: "assembly-fallback",
    fixturePath: "src/ct_test/fixtures/m12_assembly_project",
    researchDoc:
      "src/ct_test/framework_research/assembly-executable-fallback.md",
    providerTest: "src/ct_test/m12_fallback_languages_test.nim",
    sourceFiles: @["src/ct_test/frameworks/assembly_fallback.nim",
      "src/ct_test/frameworks/m12_fallback_common.nim"]),
  ProviderGateEntry(providerId: "cpp-catch2",
    fixturePath: "src/ct_test/fixtures/cpp_catch2_project",
    researchDoc: "src/ct_test/framework_research/cpp-catch2.md",
    providerTest: "src/ct_test/cpp_providers_test.nim",
    sourceFiles: @["src/ct_test/frameworks/cpp_catch2.nim",
      "src/ct_test/frameworks/cpp_common.nim"]),
  ProviderGateEntry(providerId: "cpp-ctest",
    fixturePath: "src/ct_test/fixtures/cpp_ctest_fallback_project",
    researchDoc: "src/ct_test/framework_research/cpp-ctest.md",
    providerTest: "src/ct_test/cpp_providers_test.nim",
    sourceFiles: @["src/ct_test/frameworks/cpp_ctest.nim",
      "src/ct_test/frameworks/cpp_common.nim"]),
  ProviderGateEntry(providerId: "cpp-gtest",
    fixturePath: "src/ct_test/fixtures/cpp_gtest_project",
    researchDoc: "src/ct_test/framework_research/cpp-googletest.md",
    providerTest: "src/ct_test/cpp_providers_test.nim",
    sourceFiles: @["src/ct_test/frameworks/cpp_gtest.nim",
      "src/ct_test/frameworks/cpp_common.nim"]),
  ProviderGateEntry(providerId: "crystal-spec",
    fixturePath: "src/ct_test/fixtures/crystal_spec_project",
    researchDoc: "src/ct_test/framework_research/crystal-spec.md",
    providerTest: "src/ct_test/m11_native_languages_test.nim",
    sourceFiles: @["src/ct_test/frameworks/crystal_spec.nim",
      "src/ct_test/frameworks/native_m11_common.nim"]),
  ProviderGateEntry(providerId: "d-unittest",
    fixturePath: "src/ct_test/fixtures/d_unittest_project",
    researchDoc: "src/ct_test/framework_research/d-unittest-dub.md",
    providerTest: "src/ct_test/m11_native_languages_test.nim",
    sourceFiles: @["src/ct_test/frameworks/d_unittest.nim",
      "src/ct_test/frameworks/native_m11_common.nim"]),
  ProviderGateEntry(providerId: "fortran-fallback",
    fixturePath: "src/ct_test/fixtures/m12_fortran_project",
    researchDoc: "src/ct_test/framework_research/fortran-pfunit-fallback.md",
    providerTest: "src/ct_test/m12_fallback_languages_test.nim",
    sourceFiles: @["src/ct_test/frameworks/fortran_fallback.nim",
      "src/ct_test/frameworks/m12_fallback_common.nim"]),
  ProviderGateEntry(providerId: "go-test",
    fixturePath: "src/ct_test/fixtures/go_test_project",
    researchDoc: "src/ct_test/framework_research/go-test.md",
    providerTest: "src/ct_test/m11_native_languages_test.nim",
    sourceFiles: @["src/ct_test/frameworks/go_test.nim",
      "src/ct_test/frameworks/native_m11_common.nim"]),
  ProviderGateEntry(providerId: "js-jest",
    fixturePath: "src/ct_test/fixtures/js_jest_project",
    researchDoc: "src/ct_test/framework_research/js-jest.md",
    providerTest: "src/ct_test/js_providers_test.nim",
    sourceFiles: @["src/ct_test/frameworks/js_jest.nim",
      "src/ct_test/frameworks/js_common.nim"]),
  ProviderGateEntry(providerId: "js-node-test",
    fixturePath: "src/ct_test/fixtures/js_node_test_project",
    researchDoc: "src/ct_test/framework_research/js-node-test.md",
    providerTest: "src/ct_test/js_providers_test.nim",
    sourceFiles: @["src/ct_test/frameworks/js_node_test.nim",
      "src/ct_test/frameworks/js_common.nim"]),
  ProviderGateEntry(providerId: "js-playwright",
    fixturePath: "src/ct_test/fixtures/js_playwright_project",
    researchDoc: "src/ct_test/framework_research/js-playwright.md",
    providerTest: "src/ct_test/playwright_provider_test.nim",
    sourceFiles: @["src/ct_test/frameworks/js_playwright.nim",
      "src/ct_test/frameworks/js_common.nim"]),
  ProviderGateEntry(providerId: "js-vitest",
    fixturePath: "src/ct_test/fixtures/js_vitest_project",
    researchDoc: "src/ct_test/framework_research/js-vitest.md",
    providerTest: "src/ct_test/js_providers_test.nim",
    sourceFiles: @["src/ct_test/frameworks/js_vitest.nim",
      "src/ct_test/frameworks/js_common.nim"]),
  ProviderGateEntry(providerId: "julia-fallback",
    fixturePath: "src/ct_test/fixtures/m12_julia_project",
    researchDoc: "src/ct_test/framework_research/julia-test-fallback.md",
    providerTest: "src/ct_test/m12_fallback_languages_test.nim",
    sourceFiles: @["src/ct_test/frameworks/julia_fallback.nim",
      "src/ct_test/frameworks/m12_fallback_common.nim"]),
  ProviderGateEntry(providerId: "lean-fallback",
    fixturePath: "src/ct_test/fixtures/m12_lean_project",
    researchDoc: "src/ct_test/framework_research/lean-fixture-fallback.md",
    providerTest: "src/ct_test/m12_fallback_languages_test.nim",
    sourceFiles: @["src/ct_test/frameworks/lean_fallback.nim",
      "src/ct_test/frameworks/m12_fallback_common.nim"]),
  ProviderGateEntry(providerId: "nim-unittest",
    fixturePath: "src/ct_test/fixtures/nim_unittest_project",
    researchDoc: "src/ct_test/framework_research/nim-unittest.md",
    providerTest: "src/ct_test/nim_unittest_provider_test.nim",
    sourceFiles: @["src/ct_test/frameworks/nim_unittest.nim",
      "src/ct_test/nim_lexer.nim"]),
  ProviderGateEntry(providerId: "odin-fallback",
    fixturePath: "src/ct_test/fixtures/m12_odin_project",
    researchDoc: "src/ct_test/framework_research/odin-fixture-fallback.md",
    providerTest: "src/ct_test/m12_fallback_languages_test.nim",
    sourceFiles: @["src/ct_test/frameworks/odin_fallback.nim",
      "src/ct_test/frameworks/m12_fallback_common.nim"]),
  ProviderGateEntry(providerId: "pascal-fallback",
    fixturePath: "src/ct_test/fixtures/m12_pascal_project",
    researchDoc: "src/ct_test/framework_research/pascal-fpcunit-fallback.md",
    providerTest: "src/ct_test/m12_fallback_languages_test.nim",
    sourceFiles: @["src/ct_test/frameworks/pascal_fallback.nim",
      "src/ct_test/frameworks/m12_fallback_common.nim"]),
  ProviderGateEntry(providerId: "python-pytest",
    fixturePath: "src/ct_test/fixtures/python_pytest_project",
    researchDoc: "src/ct_test/framework_research/python-pytest.md",
    providerTest: "src/ct_test/python_providers_test.nim",
    sourceFiles: @["src/ct_test/frameworks/python_pytest.nim",
      "src/ct_test/frameworks/python_common.nim"]),
  ProviderGateEntry(providerId: "python-unittest",
    fixturePath: "src/ct_test/fixtures/python_unittest_project",
    researchDoc: "src/ct_test/framework_research/python-unittest.md",
    providerTest: "src/ct_test/python_providers_test.nim",
    sourceFiles: @["src/ct_test/frameworks/python_unittest.nim",
      "src/ct_test/frameworks/python_common.nim"]),
  ProviderGateEntry(providerId: "ruby-minitest",
    fixturePath: "src/ct_test/fixtures/ruby_minitest_project",
    researchDoc: "src/ct_test/framework_research/ruby-minitest.md",
    providerTest: "src/ct_test/ruby_providers_test.nim",
    sourceFiles: @["src/ct_test/frameworks/ruby_minitest.nim",
      "src/ct_test/frameworks/ruby_common.nim"]),
  ProviderGateEntry(providerId: "ruby-rspec",
    fixturePath: "src/ct_test/fixtures/ruby_rspec_project",
    researchDoc: "src/ct_test/framework_research/ruby-rspec.md",
    providerTest: "src/ct_test/ruby_providers_test.nim",
    sourceFiles: @["src/ct_test/frameworks/ruby_rspec.nim",
      "src/ct_test/frameworks/ruby_common.nim"]),
  ProviderGateEntry(providerId: "rust-libtest",
    fixturePath: "src/ct_test/fixtures/rust_libtest_project",
    researchDoc: "src/ct_test/framework_research/rust-libtest.md",
    providerTest: "src/ct_test/rust_libtest_provider_test.nim",
    sourceFiles: @["src/ct_test/frameworks/rust_libtest.nim"]),
  ProviderGateEntry(providerId: "v-fallback",
    fixturePath: "src/ct_test/fixtures/m12_v_project",
    researchDoc: "src/ct_test/framework_research/v-fixture-fallback.md",
    providerTest: "src/ct_test/m12_fallback_languages_test.nim",
    sourceFiles: @["src/ct_test/frameworks/v_fallback.nim",
      "src/ct_test/frameworks/m12_fallback_common.nim"]),
  ProviderGateEntry(providerId: "smart-cairo",
    fixturePath: "src/ct_test/fixtures/m13_smart_contract_project",
    researchDoc: SmartHarnessResearchDoc,
    providerTest: SmartHarnessProviderTest,
    sourceFiles: SmartHarnessSourceFiles, heavy: true),
  ProviderGateEntry(providerId: "smart-cardano",
    fixturePath: "src/ct_test/fixtures/m13_smart_contract_project",
    researchDoc: SmartHarnessResearchDoc,
    providerTest: SmartHarnessProviderTest,
    sourceFiles: SmartHarnessSourceFiles, heavy: true),
  ProviderGateEntry(providerId: "smart-circom",
    fixturePath: "src/ct_test/fixtures/m13_smart_contract_project",
    researchDoc: SmartHarnessResearchDoc,
    providerTest: SmartHarnessProviderTest,
    sourceFiles: SmartHarnessSourceFiles, heavy: true),
  ProviderGateEntry(providerId: "smart-evm",
    fixturePath: "src/ct_test/fixtures/m13_smart_contract_project",
    researchDoc: SmartHarnessResearchDoc,
    providerTest: SmartHarnessProviderTest,
    sourceFiles: SmartHarnessSourceFiles, heavy: true),
  ProviderGateEntry(providerId: "smart-flow",
    fixturePath: "src/ct_test/fixtures/m13_smart_contract_project",
    researchDoc: SmartHarnessResearchDoc,
    providerTest: SmartHarnessProviderTest,
    sourceFiles: SmartHarnessSourceFiles, heavy: true),
  ProviderGateEntry(providerId: "smart-fuel",
    fixturePath: "src/ct_test/fixtures/m13_smart_contract_project",
    researchDoc: SmartHarnessResearchDoc,
    providerTest: SmartHarnessProviderTest,
    sourceFiles: SmartHarnessSourceFiles, heavy: true),
  ProviderGateEntry(providerId: "smart-leo",
    fixturePath: "src/ct_test/fixtures/m13_smart_contract_project",
    researchDoc: SmartHarnessResearchDoc,
    providerTest: SmartHarnessProviderTest,
    sourceFiles: SmartHarnessSourceFiles, heavy: true),
  ProviderGateEntry(providerId: "smart-miden",
    fixturePath: "src/ct_test/fixtures/m13_smart_contract_project",
    researchDoc: SmartHarnessResearchDoc,
    providerTest: SmartHarnessProviderTest,
    sourceFiles: SmartHarnessSourceFiles, heavy: true),
  ProviderGateEntry(providerId: "smart-move",
    fixturePath: "src/ct_test/fixtures/m13_smart_contract_project",
    researchDoc: SmartHarnessResearchDoc,
    providerTest: SmartHarnessProviderTest,
    sourceFiles: SmartHarnessSourceFiles, heavy: true),
  ProviderGateEntry(providerId: "smart-polkavm",
    fixturePath: "src/ct_test/fixtures/m13_smart_contract_project",
    researchDoc: SmartHarnessResearchDoc,
    providerTest: SmartHarnessProviderTest,
    sourceFiles: SmartHarnessSourceFiles, heavy: true),
  ProviderGateEntry(providerId: "smart-solana",
    fixturePath: "src/ct_test/fixtures/m13_smart_contract_project",
    researchDoc: SmartHarnessResearchDoc,
    providerTest: SmartHarnessProviderTest,
    sourceFiles: SmartHarnessSourceFiles, heavy: true),
  ProviderGateEntry(providerId: "smart-ton",
    fixturePath: "src/ct_test/fixtures/m13_smart_contract_project",
    researchDoc: SmartHarnessResearchDoc,
    providerTest: SmartHarnessProviderTest,
    sourceFiles: SmartHarnessSourceFiles, heavy: true),
  ProviderGateEntry(providerId: "smart-wasm",
    fixturePath: "src/ct_test/fixtures/m13_smart_contract_project",
    researchDoc: SmartHarnessResearchDoc,
    providerTest: SmartHarnessProviderTest,
    sourceFiles: SmartHarnessSourceFiles, heavy: true),
  ProviderGateEntry(providerId: "smart-wasmi",
    fixturePath: "src/ct_test/fixtures/m13_smart_contract_project",
    researchDoc: SmartHarnessResearchDoc,
    providerTest: SmartHarnessProviderTest,
    sourceFiles: SmartHarnessSourceFiles, heavy: true),
]

proc yesNo(value: bool): string =
  if value: "yes" else: "no"

proc claimsRecord*(capabilities: TestCapabilities): bool =
  capabilities.canRecordProject or capabilities.canRecordFile or
    capabilities.canRecordSingle

proc capabilityNames*(capabilities: TestCapabilities): seq[string] =
  if capabilities.canDiscoverProject: result.add "discover-project"
  if capabilities.canDiscoverFile: result.add "discover-file"
  if capabilities.canLocateTests: result.add "locate-tests"
  if capabilities.canRunProject: result.add "run-project"
  if capabilities.canRunFile: result.add "run-file"
  if capabilities.canRunSingle: result.add "run-single"
  if capabilities.canRecordProject: result.add "record-project"
  if capabilities.canRecordFile: result.add "record-file"
  if capabilities.canRecordSingle: result.add "record-single"
  if capabilities.canCapturePerTestOutput: result.add "per-test-output"
  if capabilities.canMapTraceEntryPoints: result.add "trace-entry-map"
  if capabilities.emitsStructuredEvents: result.add "structured-events"

proc matrixCapabilities(info: TestProviderInfo; entry: ProviderGateEntry):
    string =
  if entry.heavy:
    return "discover-project, discover-file, locate-tests, " &
      "conditional run-file, conditional record-file, " &
      "conditional trace-entry-map"
  capabilityNames(info.capabilities).join(", ")

proc matrixRecord(info: TestProviderInfo; entry: ProviderGateEntry): string =
  if entry.heavy: "conditional" else: yesNo(info.capabilities.claimsRecord)

proc matrixTraceMap(info: TestProviderInfo; entry: ProviderGateEntry): string =
  if entry.heavy: "conditional" else: yesNo(
    info.capabilities.canMapTraceEntryPoints)

proc gateEntryByProvider*(): Table[string, ProviderGateEntry] =
  for entry in ProviderGateEntries:
    result[entry.providerId] = entry

proc providerInfoSorted*(registry: ProviderRegistry): seq[TestProviderInfo] =
  result = registry.providers.mapIt(it.provider.info)
  result.sort proc(a, b: TestProviderInfo): int =
    cmp(a.id, b.id)

proc supportMatrixMarkdown*(registry: ProviderRegistry): string =
  let entries = gateEntryByProvider()
  var lines = @[
    "# ct-test Provider Support Matrix",
    "",
    "Generated from `newDefaultProviderRegistry()` and " &
      "`src/ct_test/release_gate.nim`.",
    "Regenerate/check with `just test-m16-release-gate`.",
    "",
    "| Provider | Language | Framework | Capabilities | Record | " &
      "Trace map | Fixture | Gate test | Heavy |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
  ]
  for info in providerInfoSorted(registry):
    let entry = entries[info.id]
    lines.add "| `" & info.id & "` | " & info.language & " | " &
      info.framework & " | " & matrixCapabilities(info, entry) &
      " | " & matrixRecord(info, entry) & " | " &
      matrixTraceMap(info, entry) & " | `" &
      entry.fixturePath & "` | `" & entry.providerTest & "` | " &
      yesNo(entry.heavy) & " |"
  lines.join("\n")

proc fileContains*(path, needle: string): bool =
  fileExists(path) and readFile(path).contains(needle)
