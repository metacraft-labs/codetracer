## repro.nim — the siblings codetracer's tests run against.
##
## This is a project of its own, nested in codetracer, with its own
## `repro.lock`. It pins the scenario runner and its backends
## (DemoVideoScript, DemoVideoScript-TermAssert, DemoVideoScript-GuiAssert,
## DemoVideoScript-Playwright) and what they bring: TermAssert,
## TermAssertClient, nim-libvterm, nim-pty and GuiAssert.
##
## They are kept out of codetracer's own `repro.lock` on purpose. That lock is
## refreshed on every push from `repro.nim`, which names only what the product
## is built from, so the refresh drops any sibling a build does not use. Each
## time it did, every scenario job stopped before its first scenario. This lock
## is refreshed by hand, here, when a test pin moves.
##
## Consumers:
##   * `.github/actions/provision-repro-lock-siblings` (`test-siblings`) runs
##     `repro develop` in this directory, so CI clones these siblings at the
##     revisions this lock pins;
##   * `ci/test/scenarios.sh` builds the runner and backends from the checkouts
##     next to codetracer, and warns when one is at another revision;
##   * `ci/test/sibling-provisioning-test.sh` checks this lock against both.
##
## To move a pin: check the sibling out at the new revision next to codetracer
## (a published commit: CI clones it), run `repro lock refresh .` in this
## directory, and commit the lock. A sibling both locks pin (nim-pty, which `ct`
## also builds from) moves in both at once; the provisioning test holds them
## equal.
import repro_project_dsl

package codetracer_test_siblings:
  defaultToolProvisioning "path"
  uses:
    "DemoVideoScript-TermAssert"
    "DemoVideoScript-GuiAssert"
    "DemoVideoScript-Playwright"
    # Cloned by a workflow at an explicit ref; declared so a lock names it.
    "codetracer-cairo-recorder"
    "codetracer-cardano-recorder"
    "codetracer-circom-recorder"
    "codetracer-flow-recorder"
    "codetracer-fuel-recorder"
    "codetracer-leo-recorder"
    "codetracer-miden-recorder"
    "codetracer-move-recorder"
    "codetracer-php-recorder"
    "codetracer-polkavm-recorder"
    "codetracer-solana-recorder"
    "codetracer-ton-recorder"
    "codetracer-flame-demo"
    "codetracer-pm"
    "codetracer-visual-replay-fixtures"
    "test-certificates-spec"
    "codetracer-example-recordings"
  build:
    # Nothing is built here: the siblings are consumed as source by the test
    # lanes. A package with no `build:` block is not solved, so the lock would
    # record nothing.
    discard
