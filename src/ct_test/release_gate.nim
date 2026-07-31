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
    sourceFiles: @["src/ct_test/frameworks/nim_unittest.nim"]),
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
