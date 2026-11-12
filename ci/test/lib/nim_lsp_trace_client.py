#!/usr/bin/env python3
"""Ask a Nim language server to trace a static block, the way the desktop does.

    nim_lsp_trace_client.py <language-server> <file.nim> <line> <character>

Starts the language server over stdio with no arguments (as the desktop's LSP
bridge spawns it), answers its `workspace/configuration` request with nothing
for the `nim` section (the desktop names no `nimsuggestPath`), opens the file,
and sends `workspace/executeCommand nim/traceStaticBlock` at the 0-based
position. Prints the answer as one JSON line and exits 0 only when the answer
names a recording that exists.

Which nimsuggest the server runs is decided by the environment this script is
started in (`CODETRACER_NIMSUGGEST`, `PATH`); that is the thing under test.
"""

import json
import os
import pathlib
import subprocess
import sys
import threading
import time

TIMEOUT_S = float(os.environ.get("CT_NIM_LSP_TIMEOUT", "240"))


def main() -> int:
    server, source, line, character = sys.argv[1:5]
    source = str(pathlib.Path(source).resolve())
    uri = pathlib.Path(source).as_uri()
    stderr_log = open(os.environ.get("CT_NIM_LSP_STDERR", os.devnull), "wb")
    proc = subprocess.Popen(
        [server], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=stderr_log, cwd=str(pathlib.Path(source).parent))

    lock = threading.Lock()
    responses: dict = {}
    messages: list = []

    def send(msg: dict) -> None:
        body = json.dumps(msg).encode()
        with lock:
            proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
            proc.stdin.flush()

    def reader() -> None:
        out = proc.stdout
        while True:
            length = None
            while True:
                header = out.readline()
                if not header:
                    return
                header = header.strip()
                if not header:
                    break
                if header.lower().startswith(b"content-length:"):
                    length = int(header.split(b":", 1)[1])
            if length is None:
                continue
            msg = json.loads(out.read(length))
            if "method" in msg and "id" in msg:
                # A request from the server. The desktop answers
                # `workspace/configuration` with nothing for `nim`.
                if msg["method"] == "workspace/configuration":
                    items = msg.get("params", {}).get("items", [])
                    send({"jsonrpc": "2.0", "id": msg["id"],
                          "result": [None for _ in items] or [None]})
                else:
                    send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
            elif "id" in msg:
                responses[msg["id"]] = msg
            else:
                messages.append(msg)

    threading.Thread(target=reader, daemon=True).start()
    deadline = time.monotonic() + TIMEOUT_S

    def request(id_: int, method: str, params: dict) -> dict:
        send({"jsonrpc": "2.0", "id": id_, "method": method, "params": params})
        while id_ not in responses:
            if time.monotonic() > deadline or proc.poll() is not None:
                raise SystemExit(f"no answer to {method} (server rc={proc.poll()})")
            time.sleep(0.05)
        return responses[id_]

    request(1, "initialize", {
        "processId": os.getpid(),
        "rootUri": pathlib.Path(source).parent.as_uri(),
        "capabilities": {"workspace": {"configuration": True},
                         "window": {"workDoneProgress": True}},
    })
    send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
    send({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": uri, "languageId": "nim", "version": 1,
                         "text": pathlib.Path(source).read_text()}}})

    def initialized() -> bool:
        return any(m.get("method") == "window/showMessage" and
                   "Nimsuggest initialized" in m["params"].get("message", "")
                   for m in list(messages))

    while not initialized():
        if time.monotonic() > deadline or proc.poll() is not None:
            print(json.dumps({"error": "nimsuggest never initialized",
                              "rc": proc.poll()}))
            return 1
        time.sleep(0.1)

    answer = request(2, "workspace/executeCommand", {
        "command": "nim/traceStaticBlock",
        "arguments": [{"uri": uri, "line": int(line), "character": int(character)}],
    })
    print(json.dumps(answer.get("result") or answer.get("error")))
    try:
        request(3, "shutdown", {})
        send({"jsonrpc": "2.0", "method": "exit"})
        proc.wait(timeout=10)
    except (SystemExit, subprocess.TimeoutExpired):
        proc.kill()
    result = answer.get("result") or {}
    trace = result.get("tracePath", "") if isinstance(result, dict) else ""
    return 0 if trace and os.path.isfile(trace) else 1


if __name__ == "__main__":
    sys.exit(main())
