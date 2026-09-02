## What THIS running renderer says it was built from, for the surfaces that
## show it to a user.
##
## ## Why this module exists at all
##
## `platform/web_deployment.nim` owns the identity as a VALUE — how it is
## spelled in `/build-id.txt`, how it is parsed back, and what a defective one
## is. None of that answers "what does the tab I am looking at say", because
## the answer lives in the entry document's descriptor and only the web boot
## sequence reads it. The two surfaces that show it (the welcome screen's
## version line and the status bar) are compiled for the desktop too and must
## not reach for a browser API to find out.
##
## So the boot sequence PUSHES the answer here once, and the surfaces PULL it.
## One assignment, in `ui_js.nim`'s web arm, immediately after `configure`.
##
## ## Why a module-level variable and not a field on a view model
##
## Because it is a property of the BUILD, not of any session, panel or
## document. Threading it through `WelcomeScreenVM` and `StatusShellModel`'s
## constructors would put a deployment constant into two reactive graphs that
## can never observe it change, and would make every existing constructor call
## site — including a dozen in the test suites — say something about a fact
## none of them are about. `StatusShellModel` still carries it as a field,
## because a view must stay a pure function of its model; what it does not do
## is carry it all the way back to the store.
##
## ## The empty identity is the desktop's correct answer
##
## Electron ships no deployment descriptor and never will: it is not served by
## anything. `buildIdentityLabel` answers "" for it and both surfaces render
## NOTHING for "" — not `build unknown`, not an empty element. The desktop DOM
## is therefore unchanged by this module's existence, which is what keeps the
## GUI suites that assert the status bar's shape honest.

import ./web_deployment

var displayed = BuildIdentity()

proc setDisplayedBuildIdentity*(identity: BuildIdentity) =
  ## Called once, by the boot sequence that read the descriptor.
  displayed = identity

proc displayedBuildIdentity*(): BuildIdentity =
  ## What to show, or the empty identity when this build does not know.
  displayed

proc displayedBuildLabel*(): string =
  ## `buildIdentityLabel` of the above — "" when there is nothing to show.
  buildIdentityLabel(displayed)

proc displayedBuildTitle*(): string =
  ## The long form for a `title=`, or "".
  buildIdentityTitle(displayed)

proc versionLineText*(version, buildLabel: string): string =
  ## The welcome screen's version line, with the deployed revision appended
  ## when there is one.
  ##
  ## A pure function of two strings so the composition is unit-testable without
  ## a DOM and without a global: the desktop case ("" label) must produce the
  ## byte-identical string it produced before this change, and that is an
  ## assertion rather than a hope.
  ##
  ## `·` rather than a second line or a parenthesis: the element it renders
  ## into is a single-line label with its own class, and this must not change
  ## the shape of the DOM around it.
  if buildLabel.len == 0: "Version " & version
  else: "Version " & version & " · " & buildLabel
