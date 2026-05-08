# `browser-replay` — Browser-Based MCR Replay Client

This directory contains the browser-side CodeTracer MCR replay
client. The client loads a CodeTracer trace into an in-memory
WebAssembly virtual filesystem and serves the standard CodeTracer
DAP/replay protocol from a Web Worker — letting users step through
a recorded trace inside their browser without launching a native
`ct host` process.

For the full design and milestone history, see
[`codetracer-specs/Planned-Work/Browser-Replay.status.org`](../../codetracer-specs/Planned-Work/Browser-Replay.status.org)
and
[`codetracer-specs/Planned-Work/Unified-Browser-Replay-Architecture.md`](../../codetracer-specs/Planned-Work/Unified-Browser-Replay-Architecture.md).

## Two trace-loading paths

The client supports two trace-loading paths:

### 1. Gateway-authenticated load (M40, production)

The client fetches the recording manifest and trace bytes through
codetracer-ci's authenticated browser-replay gateway endpoints:

- `GET /api/v1/observability/gateway/manifests/{traceId}` — manifest fetch.
- `GET /api/v1/observability/gateway/ranges/{traceId}/{**objectKey}` — byte fetch with HTTP Range.
- `POST /api/v1/observability/gateway/credential-validate` — precondition probe (optional).

This is the path used in production. Users get to a CodeTracer
debug session via a codetracer-ci debug-session URL; codetracer-ci
issues a short-lived bearer token tied to the user's
`replay.read` role on the trace's tenant; the browser-replay client
loads the trace through the gateway with that token.

The endpoint reference lives at
[`codetracer-ci/rewrite-docs/04-apis-events/http-api.md`](../../codetracer-ci/rewrite-docs/04-apis-events/http-api.md)
section 4.11. The data-path overview is in
[`codetracer-specs/Observability-Platform/docs/direct-storage-data-path.md`](../../codetracer-specs/Observability-Platform/docs/direct-storage-data-path.md).

### 2. Static-asset load (legacy, tests)

The client can also fetch a trace directly from a static HTTP
server. This path predates M40 and is used by the local nginx
test harness (`test-server.sh`, `nginx.conf`) for development
iteration on the WASM module itself.

## URL contract

The client reads its configuration from the URL query string. The
`gateway-authenticated load` path is selected when both
`gatewayBaseUrl` and `traceId` are set; the legacy static path is
selected otherwise.

```
https://<host>/index.html
  ?gatewayBaseUrl=https://codetracer.example.com
  &traceId=019e0744-31cf-7ad9-b350-f8d2e3eda5a2
  &authToken=<bearer-token>
```

Required query parameters for the gateway path:

- `gatewayBaseUrl` — the codetracer-ci base URL. The client
  appends `/api/v1/observability/gateway/manifests/{traceId}`
  and `/api/v1/observability/gateway/ranges/{traceId}/{**}` to it.
- `traceId` — the trace UUID to load.
- `authToken` — bearer token. Sent as
  `Authorization: Bearer <authToken>` on every fetch. Production
  deployments mint short-lived tokens server-side and inject them
  into the URL when redirecting users from a debug-session link.

Optional:

- `replicaIndex` (integer) — when the manifest exposes multiple
  replicas per shard, force the client to use a specific one.
  Defaults to `0`.

## Cross-origin and auth model

The gateway endpoints require user-bearer authentication and the
`replay.read` operation on the trace's tenant. The client sends
`Authorization: Bearer <authToken>` on every fetch. CORS preflights
are NOT required when the client is served from the same origin as
the gateway — the recommended deployment is a single nginx vhost
that serves both the static client assets and reverse-proxies to
codetracer-ci.

For end-to-end local testing without nginx, see
[`codetracer-ci/tests/CrossRepo.Test.Integration/BrowserReplayClientTests.cs`](../../codetracer-ci/tests/CrossRepo.Test.Integration/BrowserReplayClientTests.cs):
the cross-repo test mounts the `app/` bundle on the same port as
the gateway via `CrossRepoTestServer.MountStaticFiles`, so the
browser sees a single origin and Playwright can drive the whole
flow without CORS configuration.

## Files

| File                          | Purpose                                                                                                            |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `app/index.html`              | Thin scaffold; documents the URL contract; loads `gateway-client.js`.                                              |
| `app/gateway-client.js`       | Main-thread driver. Reads URL params; boots the worker; sends DAP `initialize` / `launch` / `configurationDone`.   |
| `app/worker.js`               | Web Worker that loads the WASM module. Two message types: `load-trace` (legacy static fetch) and `load-trace-from-gateway` (M40). |
| `app/pkg/db_backend.js`       | Generated wasm-bindgen JS bindings (rebuilt from `src/db-backend/wasm-testing/`).                                  |
| `app/pkg/db_backend_bg.wasm`  | Generated WASM module.                                                                                             |
| `nginx.conf`, `start-server.sh`, `stop-server.sh`, `setup-certs.sh` | Local nginx test harness for the legacy static-fetch path. Not used by the gateway-authenticated path.            |
| `test-server.sh`              | One-shot wrapper around the nginx harness.                                                                         |
| `traces/`                     | Hardcoded test traces for the legacy static path.                                                                  |

## Testing

The end-to-end test is
[`codetracer-ci/tests/CrossRepo.Test.Integration/BrowserReplayClientTests.cs`](../../codetracer-ci/tests/CrossRepo.Test.Integration/BrowserReplayClientTests.cs)
(`browser_replay_client_fetches_manifest_and_ranges_through_gateway`).

It:

1. Spins up a real `DistributedHttpStorageNode` Python subprocess.
2. Spins up a real `CrossRepoTestServer` with the real
   `BrowserGatewayEndpoints` route group and the real
   `IS3Provider` / `IObservabilityAuditSink`.
3. Stages real payload bytes onto the storage node and seeds a
   `ShardedMcrSegmentManifest` whose replica points at the node's
   HTTP base URL.
4. Mounts the `browser-replay/app/` bundle on the same origin as
   the gateway.
5. Launches headless Chromium via `Microsoft.Playwright`.
6. Navigates to
   `index.html?gatewayBaseUrl=...&traceId=...&authToken=...`.
7. Hard-asserts the manifest fetch returned `200`, at least one
   range fetch returned `206`, the storage node's `payloadReads`
   counter strictly increased (proves the gateway HTTP-proxied to
   the storage node), and the audit sink recorded
   `gateway.manifest.read` and `gateway.range.read` events with
   `status="allowed"`.

Run via:

```bash
cd codetracer-ci
nix develop ./nix -c dotnet test \
  tests/CrossRepo.Test.Integration/CrossRepo.Test.Integration.csproj \
  -c Release \
  --filter "FullyQualifiedName~BrowserReplayClientTests" \
  -p:NuGetAudit=false
```

## Building the WASM bundle

The `app/pkg/` directory is a build output and is `.gitignore`d.
Re-stage it from `src/db-backend/wasm-testing/pkg/` after building
the WASM module:

```bash
cd src/db-backend/wasm-testing
just build         # or: cargo build --target wasm32-unknown-unknown
cd -
cp -r src/db-backend/wasm-testing/pkg/* browser-replay/app/pkg/
```

`build-dist.sh` automates this for distribution-ready bundles.

## Known limitations

- Materialized traces (Python / Ruby / JavaScript): the M40 gateway
  endpoints serve materialized artifacts the same way as MCR shards
  (each artifact has an object key in the manifest), but the
  WASM-side replay engine for materialized traces is still in
  development. The client returns an `unsupported-backend` error
  message when handed a manifest with `kind=materialized_trace`
  for a runtime that hasn't shipped its replay engine yet.
- Token refresh: the URL-embedded `authToken` is short-lived and
  does NOT auto-refresh. Production deployments should mint
  long-enough tokens to cover an expected replay session, or wire
  in a refresh flow via the parent page.
