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

import json
from http.server import BaseHTTPRequestHandler, HTTPServer


def process_request(balance):
    # Helper kept intentionally trivial so the single-trace half of
    # the chain ends in a `TrivialCopy` hop into `balance` — the
    # M29 composer then crosses the HTTP boundary at the next hop.
    return balance


class BalanceHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/balance":
            self.send_error(404)
            return
        # The HTTP recorder boundary hook fires the
        # `boundary_id = "account-balance-with-wasm"` receive marker
        # here, paired with the frontend's send marker on the
        # X-Codetracer-Origin header value.
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length).decode("utf-8"))
        balance = payload["balance"]
        stored = process_request(balance)
        body = json.dumps({"stored": True, "value": stored}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    # Listen on 127.0.0.1:8080 — `frontend/vite.config.js` proxies
    # `/balance` here. `regenerate.sh` starts the server under the
    # codetracer recorder, drives one HTTP request through the
    # Vite-built frontend, then tears the server down.
    HTTPServer(("127.0.0.1", 8080), BalanceHandler).serve_forever()
