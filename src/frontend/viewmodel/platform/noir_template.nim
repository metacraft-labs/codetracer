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
    files: @[
      TemplateFile(
        path: "Nargo.toml",
        content: """[package]
name = "hello_noir"
type = "bin"
authors = [""]

[dependencies]
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
  ## The bundled template's `nargo info --json`, verbatim.
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
  ## What would make it dishonest is drift, and that is what
  ## `test_noir_template_constraints.nim` exists to prevent: it writes this
  ## template to a temporary directory, runs `nargo info --json` against it,
  ## and fails if the bytes differ. So editing `main.nr` without re-measuring
  ## fails a suite instead of shipping a number that is quietly wrong — the
  ## same gate that checks the crate compiles and its five tests pass.
  ##
  ## ## And why the web needs it at all
  ##
  ## `nargo` is not in a browser, and the wasm compiler has no `info`
  ## operation: `compile_vfs.rs` exports `nv_compile_vfs` and nothing else, the
  ## worker dispatches exactly `compile` and `trace`, and the only compile a
  ## tracer host asks for sets `force_brillig: true` — so even decoding its
  ## artifact would answer about an all-unconstrained build rather than the
  ## circuit. Producing this number in a tab needs a new wasm export and a new
  ## worker branch; until then the answer travels with the sources it is an
  ## answer about.

const noirTemplateConstraintProvenance* =
  "nargo info --json, run against this template at build time"
  ## Shown in the pane. A count with no provenance is a count a user cannot
  ## judge: "17" means one thing measured a second ago and another thing
  ## shipped in a bundle, and the pane must not make them look alike.
