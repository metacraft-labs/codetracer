# Cross-Tracer Origin E2E — Fixture A' "Account Balance with WASM"
# (Python aiohttp variant; three-tracer per
# Cross-Tracer-Origin-Test.audit.md § TCT-M4).
#
# This is the server side of the three-trace fixture: the WASM
# module on the frontend computed a balance from two JS-side source
# literals (userId=42, amount=100) and POST'd it here as JSON. The
# server stores the result in a local `balance` variable — the
# top of the three-trace value-origin chain documented in
# ../ANSWERS.md.
#
# Correlation: the aiohttp recorder's HTTP boundary hook auto-
# stamps the `X-Codetracer-Origin` header on incoming requests as
# a M25 receive marker under `boundary_id =
# "account-balance-with-wasm"`. The header value is the match key
# (the computed `balance`, rendered as decimal). No manual
# `# codetracer: recv ...` annotation is required in the body of
# `balance_handler` — the boundary auto-marker covers this.
#
# Per spec §14.3 + § 4 of Correlation-Markers.md, the M29 composer
# walks from `balance` → the receive marker (boundary crossing into
# the WASM trace) → the WASM `compute_balance` return value →
# (recursively, per TCT-M3) the WASM call-site in the JS trace →
# the `userId = 42` + `amount = 100` source-line literals. Two
# terminal leaves, one chain.

from aiohttp import web


async def process_request(balance):
    # Helper kept intentionally trivial so the single-trace half of
    # the chain ends in a `TrivialCopy` hop into `balance` — the
    # M29 composer then crosses the HTTP boundary at the next hop.
    return balance


async def balance_handler(request):
    # The aiohttp recorder's HTTP boundary hook fires the
    # `boundary_id = "account-balance-with-wasm"` receive marker
    # here, paired with the frontend's send marker on the
    # X-Codetracer-Origin header value.
    payload = await request.json()
    balance = payload["balance"]
    stored = await process_request(balance)
    return web.json_response({"stored": True, "value": stored})


def make_app():
    app = web.Application()
    app.router.add_post("/balance", balance_handler)
    return app


if __name__ == "__main__":
    # Listen on 127.0.0.1:8080 — `frontend/vite.config.js` proxies
    # `/balance` here. `regenerate.sh` starts the server under the
    # codetracer recorder, drives one HTTP request through the
    # Vite-built frontend, then tears the server down.
    web.run_app(make_app(), host="127.0.0.1", port=8080)
