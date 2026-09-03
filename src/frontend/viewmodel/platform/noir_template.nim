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
""")])

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

proc templateFor*(language: string): ProjectTemplate =
  ## Rule 0's selection, and the only place a language maps to a template.
  ##
  ## Takes the `languageEntry` field `resolveEntry` already produces, so a
  ## call site never re-parses a path — the second implementation of "which
  ## prefixes exist" is the failure `web_entry.classifyPath`'s own header
  ## warns about, and this is the same hazard one field further on.
  case language
  of "noir": noirHelloWorld()
  else: emptyTemplate()

proc languagesWithoutTemplate*(): seq[string] =
  ## Rule 0's agreement, as a value a test reads. See the header.
  for language in knownLanguageEntries:
    if not templateFor(language).hasFiles:
      result.add language

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
  "measured at build time by the Noir compiler this page runs"
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
