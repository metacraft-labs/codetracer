## test_support/spec_documents.nim — ONE place that knows where a published
## CodeTracer specification document is, for every suite that READS one
## instead of transcribing it.
##
## ## Why this exists
##
## A suite that reads its oracle out of the sibling specification checkout has
## to spell the way there. Four suites spelled it themselves, as four literal
## paths at two different `..` depths — one `../` from the GPUI suite and
## `../../../../../../` from the three ViewModel ones, each counted from its own
## directory:
##
##   * `test_cross_renderer_visual_alignment` (GPUI), at run time;
##   * `test_editor_vim_import`, `test_editor_vocabulary_oracle` and
##     `test_editor_collab_examples` (ViewModel), at COMPILE time through
##     `staticRead`.
##
## `codetracer-specs` then adopted the project-management layout in its own
## `1735345d` ("Adopt the pm layout: spec/, milestones/, issues/"): the topical
## trees moved under `spec/`, every `*.milestones.org` and `*.status.*` moved
## under `milestones/`, and no compatibility symlink was left behind. All four
## spellings broke at once, in two different ways — the GPUI suite started
## raising at startup and reported **0 cases and 0 checks**, and the three
## `staticRead` suites stopped COMPILING — and each had to be repaired
## separately because the layout was knowledge each of them held privately.
##
## This module holds it once (Verification-Harness-Traps §30: one predicate,
## one spelling). The next layout change — the rename of the repository
## itself to `codetracer-pm` is already argued for in that same commit
## message — is `SpecRepoDirName` and `SpecSubdir` below, and nothing else.
##
## ## A MISSING SPECIFICATION DOCUMENT STAYS A HARD RED
##
## Nothing here falls back, searches a second location, or returns an empty
## string. There is deliberately **no** `specDocumentOrSkip`. A suite whose
## oracle is absent must fail by name:
##
##   * `specDocument` is `staticRead`, so an absent document is a COMPILE
##     error naming the absolute path it tried to open;
##   * `specDocumentPath` returns a path and asserts nothing, so a caller
##     keeps using its own hard-failing prerequisite check — the GPUI suite's
##     `requireFile` is one, and this module deliberately does not carry a
##     second copy of that predicate (§30a).
##
## ## The paths are absolute, and that is the point
##
## The old spellings were relative to the suite's own directory, so the number
## of `..` segments was part of each suite's private knowledge and a suite
## that moved directories took a silently wrong path with it. `CheckoutRoot`
## below is derived from `currentSourcePath()`, so every caller gets the same
## answer from any directory and from any working directory — which also means
## a harness that runs a suite with a different `cwd` reads the same document.

import std/[os, strutils]

const
  ThisModuleTail = "src/frontend/test_support/spec_documents.nim"
    ## Where this file is expected to be, spelled so that the walk below can
    ## check its own assumption. Moving this file four directories up from the
    ## checkout root would otherwise make `CheckoutRoot` quietly wrong.

  SpecRepoDirName* = "codetracer-specs"
    ## The sibling checkout's directory name, beside this one.

  SpecSubdir* = "spec"
    ## The specification tree inside it, since `codetracer-specs` `1735345d`.
    ## Its two siblings there are `milestones/` (every `*.milestones.org` and
    ## `*.status.*`) and `issues/`; neither is read from Nim today.

const
  CheckoutRoot =
    currentSourcePath().parentDir.parentDir.parentDir.parentDir
    ## `<checkout>/src/frontend/test_support/spec_documents.nim` →
    ## `<checkout>`.

  WorkspaceRoot = CheckoutRoot.parentDir
    ## The directory the sibling checkouts share.

  SpecsDirEnvVar = "CT_SPECS_DIR"
    ## An explicit `codetracer-specs` checkout to read instead of the
    ## workspace sibling — the same variable, with the same meaning, that
    ## `ci/test/shortcut-shadow-spec-agreement.sh` and
    ## `ci/test/editor-model-case-floor.sh` honour. It exists because the
    ## sibling directory is a SHARED checkout in a multi-repo workspace: it can
    ## sit on a branch from before `1735345d`, and a worktree under test has no
    ## business moving it. It is an override, not a fallback: when it is set,
    ## ONLY that checkout is read, and a document absent there is the same
    ## hard red as an absent sibling. An ABSOLUTE path. Read at COMPILE time, because
    ## `specDocument` is a `staticRead`; a suite is compiled and run in one
    ## environment by every lane and harness.

  SpecRepoRoot =
    when getEnv(SpecsDirEnvVar).len > 0: getEnv(SpecsDirEnvVar)
    else: WorkspaceRoot / SpecRepoDirName
    ## The specification checkout's root. **Deliberately not exported.**
    ## No caller needs it — the three procs below are the whole surface — and
    ## `ci/test/frontend-reachability.sh` counts an exported frontend symbol
    ## that nothing reaches, so exporting it put a finding on the ratchet in
    ## exchange for nothing. Its own allow-list refuses the usual excuse in as
    ## many words: *"'The test covers it.' That is the defect, not the
    ## exemption."*

  SpecDocumentRoot = SpecRepoRoot / SpecSubdir
    ## The absolute directory every published specification document is under.
    ## Not exported, for the reason above.

static:
  doAssert currentSourcePath().replace('\\', '/').endsWith(ThisModuleTail),
    "spec_documents.nim has moved. `CheckoutRoot` is derived by walking four " &
    "directories up from this file, so the walk has to be re-counted here. " &
    "currentSourcePath() is " & currentSourcePath()

func specDocumentPath*(relative: string): string =
  ## The absolute path of a published specification document, where `relative`
  ## names it from the specification tree's root — `"GUI/Editing-Operations-
  ## And-Keymaps.md"`, never `"spec/GUI/…"` and never a `..` segment.
  ##
  ## This does NOT check that the document is there. The caller's own
  ## hard-failing prerequisite check does, and keeps doing it.
  SpecDocumentRoot / relative

func specDocumentRef*(relative: string): string =
  ## How a published specification document is CITED in a message a person
  ## reads: `codetracer-specs/spec/GUI/Editing-Operations-And-Keymaps.md`, the
  ## spelling that can be pasted into a `git log` in the sibling checkout.
  SpecRepoDirName / SpecSubdir / relative

template specDocument*(relative: static string): string =
  ## A published specification document's TEXT, read at compile time.
  ##
  ## An absent document is a compile error from `staticRead` naming the
  ## absolute path — it is not a skip, not an empty string and not a warning.
  staticRead(specDocumentPath(relative))
