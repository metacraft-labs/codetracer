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
    # BlockTracer M2b's two named verification tests
    # (BlockTracer.milestones.org, "The Five Panes BlockTracer Renders").
    # The `vm-unit` lane already RUNS them — it discovers
    # `src/frontend/viewmodel/tests/unit/test_*.nim` by glob — so this
    # registration is not about reaching them.  It is about the other half of
    # what this array asserts: that the file still exists and has not been
    # skip-disabled.  A milestone's verification test is exactly the file a
    # later change is tempted to delete or `skip()` when it goes red, and glob
    # discovery is silent about both.
    "src/frontend/viewmodel/tests/unit/test_five_panes_drive_headlessly.nim",
    "src/frontend/viewmodel/tests/unit/test_cross_pane_composition_needs_no_bridge.nim",
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
    #
    # UD-1 replaced the single synthetic model with Monaco's own diff editor
    # over two of them, and this file is where that is pinned as data: which
    # side each line belongs to (an addition is not in the old revision and a
    # removal is not in the new one), that the chrome is byte-identical on both
    # so the comparison is anchored, that the models carry the file's own text
    # rather than the marker a review's collector attaches, that the language
    # is resolved from the path, and that an added file, a deleted file and a
    # file with no source text each keep a sensible shape — the three the old
    # interleaved document flattened into one run of coloured lines.  What
    # Monaco then DOES with the two models (a tokenizer running, the word-level
    # intra-line marking appearing) is a DOM fact and is asserted in
    # `deepreview-gui.spec.ts`, because it cannot be observed here.
    "src/tests/gui/tests/vcs/vcs_diff_decorations_test.nim",
    # DR-R5 / UD-2 — context expansion in the diff tab.  Until DR-R5 the whole
    # capability was private procs inside `ui/deepreview.nim`, a JS-only
    # module with no importable entry point, so the boundary arithmetic that
    # decides how many lines exist above a hunk near the top of a file — the
    # arithmetic that produces blank lines numbered 0 and -1 when it is wrong
    # — was asserted by nothing.
    #
    # UD-2 changed what that arithmetic IS.  The diff tab's models are the
    # whole file now, because a Monaco model is tokenized from its own line 1
    # and a window starting at the first hunk tokenized the rest of a file
    # from mid-docstring; which of those lines a reader sees is decided by
    # Monaco's `hideUnchangedRegions`.  So this file asserts the whole-file
    # document (every line of the new revision, the old side reconstructed
    # from the hunks, the `@@` divider kept and the file header moved out),
    # the collapse `collapsedRegionsFor` predicts — including a run at each
    # edge of the file and two hunks too close together to collapse between,
    # which is where the off-by-ones live — the offers the boundary's context
    # menu makes, and the fetch-once-per-(revision,path) cache the whole-file
    # model is built from.
    #
    # `vcs_vm_test.nim` (already listed above) carries the two properties of
    # the removed per-hunk counters that outlive them: a re-sync of the same
    # rows must rebuild a byte-identical document, or the host replaces the
    # models and every region a reader expanded collapses again; and a cleared
    # panel must produce no document at all.
    "src/tests/gui/tests/vcs/vcs_context_expansion_test.nim",
    # AA-1 — the DeepReview roll-up is deleted from the Agent Activity panel,
    # and its layout identity is not.
    #
    # This replaces `agent_activity_deepreview_vm_test.nim`, which tested the
    # roll-up's ViewModel: DR-R3 wired that ViewModel to a real review, and
    # AA-1 removed the whole surface (DeepReview-GUI.md §2.1: "There is no
    # 'DeepReview section' in this panel").  The file's behavioural claims that
    # outlive the pane moved to the surfaces that still make them — per-file
    # coverage to the VCS panel's Changed Files badge, the aggregate to
    # `ReviewDataset`, and "this dataset carries no test results" to the
    # dataset level — and each is listed in this gate through
    # `materialized_review_dataset_test.nim` and `deepreview_entry_test.nim`.
    #
    # What is left needs its own file for the reason DR-R8 gave: the two
    # DeepReview ids have nearly identical names, and a deletion guard has to
    # say which one went.  Here the answer is the *opposite* of DR-R8's —
    # `Content.AgentActivityDeepReview` (39) SURVIVES, because persisted
    # layouts store the ordinal, review mode keeps the pane visible by it, and
    # AA-2/AA-3 render into it — so the guard asserts presence and absence in
    # the same file, where they cannot drift apart.
    #
    # The rendering half rides in `isonim_views_test.nim` (already listed
    # above): the panel that used to host the roll-up is where "no roll-up"
    # has to be observed.
    "src/tests/gui/tests/agent-activity-deepreview/agent_activity_rollup_removal_test.nim",
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
    # RV-11 — Full Files mode, which had never drawn a decoration.
    #
    # Both §5 overlays asked "is this editor tab the dataset's file?" as
    # `file.path == self.path`, with the dataset's repo-relative `src/main.nr`
    # on the left and the tab's path on the right.  Measured over the book's
    # own worked example, opening the full file contributed exactly zero: 0
    # `line-diff-added`, 0 `line-diff-modified`, and the diff tab's 8 flow
    # lines and 36 value chips unchanged.
    #
    # The rule now lives in `common/review_source_paths` because THREE places
    # ask it — §5.1's diff highlights, §5.3's flow overlay, and the index
    # process that serves the tab's text — and three spellings of it would be
    # three chances to disagree.  It is registered here rather than left to
    # the Playwright suite because the interesting cases are the ones a
    # browser cannot reach: the component-boundary rule that stops `main.nr`
    # claiming `/repo/src/domain.nr` (a wrong answer that renders as a
    # perfectly plausible right one), the longest-match rule that keeps the
    # answer independent of dataset ordering, and the Windows path forms.
    "src/tests/gui/tests/deepreview/review_source_paths_test.nim",
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
    # AA-2 — a `ct test` run renders in the Agent Activity session feed as a
    # summary that drills down to the recording of an individual test
    # (DeepReview-GUI.md §2.1.2).
    #
    # The projection: the runner's own NDJSON folded into a run summary,
    # asserted against bytes produced by `ct_test/contracts`' serializer plus
    # one literal wire line, so the wire format cannot drift past it.  Two of
    # its suites exist for rules that a rendering can quietly break and no
    # user-visible symptom announces: a test with no recording must offer no
    # drill-down *and* refuse to open one if asked anyway, and a recording
    # that failed before producing a trace must offer nothing at all — "a
    # broken trace tab is worse than none".
    "src/tests/gui/tests/agent-activity/test_run_summary_vm_test.nim",
    # AA-2 — the DOM the panel emits for that run.
    #
    # A separate file from `views/isonim_views_test.nim`, where the panel's
    # other view suites live, because at the time it was written that file did
    # not reach its own end: it died with SIGSEGV at
    # `isonim_views_test.nim(5388)`, downstream of the known-failing
    # "search results" cases, so every suite after that point — AA-1's own
    # roll-up deletion guard included — was dead.  Registering AA-2's
    # rendering assertions there would have made them unrunnable and silently
    # green.
    #
    # That crash is fixed: the mock-DOM lookups in that file now raise a
    # catchable `MockNodeNotFoundError` instead of returning a nil node for the
    # next line to dereference, so a missing element fails its own case and all
    # 461 run.  Merging this file back into `isonim_views_test.nim` is
    # therefore unblocked, and is a tidy-up rather than a correctness fix — it
    # is left as a separate file until someone does it deliberately.
    "src/tests/gui/tests/agent-activity/agent_activity_test_run_view_test.nim",
    # AA-2 — the Agent Workspace summary bar stops fabricating test results.
    #
    # AA-1 recorded this as a live violation of the rule it preserved when it
    # deleted the Tests card: `syncWorkspace` derived seven counters from
    # `vcs.deepReviewMode`, so the panel printed "1/1 passed" / "100.0%" with
    # review mode on and "0/0 passed" with it off, for a suite that never ran.
    # Listed here because the *positive* half — a real measurement still
    # renders — is what stops the fix being "print nothing, ever", and because
    # one of its cases asserts on the production source: a rendering test
    # alone cannot tell "the producer stopped fabricating" from "the renderer
    # now hides it", and both had to happen.
    "src/tests/gui/tests/agent-workspace/agent_workspace_no_fabricated_results_test.nim",
    # AA-3 — an evidence tool call in the session feed is a clickable entry
    # that loads the review dataset it produced (DeepReview-GUI.md §2.1.1).
    #
    # The projection: which tool calls count as evidence, and what became of
    # each.  Two of its rules are ones a rendering can quietly break with no
    # user-visible symptom announcing it, which is why they are pinned here
    # rather than left to the view: *prose* naming `ct review collect` must
    # never become a clickable review (an agent that says it will collect
    # evidence has collected none), and a command whose dataset cannot be
    # named must not be recognised at all rather than recognised with a
    # guessed path.  The suite also fixes the recogniser against the exact
    # command lines `docs/agent-prompt/deepreview-evidence.md` ships to
    # agents, so a change to the shipped prompt that the recogniser cannot
    # read breaks a test instead of silently emptying the panel.
    "src/tests/gui/tests/agent-activity/evidence_call_vm_test.nim",
    # AA-3 — the DOM the panel emits for that call.
    #
    # Registered separately from the projection because the two can fail
    # apart: the rule that decides whether a reviewer is offered a review is
    # applied twice, once by the view (whether to emit the affordance) and
    # once by the ViewModel (whether to act on it), and a suite that only
    # exercised one of them would let the other drift.  Its five
    # nothing-to-open cases each pair "no affordance" with "and here is the
    # sentence saying why" — AA-1's absence rule, which is only half kept by
    # a card that merely lacks a button.
    #
    # A separate file from `views/isonim_views_test.nim` for the reasons its
    # own header records: that file carries 17 pre-existing failures, so a
    # new suite in it would be one signal among eighteen, and the panel's
    # other rendering milestone already lives beside this one.
    "src/tests/gui/tests/agent-activity/agent_activity_evidence_view_test.nim",
    # AS-1 (Sharing/Artifact-Store.milestones.org) — the artifact model, its
    # closed kind registry, and the migration that keeps the trace upload and
    # the review-dataset upload one system rather than two.
    #
    # Registered here rather than left to the directory glob because two of
    # the three properties it pins are the kind that regress silently:
    #
    #   * the recording kind's URL space and identity are what already-issued
    #     share links and already-uploaded traces depend on, and nothing else
    #     in the ViewModel lane would notice them changing;
    #   * "an unknown kind is refused rather than stored opaquely" is the rule
    #     that stops the sharing service becoming a general file store, and a
    #     rule that is only a comment is a rule that is gone at the next
    #     convenient moment.
    #
    # Runs on BOTH backends — the model is deliberately free of filesystem,
    # HTTP, `Trace` and `langstring` so it can — so it is in `test-vm-native`
    # and `test-vm-js` alike.
    "src/tests/gui/tests/sharing/artifact_model_vm_test.nim",
    # AS-2 — store and retrieve any declared kind through ONE transfer.
    #
    # Registered for the same reason as the model suite above and one more:
    # this file is the only thing that pins the recording kind's *conversation*
    # with the service — which requests, with which bodies, in which order —
    # against literal pre-AS-2 strings.  Already-uploaded recordings are real
    # user data at real URLs, and the transfer is now generated from the kind
    # registry rather than spelled out, so a registry edit that silently
    # re-routed the recording kind would otherwise be caught by nothing until
    # a user's link stopped working.
    #
    # It also carries AS-2's four verification items (a recording round-trips,
    # a review dataset round-trips, large artifacts still transfer in slices,
    # metadata survives the round trip for each kind) in their headless form.
    # Their over-the-socket form is
    # `src/ct/online_sharing/artifact_store_roundtrip_test.nim`, which runs the
    # real HTTP client against a real server in `just test-mcr-enrichment-units`
    # — both are needed, because a correct plan that the executor does not
    # follow is a green suite and a broken upload.
    #
    # Runs on BOTH backends: the transfer *plan* is a pure function of the
    # artifact and the local file list, with no filesystem and no HTTP, which
    # is exactly why the planner and the executor are separate modules.
    "src/tests/gui/tests/sharing/artifact_transfer_vm_test.nim",
    # AS-3 — client-side encryption and password protection, once, for every
    # kind.
    #
    # Registered here because this file holds the *claims*.  Every sentence a
    # user reads about what encryption protects them from, what it does not,
    # what the service can still see, and what happens if they lose the
    # password comes out of `artifact_protection.nim`'s registry, and this
    # suite is what asserts those sentences say what they say — including that
    # the recovery answer is literally "Nothing." rather than a euphemism, and
    # that the payload-encrypting protection does NOT claim to encrypt the
    # metadata.
    #
    # It also holds AS-3's "the flow is identical across kinds" item in the
    # only form that can be checked exhaustively: the password prompt is a
    # function of `(protection, noun)`, and the suite asserts that substituting
    # the noun turns any kind's prompt into any other's, exactly.
    #
    # Runs on BOTH backends, and that is the point of splitting the pure claims
    # away from the native cryptography: a promise whose test needs a socket
    # and an OS CSPRNG is a promise that goes unchecked on most runs.  The
    # cryptography itself is asserted natively in
    # `src/ct/online_sharing/artifact_crypto_test.nim`, and end to end over a
    # real socket in `artifact_store_roundtrip_test.nim`; all three are needed.
    "src/tests/gui/tests/sharing/artifact_protection_vm_test.nim",
    # AS-4 — ONE sharing surface: sharing, access control, encryption and
    # password entry look and behave the same whatever you are sharing,
    # because they *are* the same.
    #
    # Registered here because this file holds the property that makes that
    # sentence true rather than aspirational.  `sharingView` is one builder and
    # per-kind variation can enter it through a closed, enumerated set of doors
    # (the noun, the kind's own facts, the command that opens it, §10.4's
    # visible-metadata list, and the notice a kind with frozen request bodies
    # owes); this suite demands that everything else is byte-identical over
    # kind × kind × protection × visibility × stage.  A SIXTH door added later
    # fails here, which is the only way "one flow" stays true after the people
    # who wrote it have moved on — before AS-4 there really were four separate
    # success blocks describing one operation.
    #
    # **The equality is asserted at three layers, and that is a correction.**
    # As AS-4 first shipped it, only the VIEW was compared; `renderSharingView`
    # — the function that produces what a user reads — was checked by substring
    # probes alone.  Independent verification put a door in the renderer, gated
    # on one kind and one stage, and every suite here stayed green while the
    # pre-AS-4 wording came back in the product.  The suite now compares the
    # view, the rendered text and the machine-readable JSON, and pins the
    # normaliser those comparisons remove the doors with.
    #
    # The guarantee's EDGE is stated rather than implied: it covers the sharing
    # view, not `upload.nim`'s narration about moving the bytes, which differs
    # per payload shape.  That narration is declared in an allowlist
    # `src/tests/cli/sharing_flow_cli_test.nim` enforces against a real upload
    # of each kind.
    #
    # It also carries the milestone's second and third verification items in
    # their headless form (a listing row makes each kind recognisable without
    # opening it; an access-control change reaches the view, the record and the
    # request body, and an unknown `--visibility` token is refused by name).
    # Their in-the-running-product form is
    # `src/tests/cli/sharing_flow_cli_test.nim`, which drives the shipped `ct`
    # binary against a stand-in service over a real socket — both are needed,
    # and AS-3 shipped two defects that only the second shape could catch.
    #
    # Runs on BOTH backends: the surface is pure — no filesystem, no HTTP, no
    # `std/times` — for the same reason `artifact_protection.nim` is.
    "src/tests/gui/tests/sharing/artifact_sharing_vm_test.nim",
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
    # NTR-2 (codetracer-specs/Planned-Features/Native-Target-Recognition.md).
    # The core's delegation to `ct-native-replay recognize` and the `--backend`
    # refusal.  Registered here for the same reason as the three above: the
    # delegation they replace was DEAD for its whole life — `debuginfo lang` is
    # a subcommand `ct-native-replay` has never had, so `clap` failed, stdout
    # was empty and `toLang("")` returned LangUnknown, which is
    # indistinguishable from a working recognizer that found nothing.  A test
    # reachable only by a glob has nothing asserting it still exists, and this
    # is precisely a lane where "it quietly stopped running" would reproduce
    # the original defect.
    "src/tests/cli/target_recognition_test.nim",
    "src/tests/cli/record_backend_selection_test.nim",
    "src/tests/cli/record_recognition_e2e_test.nim",
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

  CliLangContractGateTests* = [
    # The `Lang` ordinal contract and the domain types that succeed it.  Same
    # contract and the same runner as the three arrays above — `just
    # test-cli-record` globs the whole of `src/tests/cli` — kept in its own
    # array because its subject is neither the record dispatch lane nor a
    # command group, and folding it into `CliRecordGateTests` would dilute that
    # array's stated scope.  `CliReviewGateTests` set the precedent and says so
    # outright: a different subject gets its own array.
    #
    # These three exist because `Lang`'s ordinal is a WIRE AND STORAGE contract
    # held in three hand-maintained copies that no compiler compares:
    #
    #   * the Nim enum, `src/common/common_lang.nim`;
    #   * the canonical Rust enum, `libs/ct-lang/src/lib.rs`, which carries the
    #     ordinal across the `ct/load-locals` DAP hop via `serde_repr`;
    #   * the hand-written JS ordinal map in `src/frontend/trace_metadata.nim`.
    #
    # A copy that falls behind does not fail loudly — it decodes an integer as a
    # different language.  That has already happened here: `src/tui/src/lang.rs`
    # stopped at `Solana` (37 of 40) and `libs/ct-dap-client` diverged from
    # ordinal 6 onwards, both silently.  `lang_enum_contract_test` is what pins
    # the three copies together, and it fails rather than silently comparing
    # nothing if it cannot locate either list.
    #
    # `trace_index_migration_test` guards the other end of the same contract:
    # the `lang` column of the persisted `trace_index.db` holds ordinals written
    # by OLDER builds, decoded through the frozen `langV0OrdinalNames` snapshot
    # in `src/common/trace_index.nim` — a table whose header says "Never
    # regenerate this from `Lang`" precisely because regenerating it would make
    # old rows decode as the wrong language.
    #
    # `target_axes_test` pins the successor types (`src/common/target_axes.nim`,
    # `src/common/target_assessment.nim`), including the decomposition of all 41
    # `Lang` values onto the four axes.  It is registered here rather than left
    # to the glob because it is the safety net for the migration that removes
    # `Lang` members, which is exactly when "the test quietly stopped running"
    # would be most expensive.
    "src/tests/cli/lang_enum_contract_test.nim",
    "src/tests/cli/trace_index_migration_test.nim",
    "src/tests/cli/target_axes_test.nim",
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
