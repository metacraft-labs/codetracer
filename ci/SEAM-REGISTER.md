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

## B. Open seams — what the local loop does NOT reach

| Seam | Why it is open | What compensates |
| --- | --- | --- |
| **Edge cache isolation.** That an authenticated render can never be served from a shared cache to an anonymous visitor | There is no shared cache in the local loop. §4 names this as the property hardest to reproduce locally and forbids shipping on a green local run for it | The `An authenticated render never enters the shared cache` step of `deploy-web-codetracer.yml`, against `ide.codetracer.com`, on every deploy |
| **`ct host` SERVING inside a substrate-allocated session.** The server reachable on the container's own address | Probed 2026-10-01 against a real Incus 6.0.6, and four of the five steps now cross: the published image BOOTS as a container, its init leases an address and writes `/run/isonim-net.status` = `ok`, `/bin/ct` RUNS, and `ct host` starts and reaches its trace-loading stage with `--port` showing `auto-assign; CODETRACER_HOST_PORT`. The fifth is unproven: `ct host` requires a trace, and no fixture in this tree is in a form it accepts without an import step that wants a zip | Nothing for the last step. It is a FIXTURE gap rather than an integration one, and saying so is the point of this row — the probe is what turned "no test crosses the join" into one named step |
| **Session TLS.** An allocated session reached over HTTPS | `Hosted-Session-Allocation.md`: _"TLS termination under the wildcard is the other half and is not implemented; it needs DNS and an issuer"_ | Nothing. It is unimplemented, not untested |
| **The egress cap firing on a live session.** A session crossing its D-S14 cap and being evicted | `test_session_egress_policy.nim` proves the RULE and the ACL argv; `sessionctl sweep-egress` proves the verb runs. Nothing drives a session past a real cap | Nothing. The in-namespace half is `test_session_substrate.sh`'s territory and does not cover the cap |
| **The sweeps on a timer.** Both `sweep-idle` and `sweep-egress` exist as verbs and nothing calls them periodically | Pre-existing; recorded as isonim-platform seam S44, which the egress cap now joins | Nothing. A session abandoned by its browser, or one past its cap, is reclaimed only when someone runs the verb |
| **The renderer against the pinned `isonim-tui`.** `ui_js.nim` compiled on the revision the flake pins | The sibling checkout in this workspace is 31 commits behind and lacks `clusterDisplayWidth(cluster, ambiguous)`, so local compiles need `ISONIM_TUI_SRC` pointed at mainline | CI's `renderer-electron` lane, which uses the pin |

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

Neither is visible without starting the thing. That is what a seam is.

## C. Deliberately not a seam

**`-d:ctWeb`'s compile-time partition.** Deferred by decision 2026-10-01 with a
measurement, a removal condition and `ci/test/ctweb-partition-inventory.sh` as
its boundary — 13 branches across 7 files, which may shrink freely and may only
grow by editing an inventory somebody reads. It is a decision, not an untested
seam.
