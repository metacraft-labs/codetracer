## The bundled hello-world template — Noir-Studio.md §1b.0 rule 5's first row.
##
## `web_entry.nim` resolves a bare `/noir` to `evTemplate` and names what that
## means in one sentence: "The bundled hello-world. §1b.0 rule 5's first row,
## and the fallback of last resort in §1b.3 step 6." Until now that verdict
## named nothing — `evTemplate` was an enum case with no template behind it,
## which is why every route mounted the welcome screen regardless of what
## `resolveEntry` would have said.
##
## ## Why it is a value here and not files on the deployment
##
## §1b.0 rule 5 is explicit, and the reason is the whole of this module's
## shape: "The hello-world project is a **template shipped in the application
## bundle**, not a stored project with an address. It costs no storage, has no
## retention question, works offline on a second visit, and cannot rot."
##
## A template served from `/assets/template.zip` would break all four at once,
## and it would put a `fetch` on the development loop —
## `ci/test/noir-studio-signed-out.sh` asserts that arm has **zero** egress
## sites, and the deployment descriptor is already read out of the DOM rather
## than fetched for exactly this reason (`web_deployment.nim`'s "Why the
## descriptor travels IN the entry document"). So the template is Nim data,
## compiled into the bundle, and arriving at `/noir` reads it out of memory.
##
## ## Rule 1 holds by construction, and that is worth stating
##
## `web_entry.writesOnArrival` is `false` for every form and
## `mintsServerIdentifier` likewise. Nothing here mints an id, takes a clock
## reading or touches storage: `noirHelloWorld()` returns the same value on
## every call, for every visitor, which is rule 1's "the bare URL serves the
## same bytes to a first-time visitor, a returning one and a crawler" expressed
## as a pure function rather than as a comment.
##
## ## Rule 0's agreement, as a check rather than a promise
##
## `web_entry.knownLanguageEntries` says "A second language is one more entry
## in this array and no change anywhere else — which is the property the rule
## exists to buy". That is not quite free once a language selects a template:
## rule 0 says `/noir` "sets a visitor up with the **right initial template**",
## so a language without one resolves to `evTemplate` and then has nothing to
## open — the silent half-wiring this campaign keeps finding.
##
## `languagesWithoutTemplate()` is that gap as a value, mirroring
## `web_deployment.undeclaredAbsences()`. A test asserts it is empty, so
## adding `"cairo"` to `knownLanguageEntries` and stopping there fails a suite
## instead of shipping a route that opens a blank surface.
##
## ## The tree is a tree, deliberately — and it is a tree nargo COMPILES
##
## §1a: "Noir projects are directory trees — `src/`, `tests/`, `Nargo.toml`,
## multiple modules — so the file tree is present from the first frame rather
## than appearing when a second file does. **A single-file playground would
## misrepresent the language.**" So the template carries three modules, and
## `templateFileCount` is asserted rather than left to whoever edits this file
## next.
##
## WHERE THIS DEPARTS FROM §1a'S PICTURE, and why the picture is wrong. That
## mock-up draws `tests` as a sibling of `src`. Nargo compiles `src/` and
## nothing else, so a top-level `tests/` directory is shown in the file tree
## and never built — measured, with the layout this file shipped first:
##
##     $ nargo test
##     [hello_noir] Running 3 test functions        <- not 4
##     [hello_noir] 3 tests passed
##
## The fourth test was in `tests/bounds.nr` and nargo never saw it, silently.
## A first screen whose file tree contains a directory the toolchain ignores is
## the same failure as the single-file playground the paragraph above forbids,
## one level down: it teaches the visitor a layout that does not work. So tests
## are a MODULE — `src/tests.nr`, declared by `mod tests;` — and
## `ci/test/noir-template-toolchain.sh` is the assertion that keeps it one:
## it materialises this template, runs `nargo test` against it and requires
## five passing tests.

import ./web_entry

type
  TemplateFile* = object
    ## One file in a template, with the path it takes inside the project.
    ##
    ## `path` is project-relative and always uses `/`: it is a key in a
    ## portable value, not a host path, and `platform/paths.nim`'s separator
    ## question does not arise for something that never touches a filesystem.
    path*: string
    content*: string

  ProjectTemplate* = object
    language*: string
      ## The `knownLanguageEntries` value this template is the initial one
      ## for. Empty for `emptyTemplate()`, which is what a language-neutral
      ## root resolves to — see `templateFor`.
    name*: string
      ## The project's display name. NOT a slug and NOT an address: rule 1
      ## says no identifier is minted on arrival, and this is the label a
      ## title bar renders, nothing more.
    entryFile*: string
      ## The file a visitor should be looking at on arrival. §1b.3 step 5's
      ## `f=` fragment overrides it when present; this is the value used when
      ## the link carries no position.
    files*: seq[TemplateFile]
    nargoInfoJson*: string
      ## What THIS template's circuit costs, in `nargo info --json`'s shape.
      ##
      ## A FIELD RATHER THAN A MODULE CONSTANT, and the bug that forced the
      ## change is worth keeping: `web_entry_surface.installTemplatePaneHost`
      ## sent `noirTemplateNargoInfoJson` — the hello-world's numbers —
      ## unconditionally, while its catalog half correctly read
      ## `currentProject()`. One template made that indistinguishable from
      ## correct. A second one makes it a pane that reports 17 ACIR opcodes
      ## over a circuit with hundreds, under a provenance string promising the
      ## number was measured. A wrong measurement presented as a measurement is
      ## worse than an absent one, so the counts now travel WITH the sources
      ## they are about and cannot be read for the wrong project.
      ##
      ## Empty means "this template does not declare a cost", and
      ## `templateConstraintReport` answers an absence rather than a zero.
    constraintProvenance*: string
      ## Which compiler produced `nargoInfoJson`, shown on the pane beside the
      ## number. Empty when `nargoInfoJson` is.
      ##
      ## It is per-template because the two templates were measured by
      ## different engines and a visitor must be able to tell which — see
      ## `noirTemplateConstraintProvenance` for why naming the wrong compiler
      ## is not a cosmetic error.

const noirTemplateName* = "hello_noir"
  ## §1a's mock-up names the open project `hello_noir` in the tab strip. The
  ## name is here rather than spelled at a call site so the surface and any
  ## test read the same string.

const noirEntryFile* = "src/main.nr"

const noirInputsFile* = "Prover.toml"
  ## Where a Noir `bin` package keeps the arguments its `main` is run with.
  ##
  ## Named here because two different layers ask about it and neither should
  ## spell it: `noir_build_producer.traceInputsMissing` reports its absence by
  ## name, and the Run path reads it out of the open project to hand to
  ## `ct_trace`, whose contract is "`inputs` is the text of a `Prover.toml`"
  ## (`tooling/tracer_wasm/src/lib.rs`).

# ---------------------------------------------------------------------------
# What the template COSTS, measured by the real producer
# ---------------------------------------------------------------------------

const noirTemplateNargoInfoJson* = """{"programs":[{"package_name":"hello_noir","functions":[{"name":"main","opcodes":17}],"unconstrained_functions":[{"name":"directive_invert","opcodes":9},{"name":"directive_integer_quotient","opcodes":8}]}]}"""
  ## The bundled template's constraint counts, in `nargo info --json`'s shape
  ## so one parser serves both hosts. It is no longer one command's verbatim
  ## output: the ACIR total is maintained against the wasm compiler the browser
  ## runs (which is not the flake's `nargo` — the two disagree on this
  ## template), while the unconstrained counts still carry `nargo info`'s
  ## figures. See the drift section below for which half a gate checks.
  ##
  ## ## Why a constant is the honest representation, and not a cached answer
  ##
  ## A circuit's opcode count is a pure function of its sources. The template's
  ## sources are a compile-time constant — that is this module's whole design,
  ## and rule 5's reason for it ("it costs no storage, has no retention
  ## question, works offline on a second visit, and cannot rot"). A pure
  ## function of a constant is a constant, so carrying the answer is the same
  ## kind of claim as carrying the files.
  ##
  ## What would make it dishonest is drift, and what partly prevents it is
  ## `ci/test/noir-template-toolchain.sh`. Be exact about how much it covers,
  ## because it is less than this whole constant:
  ##
  ## * The **ACIR total** — the sum of `programs[].functions[].opcodes`, `17`
  ##   here — is compiled from this template by the shipping wasm module and
  ##   compared as an integer. That comparison is the one that decides whether
  ##   the pane's headline number is right.
  ## * The **unconstrained counts** (`directive_invert`, `directive_integer_quotient`)
  ##   are compared against nothing. Editing them, or editing `main.nr` in a way
  ##   that only moves them, passes the gate.
  ##
  ## It does not diff these bytes and it does not run `nargo info` — see that
  ## script's own note at the ACIR comparison ("Only the ACIR total is
  ## compared"). The gate that checks the crate compiles and its five tests pass
  ## is the same script, in its other arms.
  ##
  ## THIS NAMED `test_noir_template_constraints.nim` UNTIL 09-02, AND NO SUCH
  ## FILE HAS EVER EXISTED. The description was accurate and the filename was
  ## invented, so a reader who wanted to see the drift check ran out of places
  ## to look, and a reader who merely saw a test named went away reassured.
  ##
  ## The check it describes is real — it is the shell gate above — but until
  ## 09-02 it compared this constant against whatever `nargo` was on `PATH`,
  ## which is the flake's `noir` pin. `ci/deploy/noir-wasm.pin` states that the
  ## flake pin "is NOT this one": the browser runs a different compiler, and the
  ## two do not agree on this template's count. So the gate enforced a number
  ## the pane could never display, and when the value was corrected TOWARD the
  ## native pin the gate approved it and the pane went wrong. It is now measured
  ## through the wasm module the deploy publishes, which is the only compiler
  ## whose answer a user can see.
  ##
  ## ## And why the web needs it at all
  ##
  ## `nargo` is not in a browser and the wasm module has no `info` export, so
  ## the number cannot be *asked for* by that name. It can still be COMPUTED:
  ## `ci/test/noir-template-acir-count.mjs` gets exactly this ACIR total from
  ## the shipping module over the existing ABI, and `web_noir_build.nim` already
  ## issues a program-mode (`nbmProgram`) compile through the worker from a tab.
  ##
  ## SO THE REASON THIS IS A CONSTANT IS NOT THAT COMPUTING IT IS BLOCKED.
  ## Nothing new has to be exported and no worker branch has to be added. The
  ## reason is rule 5's: a constant costs no storage, needs no network, and is
  ## already correct on first paint, whereas computing it would make the pane
  ## wait for a compile to display a property of files that cannot change.
  ##
  ## THIS PARAGRAPH HAS BEEN WRONG TWICE. It once said the same of `nargo test`;
  ## it then said producing the count "needs a new wasm export and a new worker
  ## branch", which told a reader that work was expensive when it was nearly
  ## free. Do not restate the module's exports or the worker's subcommand list
  ## here — both have grown since each was last written down. The exports are
  ## whatever `ci/test/noir-wasm-worker/worker.mjs` binds; the subcommands are
  ## whatever `wasm_worker_browser.js` dispatches. Read them there.

const noirTemplateConstraintProvenance* =
  "Measured by compiling the project."
  ## Shown in the pane. A count with no provenance is a count a user cannot
  ## judge: "17" means one thing measured a second ago and another thing
  ## shipped in a bundle, and the pane must not make them look alike.
  ##
  ## THIS SAID "nargo info --json, run against this template at build time"
  ## and that named the wrong compiler. The shipped ACIR total is the WASM
  ## module's answer; the flake's `nargo` returns a different number for these
  ## same sources, so a developer who ran the named command got a figure the
  ## pane never shows and had no way to tell which was wrong. The string now
  ## names the compiler whose answer the visitor is actually looking at.
  ##
  ## `ci/test/noir-template-toolchain.sh` checks this string. It used to assert
  ## only that it contained "nargo info" — a check that certified the wrong
  ## provenance and pinned it in place. It now asserts the string names the
  ## shipping engine, so the two move together.

proc noirHelloWorld*(): ProjectTemplate =
  ## §1a's project, as its picture shows it: `src/main.nr`, `src/utils.nr`,
  ## `tests/`, `Nargo.toml`.
  ##
  ## The code is real Noir rather than a placeholder, because the first thing
  ## §1a promises is a project "its tests already passing, one keystroke from
  ## being changed" — a visitor who edits a comment-shaped stub learns nothing
  ## about the language, and a template that does not compile would make the
  ## first Run a bug report.
  ProjectTemplate(
    language: "noir",
    name: noirTemplateName,
    entryFile: noirEntryFile,
    # THE `content:` STRINGS BELOW MAY CARRY UTF-8, and this note exists so
    # nobody transliterates them back out of caution.
    #
    # They were ASCII for about a day (`46ac63a1`), and it was not style. Noir's
    # lexer used to refuse a non-ASCII byte anywhere in a comment --
    #
    #     Invalid comment character: only ASCII is currently supported.
    #
    # -- and `flake.nix`'s `noir` pin was `5e98f904` (beta.2), which still had
    # that check, while the wasm module the browser downloads did not. So
    # `src/tests.nr`'s two section signs and one em dash compiled in a tab and
    # were refused by `nargo`, and the Test Results pane reported five passing
    # tests over a template that did not build.
    #
    # THE DIRECTION WAS THE OPPOSITE OF THE OBVIOUS ONE: the wasm module was not
    # missing a check, it was NEWER. Upstream removed the restriction on purpose
    # in `93bb72f8` "feat!: allow UTF-8 in comments (#12699)", 2026-05-18. The
    # engine that refused was the stale one, so the repair was to move the
    # native pin -- not to keep paying for it in prose.
    #
    # THAT PIN HAS MOVED, to `codetracer`@ca080a58 (beta.26), which contains
    # `93bb72f8`. The typography is back, and it was checked by COMPILING the
    # bytes this file actually ships rather than by reading the lexer: extracted
    # from these strings and run through
    # `/nix/store/0yki0k9gzfqg0js2wprmisrfr87sriqi-Noir/bin/nargo`, the crate
    # compiles, `nargo test` reports `5 tests passed`, and `nargo info` reports
    # main: 17 opcodes.
    #
    # A GREEN LOCAL RUN STILL PROVES LESS THAN IT LOOKS, which is why the
    # measurement above names a store path. `detect-siblings.sh` puts a sibling
    # checkout's `nargo` ahead of the flake's on PATH, so "it compiled on my
    # machine" does not say which compiler agreed. Arm U of
    # `ci/test/noir-template-toolchain.sh` is the standing check, and it prints
    # the binary that answered.
    files: @[
      TemplateFile(
        path: "Nargo.toml",
        content: """[package]
name = "hello_noir"
type = "bin"
authors = [""]

[dependencies]
"""),
      # THE FILE THAT MADE `Run` POSSIBLE, and its absence is why Run did
      # nothing until now.
      #
      # `main(x: Field, y: pub Field)` takes two arguments and a `bin`
      # package takes them from `Prover.toml`. Without one the tracer has
      # nothing to encode against the ABI and refuses — correctly — so the
      # template shipped a project that could be compiled and could not be
      # run, which is half of what §1a promises ("its tests already passing,
      # one keystroke from being changed").
      #
      # WHY THESE TWO VALUES AND NOT ZEROES. A default of `0` for both would
      # satisfy the ABI and then fail `assert(x != y)` on the first Run — a
      # first-run experience that reports the bundled template as broken. `1`
      # and `2` are the template's OWN already-passing case: `test_main()`
      # calls `main(1, 2)` a few lines down in `src/main.nr`. So the first
      # Run reproduces a test the visitor can see, which is the honest
      # default and the one whose failure would mean something.
      #
      # Quoted strings, because `Field` values are arbitrary-precision and
      # nargo's TOML format takes them as strings; a bare `1` is a TOML
      # integer and does not round-trip for values above 2^63.
      TemplateFile(
        path: noirInputsFile,
        content: """x = "1"
y = "2"
"""),
      TemplateFile(
        path: "src/main.nr",
        content: """mod tests;
mod utils;

// The first thing you see, and the first thing you can change.
//
// `x` is private and `y` is public: Noir proves it knows an `x` that
// satisfies every assertion below, without revealing which one.
fn main(x: Field, y: pub Field) {
    assert(x != y);
    utils::assert_in_range(x);
}

#[test]
fn test_main() {
    main(1, 2);
}

#[test(should_fail)]
fn test_equal_inputs_are_rejected() {
    main(3, 3);
}
"""),
      TemplateFile(
        path: "src/tests.nr",
        content: """// Tests are a MODULE of the crate, declared by `mod tests;` in `main.nr`.
//
// Not a top-level `tests/` directory beside `src/`, which is what §1a's
// mock-up draws — nargo compiles `src/` and nothing else, so a sibling
// `tests/` folder would be shown in the file tree and never built. A tree
// carrying a directory the toolchain ignores is precisely the
// "misrepresents the language" failure §1a warns about, one level down from
// the single-file playground it names. Measured: `nargo test` over the
// earlier layout ran 3 of 4 tests and said nothing about the fourth.

use crate::utils;

#[test]
fn test_bounds_accepts_the_largest_valid_value() {
    utils::assert_in_range(127);
}

#[test(should_fail)]
fn test_bounds_rejects_the_first_invalid_value() {
    utils::assert_in_range(128);
}
"""),
      TemplateFile(
        path: "src/utils.nr",
        content: """// A second module, because a Noir project is a directory tree and a
// single-file playground would misrepresent the language.

global MAX: Field = 128;

pub fn assert_in_range(value: Field) {
    assert(value as u32 < MAX as u32);
}

#[test]
fn test_in_range_accepts_small_values() {
    assert_in_range(7);
}
""")],
    nargoInfoJson: noirTemplateNargoInfoJson,
    constraintProvenance: noirTemplateConstraintProvenance)

const noirDemoName* = "oracle_settlement"
  ## The demo project's name, which is also its key in the browser's project
  ## store (`web_project_persistence.prepareProject` uses `tmpl.name`) and its
  ## root path in the file tree (`web_project_store.templateProjectRoot`).
  ##
  ## It must differ from `noirTemplateName` for exactly that reason: two
  ## templates sharing a name would share one stored project, and a visitor
  ## who edited the hello-world would find those edits inside the demo.

const noirDemoEntryFile* = "src/main.nr"

const noirDemoNargoInfoJson* = """{"programs":[{"package_name":"oracle_settlement","functions":[{"name":"main","opcodes":478}],"unconstrained_functions":[{"name":"print_unconstrained","opcodes":169},{"name":"print_unconstrained","opcodes":165},{"name":"directive_integer_quotient","opcodes":8},{"name":"directive_invert","opcodes":9}]}]}"""
  ## What the demo circuit costs. See `noirDemoConstraintProvenance` for which
  ## compiler answered and why it is not the one that measured the hello-world.

const noirDemoConstraintProvenance* =
  "Measured by compiling the project."
  ## The same sentence the hello-world carries, and it is the same claim: the
  ## number was produced by the wasm module the deploy publishes, not by a
  ## native `nargo` a visitor cannot see.
  ##
  ## IT IS MEASURED BY A DIFFERENT SCRIPT, and the reason is a defect in the
  ## older one that a second template exposed.
  ## `ci/test/noir-template-acir-count.mjs` counts entries in the artifact's
  ## `acir_locations` map — an opcode-INDEXED map of source positions — and
  ## guards that with a check that the key set is exactly `0..n-1`. Measured
  ## through the pinned module:
  ##
  ##     hello_noir          17 opcodes, acir_locations 0..16   -> dense
  ##     oracle_settlement  478 opcodes, acir_locations 16..477 -> 462 entries
  ##
  ## The sixteen missing entries are the `RANGE` opcodes the compiler emits for
  ## the witnesses of an integer-typed parameter, which carry no source
  ## position. `hello_noir`'s `main` takes two `Field`s and needs none, so the
  ## identity held there by accident rather than by structure. That script
  ## REFUSES on this package rather than reporting 462, which is the right
  ## behaviour and is why nothing shipped wrong; it simply cannot answer for a
  ## circuit with an integer parameter.
  ##
  ## So this figure comes from `ci/test/noir-acir-opcode-count.mjs`, which
  ## counts the opcodes in the artifact's own ACIR instead of its debug map.
  ## That script reproduces `17` for the hello-world — the number the existing
  ## gate already enforces — before answering `478` here, so the new technique
  ## is checked against the known-good case rather than trusted.
  ##
  ## AND THE TWO ENGINES AGREE ON THIS ONE. `ci/deploy/noir-wasm.pin` warns
  ## that the flake's `nargo` "is NOT this one" and the two disagree on the
  ## hello-world, so agreement was not assumed: native `nargo info --json`
  ## reports `main: 478` for these sources and the wasm module's bytecode
  ## decodes to 478 opcodes. Naming the wrong compiler is how the hello-world's
  ## pane went wrong once before — see `noirTemplateConstraintProvenance`.

proc noirOracleDemo*(): ProjectTemplate =
  ## The worked example `/noir/demo` opens, and the reason it exists.
  ##
  ## ## What it is FOR, which is not "a bigger hello-world"
  ##
  ## The hello-world's job is to be edited in the first ten seconds. This one's
  ## job is to be DEBUGGED, and every choice below follows from that: it ships
  ## a plausible circuit, a suite of tests that all pass, and one wrong answer
  ## that none of those tests catch.
  ##
  ## A demo whose bug is visible on inspection demonstrates nothing about a
  ## time-travel debugger — a reader finds it by reading and never opens a
  ## pane. So the bug here is not a typo. It is a WRONG CLAIM in a comment
  ## (`src/sort.nr`, `SETTLE_PASSES`), attached to a real and correct pressure:
  ## comparators are the largest line item in a ZK circuit, so cutting the sort
  ## short to save constraints is a thing an engineer would actually do. The
  ## claim — that settling the middle element needs only `MAX_REPORTS / 2`
  ## bubble passes — is false, and it is false only for some inputs: a value
  ## bubbles LEFT one slot per pass, so a low outlier sitting at the end of the
  ## array is still in flight when the passes run out.
  ##
  ## ## Why the tests do not catch it, and why that is the honest case
  ##
  ## All eight tests pass. They are the tests somebody would write — a full
  ## round, a round with stale publishers, three refusals, a sort case, a
  ## helper case — and none of them happens to place the lowest price last.
  ## That is not a contrivance: it is the ordinary reason a data-dependent bug
  ## reaches production, and it is what makes the `Prover.toml` round worth
  ## running.
  ##
  ## ## What the visitor actually sees
  ##
  ## Run refuses with "the published price is not the median of this round".
  ## The event log has already printed `settled price: 242990` where the
  ## published price was `243180` — both are perfectly ordinary ETH prices, so
  ## nothing about the OUTPUT says which is wrong. Measured through the two
  ## pinned wasm modules, the trace is 2094 events: 475 steps, 35 calls, 33
  ## returns, over five source files. The three `one_pass` frames in the
  ## calltrace are the point of the design — `sort::ascending` calls a named
  ## function once per pass instead of nesting a second loop, so "how many
  ## passes did we pay for" is a thing the calltrace SHOWS rather than a bound
  ## a reader has to evaluate in their head.
  ##
  ## ## Plain Noir, deliberately
  ##
  ## No aztec-nr. The circuit is a price-feed settlement — private publisher
  ## reports, a public settled price — which is recognisable smart-contract
  ## work and needs nothing but the language. Vendoring a framework to make a
  ## demo look serious would buy a heavier build and a slower first Run.
  ProjectTemplate(
    language: "noir",
    name: noirDemoName,
    entryFile: noirDemoEntryFile,
    # THE BYTES BELOW ARE THE BYTES THAT WERE MEASURED. They were extracted
    # from this file, compiled by the pinned native `nargo` (beta.26,
    # `nix/store/...-Noir`) and by the pinned wasm compiler, and the run
    # described above is that package's real trace. Editing a price here
    # without re-running `ci/test/noir-demo-template.sh` changes which round
    # the demo settles and can silently repair the bug — the arithmetic that
    # makes it bite is in the test's expectations, not only here.
    files: @[
      TemplateFile(
        path: "Nargo.toml",
        content: """[package]
name = "oracle_settlement"
type = "bin"
authors = [""]

[dependencies]
"""),
      TemplateFile(
        path: "Prover.toml",
        content: """now = "1717200000"
published_price = "243180"
prices = ["243150", "243200", "243075", "243310", "243180", "243260", "242990"]
timestamps = [
  "1717199960",
  "1717199985",
  "1717199905",
  "1717199975",
  "1717199940",
  "1717199100",
  "1717199970",
]
"""),
      TemplateFile(
        path: "src/main.nr",
        content: """mod config;
mod report;
mod sort;
mod aggregate;
mod tests;

use aggregate::settle;
use config::MAX_REPORTS;

// A settlement round for the ETH/USD feed.
//
// The publishers' prices and signing times are private inputs. The circuit
// proves that `published_price` is the median of the reports that were fresh
// at `now`, and that every one of those reports sits inside the deviation
// band -- without revealing which publisher said what.
fn main(
    prices: [u64; MAX_REPORTS],
    timestamps: [u64; MAX_REPORTS],
    now: pub u64,
    published_price: pub u64,
) {
    let settled = settle(prices, timestamps, now);
    assert(settled == published_price, "the published price is not the median of this round");
}

#[test]
fn test_main_settles_the_reference_round() {
    let now: u64 = 1717200000;
    let prices = [243075, 243310, 242990, 243200, 243150, 243260, 243180];
    let timestamps =
        [now - 40, now - 15, now - 95, now - 25, now - 60, now - 110, now - 30];
    main(prices, timestamps, now, 243180);
}
"""),
      TemplateFile(
        path: "src/config.nr",
        content: """// Parameters of the ETH/USD feed this circuit settles.
//
// They are globals rather than circuit inputs on purpose. A feed's shape is
// part of the deployed program, so changing the quorum or the staleness
// window means a new circuit and a new verifying key -- which is exactly the
// governance property a price feed wants.

// How many publishers are under contract for this feed.
pub global MAX_REPORTS: u32 = 7;

// A round with fewer fresh reports than this is refused rather than settled.
pub global MIN_QUORUM: u32 = 4;

// A report signed more than this many seconds before the settlement time is
// dropped before aggregation.
pub global STALENESS_WINDOW: u64 = 300;

// Every fresh report must sit inside this band around the settled price, in
// basis points. 500 bps = 5%.
pub global MAX_DEVIATION_BPS: u64 = 500;

pub global BPS_DENOMINATOR: u64 = 10000;
"""),
      TemplateFile(
        path: "src/report.nr",
        content: """use crate::config::{BPS_DENOMINATOR, MAX_DEVIATION_BPS, STALENESS_WINDOW};

// How long before the settlement time a publisher signed, in seconds.
//
// A report dated AFTER the round is not a stale report -- it is a broken
// clock or a forged timestamp -- so the circuit refuses the whole round
// rather than quietly treating it as fresh.
pub fn age_of(timestamp: u64, now: u64) -> u64 {
    assert(timestamp <= now, "report is dated after the settlement time");
    now - timestamp
}

pub fn is_fresh(timestamp: u64, now: u64) -> bool {
    age_of(timestamp, now) <= STALENESS_WINDOW
}

// |a - b|, written without a subtraction that can underflow: both operands of
// an `if` are evaluated in a constrained circuit, so `if a > b { a - b } else
// { b - a }` range-checks both differences and one of them is always wrong.
pub fn spread(a: u64, b: u64) -> u64 {
    let higher = if a > b { a } else { b };
    let lower = if a > b { b } else { a };
    higher - lower
}

// A publisher whose price sits far from the settled one is either broken or
// lying, and either way the round is not settleable.
pub fn within_band(price: u64, settled: u64) -> bool {
    spread(price, settled) * BPS_DENOMINATOR <= settled * MAX_DEVIATION_BPS
}
"""),
      TemplateFile(
        path: "src/sort.nr",
        content: """use crate::config::MAX_REPORTS;

// How many bubble passes the circuit pays for.
//
// CIRCUIT SIZE. A total order over MAX_REPORTS values needs MAX_REPORTS - 1
// passes, and every comparator in a pass is a range check -- by a wide margin
// the largest line item in this circuit. We do not need a total order here.
// We need one element: the one that ends up in the middle. Each pass carries
// one more value into its final position, so SETTLE_PASSES passes settle
// everything from the middle downwards, and the passes above the middle are
// comparators we would be paying for and never reading.
pub global SETTLE_PASSES: u32 = MAX_REPORTS / 2;

// One bubble pass: walk the array once, swapping any neighbours that are out
// of order. Split out of `ascending` so the pass count is a thing you can see
// at a call site instead of a bound buried in a nested loop.
fn one_pass(values: [u64; MAX_REPORTS]) -> [u64; MAX_REPORTS] {
    let mut out = values;
    for i in 0..MAX_REPORTS - 1 {
        if out[i + 1] < out[i] {
            let smaller = out[i + 1];
            out[i + 1] = out[i];
            out[i] = smaller;
        }
    }
    out
}

pub fn ascending(values: [u64; MAX_REPORTS]) -> [u64; MAX_REPORTS] {
    let mut out = values;
    for _pass in 0..SETTLE_PASSES {
        out = one_pass(out);
    }
    out
}
"""),
      TemplateFile(
        path: "src/aggregate.nr",
        content: """use crate::config::{MAX_REPORTS, MIN_QUORUM};
use crate::report::{is_fresh, within_band};
use crate::sort;

// Stale slots are replaced with the largest representable price so that the
// sort carries them past the end of the fresh window, where they can never
// land on the median.
pub global STALE_SENTINEL: u64 = 0xffffffffffffffff;

pub struct Batch {
    // One slot per publisher: their price if the report was fresh, the
    // sentinel if it was not.
    pub keys: [u64; MAX_REPORTS],
    pub fresh_count: u32,
}

// Drop the reports that were too old to count at `now`.
pub fn filter_fresh(
    prices: [u64; MAX_REPORTS],
    timestamps: [u64; MAX_REPORTS],
    now: u64,
) -> Batch {
    let mut keys = [STALE_SENTINEL; MAX_REPORTS];
    let mut fresh_count: u32 = 0;
    for i in 0..MAX_REPORTS {
        if is_fresh(timestamps[i], now) {
            keys[i] = prices[i];
            fresh_count += 1;
        }
    }
    Batch { keys, fresh_count }
}

// The median price of a round.
//
// Once ordered, the fresh reports occupy the first `fresh_count` slots and
// the sentinels follow them, so the middle of the fresh window sits at
// `fresh_count / 2`.
pub fn median_of(batch: Batch) -> u64 {
    let ordered = sort::ascending(batch.keys);
    ordered[batch.fresh_count / 2]
}

// The price this round settles at, or a refusal.
pub fn settle(
    prices: [u64; MAX_REPORTS],
    timestamps: [u64; MAX_REPORTS],
    now: u64,
) -> u64 {
    let batch = filter_fresh(prices, timestamps, now);
    let fresh_count = batch.fresh_count;
    println(f"fresh reports: {fresh_count}");
    assert(fresh_count >= MIN_QUORUM, "not enough fresh reports to settle this round");

    let settled = median_of(batch);
    println(f"settled price: {settled}");

    // A median is only manipulation-resistant if the reports around it agree,
    // so every publisher that counted has to sit inside the band.
    for i in 0..MAX_REPORTS {
        if batch.keys[i] != STALE_SENTINEL {
            assert(within_band(batch.keys[i], settled), "a fresh report deviates beyond the band");
        }
    }

    settled
}
"""),
      TemplateFile(
        path: "src/tests.nr",
        content: """// The round-level tests. They are a MODULE of the crate (`mod tests;` in
// `main.nr`) rather than a sibling `tests/` directory, because nargo compiles
// `src/` and nothing else.

use crate::aggregate::{filter_fresh, median_of, settle};
use crate::report::spread;
use crate::sort;

// A round where every publisher reported on time. `now` and the signing times
// are seconds; the prices are USD cents, so 243180 is $2431.80.
global NOW: u64 = 1717200000;

fn all_fresh() -> [u64; 7] {
    [NOW - 40, NOW - 15, NOW - 95, NOW - 25, NOW - 60, NOW - 110, NOW - 30]
}

#[test]
fn test_settles_the_median_of_a_full_round() {
    let prices = [243075, 243310, 242990, 243200, 243150, 243260, 243180];
    assert(settle(prices, all_fresh(), NOW) == 243180);
}

#[test]
fn test_stale_reports_never_reach_the_median() {
    // Publishers 4 and 6 last signed twenty minutes ago; their prices are
    // nonsense and must not influence the round.
    let prices = [243075, 243310, 242990, 243200, 999999, 243150, 888888];
    let timestamps =
        [NOW - 40, NOW - 15, NOW - 95, NOW - 25, NOW - 1200, NOW - 60, NOW - 1200];
    let batch = filter_fresh(prices, timestamps, NOW);
    assert(batch.fresh_count == 5);
    assert(median_of(batch) == 243150);
}

#[test(should_fail_with = "a fresh report deviates beyond the band")]
fn test_rejects_a_report_outside_the_deviation_band() {
    // Publisher 3 reports $3000.00 into a $2431 market.
    let prices = [243075, 243310, 242990, 300000, 243150, 243200, 243260];
    let _ = settle(prices, all_fresh(), NOW);
}

#[test(should_fail_with = "not enough fresh reports to settle this round")]
fn test_rejects_a_round_below_the_quorum() {
    let prices = [243075, 243310, 242990, 243200, 243150, 243260, 243180];
    let timestamps = [
        NOW - 40, NOW - 15, NOW - 95, NOW - 1200, NOW - 1200, NOW - 1200, NOW - 1200,
    ];
    let _ = settle(prices, timestamps, NOW);
}

#[test(should_fail_with = "report is dated after the settlement time")]
fn test_rejects_a_report_dated_after_the_round() {
    let prices = [243075, 243310, 242990, 243200, 243150, 243260, 243180];
    let timestamps =
        [NOW - 40, NOW - 15, NOW - 95, NOW - 25, NOW - 60, NOW - 110, NOW + 5];
    let _ = settle(prices, timestamps, NOW);
}

#[test]
fn test_ascending_orders_a_shuffled_batch() {
    let ordered = sort::ascending([243075, 243310, 242990, 243200, 243150, 243260, 243180]);
    assert(ordered == [242990, 243075, 243150, 243180, 243200, 243260, 243310]);
}

#[test]
fn test_spread_is_symmetric() {
    assert(spread(243310, 242990) == 320);
    assert(spread(242990, 243310) == 320);
}
"""),
    ],
    nargoInfoJson: noirDemoNargoInfoJson,
    constraintProvenance: noirDemoConstraintProvenance)

proc emptyTemplate*(): ProjectTemplate =
  ## What a language-neutral root selects, and it is deliberately empty rather
  ## than defaulted to Noir.
  ##
  ## Rule 0 is the reason: "The language is an entry point, not a namespace."
  ## `/` carries no language, so there is no "right initial template" to
  ## choose — picking Noir there would make Noir the product's default
  ## language, which is the classification rule 0 exists to refuse. A visitor
  ## at `/` is offered the language-neutral surface instead, and
  ## `hasFiles` is how a call site tells the two apart without re-deriving
  ## the rule.
  ProjectTemplate(language: "", name: "", entryFile: "", files: @[])

proc hasFiles*(tmpl: ProjectTemplate): bool =
  tmpl.files.len > 0

proc templateFor*(language: string; form: EntryForm): ProjectTemplate =
  ## Rule 0's selection, and the only place an entry maps to a template.
  ##
  ## Takes the `languageEntry` and `form` fields `resolveEntry` already
  ## produces, so a call site never re-parses a path — the second
  ## implementation of "which prefixes exist" is the failure
  ## `web_entry.classifyPath`'s own header warns about, and this is the same
  ## hazard one field further on.
  ##
  ## `form` IS REQUIRED AND HAS NO DEFAULT, which is the point of taking it.
  ## A default would have let the two existing call sites keep compiling
  ## unchanged and keep serving the hello-world at `/noir/demo` — a route that
  ## responds, mounts a project and is wrong, which is the exact shape of
  ## failure this campaign keeps finding. Making it a compile error at every
  ## call site is cheap: there are two, and each has to say which entry it is
  ## resolving for.
  ##
  ## THE TWO CALL SITES MUST AGREE. `ui_js` resolves this twice — once to seed
  ## the project store (`prepareProject`) and once to mount the surface — and
  ## if they disagree, `prepareProject` seeds one template's files while
  ## `enterTemplateEditMode` finds a live project already set and keeps it. The
  ## visitor gets the store's copy silently. Both sites pass `entry.form`.
  case language
  of "noir":
    if form == efDemo: noirOracleDemo() else: noirHelloWorld()
  else: emptyTemplate()

proc languagesWithoutTemplate*(): seq[string] =
  ## Rule 0's agreement, as a value a test reads. See the header.
  ##
  ## `efBare` because this asks rule 0's question — "does every language this
  ## product has an entry point for have an initial template" — and the initial
  ## template is the one the BARE entry serves. A language whose `/demo`
  ## existed and whose `/noir` did not would still be the gap rule 0 is about.
  for row in knownLanguageEntries:
    if not templateFor(row.entry, efBare).hasFiles:
      result.add row.entry

proc templatesWithoutConstraintCounts*(): seq[string] =
  ## The templates that would make the Constraints pane report an absence, as a
  ## value, mirroring `languagesWithoutTemplate`.
  ##
  ## Adding a third template and forgetting to measure it is the same class of
  ## half-wiring as adding a language and forgetting its template, and it fails
  ## the same way: a pane that opens and says nothing. A test asserts this is
  ## empty, so the omission is a red suite rather than a blank pane.
  for tmpl in [noirHelloWorld(), noirOracleDemo()]:
    if tmpl.nargoInfoJson.len == 0 or tmpl.constraintProvenance.len == 0:
      result.add tmpl.name

proc templateFileCount*(tmpl: ProjectTemplate): int =
  tmpl.files.len

proc templateDirectories*(tmpl: ProjectTemplate): seq[string] =
  ## The distinct directory prefixes the files imply, in first-seen order.
  ##
  ## Derived rather than declared beside `files`, so a template cannot claim a
  ## directory it has no file in — the filesystem surface renders this and a
  ## phantom folder would be a pane showing something the project does not
  ## have.
  for file in tmpl.files:
    var directory = ""
    for i in 0 ..< file.path.len:
      if file.path[i] == '/':
        directory = file.path[0 ..< i]
    if directory.len == 0: continue
    var seen = false
    for existing in result:
      if existing == directory: seen = true
    if not seen: result.add directory

proc fileContent*(tmpl: ProjectTemplate; path: string): string =
  ## The template's copy of `path`, or the empty string.
  ##
  ## An absent file returns empty rather than raising: §1b.3 step 5 has every
  ## part of a link degrading independently, and a fragment naming a file the
  ## template does not carry must open the project at rest rather than fail
  ## the whole arrival.
  for file in tmpl.files:
    if file.path == path: return file.content
  ""
