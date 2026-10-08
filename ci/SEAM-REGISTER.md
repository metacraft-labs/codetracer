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
| **`ct host` SERVING in a container, reached from OUTSIDE it** | `ci/test/host-image-serves-in-a-container.sh`, 10/10 against a real Incus 6.0.6 — the image launches, its init leases, `ct --version` runs, `/etc/passwd` resolves, the fixture trace imports through the image's own `ct import`, `ct host` auto-assigns and prints `CODETRACER_HOST_URL`, and the HOST gets `200` on `/` plus a `/deployment.json` answer over the bridge. The join WD1a, WD1c and WD2 were each half of |
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
| **The renderer on the pinned `isonim-tui`** | This workspace's sibling checkout is 31 commits behind and lacks `clusterDisplayWidth(cluster, ambiguous)`, so a local compile needs `ISONIM_TUI_SRC`. That is workspace drift, already filed, not a product gap | CI's `renderer-electron` lane, which compiles `ui_js.nim` on the revision the flake pins |

## B1. Genuinely open — one row, and it is not this campaign's to close

| Seam | Where it stands | What compensates |
| --- | --- | --- |
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
