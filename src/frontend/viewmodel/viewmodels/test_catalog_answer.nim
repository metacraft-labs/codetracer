## NOT-A-TEST-LANE-FILE: this is the Test Results pane's CATALOG ANSWER —
## production frontend code named after the tests it discovers, which is why
## its basename matches the guard's `test_*` name arm. It imports no
## `unittest` and declares no `suite`/`test` block. It is asserted by
## `src/frontend/viewmodel/tests/unit/test_plat53_test_results.nim`, which the
## `vm-unit` and `vm-unit-js` lanes run.

## viewmodels/test_catalog_answer.nim — which tests a project has, and when
## there is no answer, the sentence that says why.
##
## Spec: `GUI/Core-Panes/Test-Results-Pane.md` §8.2.
##
## ONE RULE, EVERY HOST. The desktop's main process answers
## `CODETRACER::ns9-panes` with it (`index/ns9_panes.nim`, over node's `fs`),
## and the terminal and the GPUI window answer their own Test Results pane
## with it (`host/native_test_host.nim`, over `std/os`). Each host does only
## what its platform must — say whether the marker file exists, and read the
## `.nr` sources under `src/` — and the decision of what the pane is told is
## made here, once. Until PLAT-53 it was written inline in `ns9_panes`, where
## a second front-end could only have copied it.
##
## The ORDER of the arms is the desktop's, and it is the order a user can act
## on: no folder at all, a folder that is not a Noir crate, a crate whose
## discovery failed, a catalog.
##
## Pure; C and JavaScript backends.

import ../../../ct_test/contracts
import ../../../ct_test/frameworks/noir_test_syntax
from ./no_project_folder import NoProjectFolderText

export contracts, NoirSourceFile, NoirProjectMarker

const
  NoTestProviderText* =
    "This project has no " & NoirProjectMarker & ", so CodeTracer has no " &
    "test provider for it yet. Noir is the first language wired into this " &
    "pane; the `ct test` framework already has providers for many more."
    ## A folder that is not a Noir crate. Not an error: a statement about
    ## which languages this pane has a provider for.
  DiscoveryFailedStem* = "Test discovery failed for this project: "
    ## A crate whose sources could not be read into a catalog; the reason
    ## follows.

type
  TestCatalogAnswer* = object
    ## What a host tells the pane: a catalog, or the reason there is none.
    hasCatalog*: bool
    catalog*: TestCatalog
    absence*: string
      ## "" when `hasCatalog`; installed as the pane's `runAbsence`.

  NoirSourcesReader* = proc(): seq[NoirSourceFile]
    ## Every readable `.nr` under the project's `src/`, named by its
    ## project-relative path with `/` separators. The host's walk; called only
    ## once the folder is known to be a crate.

proc testCatalogAnswer*(folder: string; hasMarker: bool;
                        sources: NoirSourcesReader): TestCatalogAnswer =
  ## The answer for `folder` (`hasMarker`: whether `<folder>/Nargo.toml`
  ## exists).
  if folder.len == 0:
    return TestCatalogAnswer(absence: NoProjectFolderText)
  if not hasMarker:
    return TestCatalogAnswer(absence: NoTestProviderText)
  try:
    result = TestCatalogAnswer(hasCatalog: true,
                               catalog: noirCatalogFromSources(sources()))
  except CatchableError:
    result = TestCatalogAnswer(absence: DiscoveryFailedStem &
                                        getCurrentExceptionMsg())
