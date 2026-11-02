# Seam Register — the CodeTracer web-deployments local loop

**Status:** current as of the WD campaign (WD0–WD4, closed 2026-10-01) ·
**Owner:** whoever last changed `ci/test/web-front-door-local.sh` or
`src/frontend/index/`.

This is the register required by
[local-development-parity.md §4.1](../../metacraft-specs/infrastructure/local-development-parity.md).
It lists **the integration points this campaign's local loop does not exercise**.

The rule that gives it teeth: _an unlisted seam is an assumed-covered seam, and
those are the ones that fail in production._

This campaign supplies its own cautionary case, and it is the same shape as the
CIAM one §4.1 cites. Both ends of the facade endpoint were built — a 61-verb
dispatcher and a client satisfying all seven facades, 902 green assertions
between them — and **neither was connected to anything**. A running `ct host`
served no facade and its page installed a profile that claimed capabilities
every facade refused. Two suites were green throughout. The same session then
reproduced it in miniature: `sweepEgressCap` was written, tested and called by
nothing, so D-S14's egress cap was arithmetic rather than enforcement.

A row is closed only by a test that **crosses** the seam. "The client is
written" closes nothing.

---

## A. Closed by this campaign

| Seam | What crosses it now |
| --- | --- |
| The page reaches the facade dispatcher over a socket | `src/frontend/tests/facade_endpoint_over_socket_test.nim` — real `setupServer`, real socket.io, 70 checks. Deleting the `client.on` wiring leaves 1 check and 1 failure naming the cause |
| The client is constructed from what the server declared | `viewmodel/tests/unit/test_container_boot.nim` — a `welcome` installs a platform carrying the profile that ARRIVED, on both backends |
| The descriptor is one document delivered two ways | `index_serves_one_deployment_descriptor_test.nim` — compares the two documents to each other, not each to a shape |
| `ct host` serves the deployment's cache classes | `index_serves_deployment_cache_classes_test.nim` — headers on real responses, two probes in different classes |
| `ct host` reports the port it actually bound | `index_reports_the_port_it_bound_test.nim` — CONNECTS to the port the URL line named |
| The front door's fork, allow-list and headers | `ci/test/web-front-door-local.sh` — real pinned wrangler, real generated function, 16 checks |
| The image reaches a daemon's store and resolves | `ci/publish-host-image.sh`, run against a real Incus 6.0.6 |
| **`ct host` SERVING in a container, reached from OUTSIDE it** | `ci/test/host-image-serves-in-a-container.sh`, 10/10 against a real Incus 6.0.6 — the image launches, its init leases, `ct --version` runs, `/etc/passwd` resolves, the fixture trace imports through the image's own `ct import`, `ct host` auto-assigns and prints `CODETRACER_HOST_URL`, and the HOST gets `200` on `/` plus a `/deployment.json` answer over the bridge. The join WD1a, WD1c and WD2 were each half of. Graded in CI by `ct-host-container-gate` (codetracer.yml), which runs the publisher and then this gate inside a NixOS VM that is an Incus host (`ci/test/host-image-serves-in-incus-vm.sh`) |
| The published image BOOTS, networks, and runs `ct` | The probe in §B2 — container boots, `/run/isonim-net.status` = `ok`, `ct --version` answers, `ct host --help` shows `auto-assign; CODETRACER_HOST_PORT` |
| **The egress cap firing on a LIVE session** | isonim-platform `75bf80a` — `test_egress_cap_evicts_a_live_session`, 15/15 against a real Incus 6.0.6: a session emits traffic, the sweep reads the allocator's counter, the predicate fires, the session is evicted `egress_cap` and the container destroyed. Paired with a control under a 1 GB cap that must SURVIVE the same sweep |
| The session sweeps run on a clock | isonim-platform `3743125` — `substrate.runSessionSweeps` from the api-server's async loop every `ISONIM_SESSION_SWEEP_SECONDS`. Seam S44 closed, and D-S14's cap with it |

## B. Answered by the mechanism its policy names — not open

These read as open seams in an earlier revision of this file and they are not. A
seam is an integration point **nothing** crosses. These are crossed by the
mechanism their governing policy prescribes, and listing them beside genuine
gaps makes the register cry wolf — the one thing it cannot afford, because its
whole claim is that an unlisted seam is an assumed-covered one.

| Point | Why the local loop cannot cross it | What does |
| --- | --- | --- |
| **Edge cache isolation** — an authenticated render must never reach an anonymous visitor from a shared cache | There is no shared cache in a local loop, and `local-development-parity.md` §4 names this the property hardest to reproduce locally and **forbids** shipping on a green local run for it. A local crossing would be the mistake, not the fix | The `An authenticated render never enters the shared cache` step of `deploy-web-codetracer.yml`, on every deploy, against `ide.codetracer.com` |
| **The renderer on the pinned `isonim-tui`** — and, measured 2026-10-25, on the pinned `isonim` and `nim-everywhere` as well | **THREE repos deep, not one.** This row said `ISONIM_TUI_SRC` was enough; a local renderer-arm build on 2026-10-25 found it is the first of three, each failing only once the one before it is overridden: `isonim-tui` lacks `clusterDisplayWidth(cluster, ambiguous)` (`editor/selection.nim:658`), then `isonim` cannot iterate a `NativeSeq` from a generic instantiated elsewhere (`core/reconcile.nim:36`), then `isonim` needs `RawNondet` from a newer `nim-everywhere` (`core/clock.nim:63`). Each sibling's checkout sits on its `isonim-release` branch behind its own `agents`. `config.nims` gives no env override for `nim-everywhere` at all, so an override has to borrow a later hook (`CODETRACER_RESULTS_SRC`). This is workspace drift, already filed, not a product gap — but it is wider than this row claimed, and the practical consequence is that **the renderer half of `ci/test/noir-studio-signed-out.sh` cannot be run against CI's pinned siblings in this workspace**: a build with all three overridden carries two extra findings of its own (a `nim_everywhere/http` `fetch` the overridden `isonim` pulls in, and one visual-replay site whose classifier marker lands 26 lines above it, outside the 20-line window), so the gate reports 5 failures that belong to the overrides and not to the product. **Review re-attributed those five by name rather than by correlating two builds, 2026-10-27:** the first unclassified site's mangled JS symbol spells out the absolute path it was compiled from, and that path is the OVERRIDE checkout's `nim_everywhere/http` module rather than anything under `src/` here, and the second is a `visual_replay_client_factory` site whose nearest marker above it sits 26 lines away against a 20-line back-window. The remaining three are consequences of those two (the total, the visual-replay count, the per-surface sum). None is reachable from WD7's change, and the two sites WD7 adds classify correctly as `session-allocation`. **The three-repo error CHAIN above is the 2026-10-25 build's measurement and was NOT re-run by review** — `RawNondet` does not occur in either sibling checkout as it stands here, which is consistent with it living on a newer revision but is not a confirmation of it | CI's `renderer-electron` lane, which compiles `ui_js.nim` on the revision the flake pins — and, for the egress budget specifically, CI's own `test-noir-studio-signed-out` run. A local change to that budget can be checked only as a DELTA against a locally built baseline, which is what WD7 did: 14 sites before, 16 after, with the two new ones classified `session-allocation`, every other surface unmoved, and the same two override findings present in both runs |

## B1. Genuinely open — **two** rows, and only one of them is this campaign's

**Was "one row, and it is not this campaign's to close". Corrected 2026-10-23
by WD7**, which found a second open seam this register had asserted away by
omission: nothing in the product asks the substrate for a session.

**Narrowed 2026-10-25 by WD7's implementation, and NOT closed.** The allocation
call now exists on the request path; what is still uncrossed is the
OBSERVATION of it from the substrate's side, which is the only assertion
`Hosted-Session-Allocation.md` §5 accepts. The row below says which half is
which, because "the code is there" and "the substrate saw it" are different
claims and this register's whole value is in not letting the first stand in for
the second.

**And the two local gates measure different things, which review measured
rather than assumed.** `ci/test/wd7-loop-arm-allocates-nothing.sh` reads the
BUILT loop arm, so what it can see is the import graph: measured at the Oct-25
bundles, `web.js` carries **0** occurrences of `session95allocation`, of
`allocationRequestFor` and of the `CODETRACER_SESSION_ALLOCATION` marker, where
`ui.js` carries 42 and 3. That is a strong fact and it is the only fact that
gate has — **a change to the LOGIC inside `session_allocation.nim` is invisible
to it**, because the module is not in that bundle to be changed. Planting "a
static project allocates after all" reddens the in-process suite and leaves
both gates green, and that is correct rather than a gap: the import-graph half
and the builds-no-request half are independent reasons the substrate sees no
request from Noir Studio, and each has exactly one instrument. Do not read
either as covering the other.

| Seam | Where it stands | What compensates |
| --- | --- | --- |
| **The allocation call** — the product asks the substrate for a session, and the substrate is seen to have been asked | **Narrowed by WD7, 2026-10-25, and the two halves are stated separately on purpose.** _Built:_ `viewmodel/platform/session_allocation.nim` builds the request and reads the answer and performs no I/O; `ui/session_allocation_client.nim` carries the two HTTP calls (`GET /api/v1/apps/{project}/deployment.json`, then `POST /api/v1/projects/{project}/sessions`); `ui_js.nim` drives it from `entry.form == efProject`. The `(image, flavour)` pair is READ from WD4's descriptor, refusals are surfaced verbatim with their status, and `product_id` is deliberately absent from the body (**D-S13**: the product comes from the deployment, so `ide.codetracer.com` needs an api-server running `ISONIM_SESSION_PRODUCT=codetracer` — a DEPLOYMENT fact this register cannot check). _Proved:_ `test_session_allocation.nim`, **28 cases / 134 assertions** green on the C and JS backends at `ea66311ec` plus this change (review added five cases: the client module's own pure halves had no coverage at all, and one of them is `sessionStartFailureText`, the sentence a person actually reads), and `run-wd7-session-allocation-mutations.py` **8 arms, 8 killed, 0 survived, 0 harness-failure, with 2 behaviour-preserving controls green** — re-run by review in 1m27s, needle scan clean and the subject back at its recorded control digest afterwards. **Review planted two arms the implementation had not, and both were killed:** `allocationRequestFor` answering `some` for a static project, and an answer carrying no `ok` verdict reported as a refusal rather than as unreachable — the second caught by one of the five new cases, independently of the module's own. `ci/test/wd7-loop-arm-allocates-nothing.sh` is **7/7, re-run by review**: the Noir Studio arm has 0 egress sites and 0 markers, the planted arm the SAME scanner sees has 2 and 2, and the restore is proved by the nonce being absent from the tree while the same grep still finds it twice in the saved plant copy. `test_web_front_door.nim` (16) and `test_deployment_descriptor.nim` (12) are unchanged and green on both backends. _STILL OPEN:_ **nobody has watched a session appear in the substrate because `ide.codetracer.com` asked for one.** §5's `test_ide_codetracer_allocates_a_shared_session` is satisfied only by the substrate's view — _"a deployment that spawned its own container would serve a working IDE and pass every client-side check"_ — and that needs a running api-server with the platform database, a login session and a headless browser against a published bundle, none of which exists in a local loop. What WAS driven locally, at `isonim-platform` `04c078c` with a `sessionctl` whose compiled sources are identical at that revision: `image-resolve` refuses an invented reference by name (`no image '<ref>' in this substrate's image store`) and resolves a reference the store holds to a fingerprint, so the refusal discriminates rather than refusing everything. And the D-S13 control, re-run by review: the same `budget assess --customer gh-brill --meter session.flavour_seconds`, **naming no product in either request**, reads `product_id: isonim` with `ISONIM_SESSION_PRODUCT` unset and `product_id: codetracer` with it set — carrying DIFFERENT grants (`included` 360000 against 144000), which is why the product cannot be a request field. Those are the observer; nothing has yet made it observe a request the PRODUCT sent. **Measured on this host, 2026-10-27: no api-server is listening, and `incus project list` shows `default` and `isonim-dev` and no `isonim-sessions` — the substrate has never stood its container project up here, and the second front door D-S13 requires (`ISONIM_SESSION_PRODUCT=codetracer`) does not exist** | **Nothing compensates for the open half, and that is the row.** The closest thing is the construction gate above: if the Noir Studio arm carries no allocation and the allocation client carries no admission check, then a substrate that saw a request from Noir Studio did not get it from this bundle, and a refusal the UI shows was not invented here. Both narrow where §5's tests may fail; neither is one of them. The remaining work is an integration constellation, and it is SS-M9's meeting point — _"an isonim editor session and an `ide.codetracer.com` session, live, on the same substrate"_ — not another local arm |
| **Session TLS** — an allocated session reached over HTTPS | **Tracked in the owning plan, not dangling here.** `Shared-Services-Production.milestones.org` SS-M5 carries it: the allocation half is done (isonim-platform `b0b0ae8`, hostname derived from the session id, eight tests) and "what remains is the wildcard certificate and TLS termination". Its own executive summary lists the blocker among the things "nobody here can supply" — a wildcard certificate and DNS. Its verification is already written: _a session is allocated, reachable over TLS on its own hostname, and reclaimed_ | SS-M5, with the blocker named there. This row exists so a reader of THIS register is not surprised by it, and closing it is that campaign's to do once the certificate exists |

## B2. What the probe cost, and why it is in this file

The probe above was run because this register said "nothing crosses the join".
It found **two defects that every green check upstream had missed**, and both
are the register's own argument:

- **`codetracer-host`'s wrapper dropped `LD_LIBRARY_PATH`.** The desktop `ct`
  carries it because `.ct-wrapped` `dlopen`s openssl by SONAME; re-making the
  wrapper to repoint `CODETRACER_PREFIX` silently lost it. The package built,
  the image built, the publication imported and the substrate RESOLVED it —
  and the binary could not start, under any runtime. Nothing in that chain
  starts `ct`.
- **The converted image's init reported `no-lease` while the network worked.**
  Its route test was `| grep -q .`, carried over from the substrate's own init,
  and `grep` is not in this image. `dhcpcd.log` said `leased 10.159.161.115`
  and `ip route` showed the default route. That is exactly the "NIC, no lease"
  ambiguity the status file exists to remove, reintroduced by a test that
  depended on a binary the image does not carry.

- **The image shipped no `/etc/passwd`.** `dockerTools` does not write one,
  because an OCI runtime never asks who it is. node's `os.userInfo()` does,
  three layers down: `ct host` exited on `uv_os_get_passwd` ENOENT **before it
  listened**, after the two fixes above were already in. The substrate's own
  image writes a root-only passwd and group for exactly this reason, and the
  converter now does too.

None of the three is visible without starting the thing. That is what a seam is
— and the register found all three in one afternoon by naming one row "nothing
crosses this".

## C. Deliberately not a seam

**`-d:ctWeb`'s compile-time partition.** Deferred by decision 2026-10-01 with a
measurement, a removal condition and `ci/test/ctweb-partition-inventory.sh` as
its boundary — 13 branches across 7 files, which may shrink freely and may only
grow by editing an inventory somebody reads. It is a decision, not an untested
seam.
