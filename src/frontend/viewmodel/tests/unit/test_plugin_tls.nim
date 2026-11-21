## test_plugin_tls.nim — §8.1's Socket row over TLS, with REAL TLS
## connections (PLAT-8's open item: "no test opens a real TLS connection").
##
## The peer is a real `python3` TLS server (the standard library's `ssl`
## module over a real loopback socket) speaking the same length-prefixed
## framing from the other side. Its certificates are minted for each run by the
## real `openssl` command: a test CA, a leaf for `localhost`/`127.0.0.1` signed
## by it, a leaf for `wrong.example` signed by it, and a second CA nobody
## trusts. The plugin is a real `PluginContext` holding `socket:local`, and it
## connects through `connectTcp(tls = true)`, the call a plugin makes.
##
## WHAT IS NOT REACHED: a DNS NAME's check. A plugin may reach this machine
## only by loopback literal (`socket:local`); a name that resolves here cannot
## be declared as a host at all. So the server is reached as `127.0.0.1`, its
## certificate's IP entry is what is checked (`X509_VERIFY_PARAM_set1_ip_asc`),
## and the DNS arm (`SSL_set1_host`) is the same call site with the other
## setter, exercised by no local test.
##
## The one thing set for the test rather than found: `SSL_CERT_FILE`, which
## names the test CA as trusted — the same variable a user behind a corporate
## CA sets. It is not a stand-in: OpenSSL reads it exactly as it would in a
## user's session.
##
## Built with `-d:ssl -d:useOpenssl3` (its lane's flags); without them the TLS
## arm answers `ioUnsupported`, which the first case would report.

import std/[asyncdispatch, monotimes, os, osproc, strutils, tempfiles, times, unittest]

import codetracer_embed
import plugin_host/[host, plugin_io]
import plugin_fixtures/io_tool_plugin

var checks = 0
template ck(cond: untyped) =
  inc checks
  check cond

const ServerSource = """
import socket, ssl, struct, sys

cert, key, portfile = sys.argv[1], sys.argv[2], sys.argv[3]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
srv = socket.socket()
srv.bind(("127.0.0.1", 0))
srv.listen(8)
open(portfile, "w").write(str(srv.getsockname()[1]))
while True:
    raw, _ = srv.accept()
    try:
        conn = ctx.wrap_socket(raw, server_side=True)
    except (ssl.SSLError, OSError):
        raw.close()
        continue
    try:
        head = b""
        while len(head) < 4:
            chunk = conn.recv(4 - len(head))
            if not chunk:
                break
            head += chunk
        if len(head) == 4:
            n = struct.unpack(">I", head)[0]
            body = b""
            while len(body) < n:
                body += conn.recv(n - len(body))
            reply = body.upper() + b"|" + conn.version().encode()
            conn.sendall(struct.pack(">I", len(reply)) + reply)
    except (ssl.SSLError, OSError):
        pass
    conn.close()
"""

proc findOpenssl(): string =
  ## `OPENSSL_BIN`, else `openssl` on PATH, else one in the Nix store.
  result = getEnv("OPENSSL_BIN")
  if result.len > 0 and fileExists(result): return
  result = findExe("openssl")
  if result.len > 0: return
  for p in walkPattern("/nix/store/*-openssl-3*-bin/bin/openssl"):
    return p

proc run(cmd: seq[string]) =
  let (o, code) = execCmdEx(quoteShellCommand(cmd))
  doAssert code == 0, cmd.join(" ") & "\n" & o

type Pki = object
  dir, ca, otherCa, goodCert, goodKey, wrongCert, wrongKey: string

proc mintPki(openssl: string): Pki =
  ## A CA, two leaves it signs, and a second CA. Real certificates, made by
  ## the real tool, for this run only.
  let d = createTempDir("ct-plugin-tls-", "")
  result = Pki(dir: d, ca: d / "ca.pem", otherCa: d / "other-ca.pem",
               goodCert: d / "good.pem", goodKey: d / "good.key",
               wrongCert: d / "wrong.pem", wrongKey: d / "wrong.key")
  for (name, cn) in [("ca", "ct test CA"), ("other-ca", "an untrusted CA")]:
    run(@[openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days",
          "2", "-subj", "/CN=" & cn, "-keyout", d / (name & ".key"),
          "-out", d / (name & ".pem")])
  for (name, san) in [("good", "DNS:localhost,IP:127.0.0.1"),
                      ("wrong", "DNS:wrong.example")]:
    writeFile(d / (name & ".ext"), "subjectAltName=" & san & "\n")
    run(@[openssl, "req", "-newkey", "rsa:2048", "-nodes", "-subj",
          "/CN=" & name, "-keyout", d / (name & ".key"),
          "-out", d / (name & ".csr")])
    run(@[openssl, "x509", "-req", "-in", d / (name & ".csr"), "-CA", d / "ca.pem",
          "-CAkey", d / "ca.key", "-CAcreateserial", "-days", "2",
          "-extfile", d / (name & ".ext"), "-out", d / (name & ".pem")])

type Server = object
  process: Process
  port: int

proc startServer(cert, key: string): Server =
  let dir = createTempDir("ct-plugin-tls-srv-", "")
  writeFile(dir / "server.py", ServerSource)
  let portFile = dir / "port"
  result.process = startProcess("python3", args = ["-I", dir / "server.py",
    cert, key, portFile], options = {poUsePath, poStdErrToStdOut})
  let start = getMonoTime()
  while not fileExists(portFile) or readFile(portFile).len == 0:
    doAssert getMonoTime() - start < initDuration(seconds = 60),
      "the TLS server did not start"
    sleep(20)
  result.port = parseInt(readFile(portFile).strip)

proc stop(s: Server) =
  s.process.terminate()
  discard s.process.waitForExit()
  s.process.close()

proc tlsPlugin(id: string): IoProbePlugin =
  ## A plugin holding `socket:local`, activated in a real host.
  result = newIoProbePlugin()
  let host = newPluginHost(semver(1, 0, 0), initDuration(milliseconds = 250))
  let text = "{\"id\": \"" & id & "\", \"version\": \"1.0.0\", " &
    "\"activation\": [{\"event\": \"trace-opened\"}], " &
    "\"capabilities\": [\"socket:local\"]}"
  let parsed = parseManifest(text, id & ".json")
  doAssert parsed.isOk, renderAll(parsed.errors)
  let impl = result.implementation(parsed.manifest)
  discard host.register(text, id & ".json", impl.activate)
  host.resolveAll()
  discard host.activateFor(ActivationEvent(kind: aeTraceOpened))

proc exchange(p: IoProbePlugin; host: string; port: int): (SocketOutcome, string) =
  let c = waitFor p.attemptTlsConnect(host, port)
  if c.status != ioOk:
    return (c, "")
  let w = waitFor c.stream.writeFrame("hello over tls", frLengthPrefixed)
  doAssert w.status == ioOk, w.message
  let f = waitFor c.stream.readFrame(frLengthPrefixed)
  closeStream(c.stream)
  (c, (if f.status == ioOk: f.frame else: "read: " & f.message))

let openssl = findOpenssl()
doAssert openssl.len > 0, "the TLS suite needs the `openssl` command"
doAssert defined(ssl), "built without -d:ssl: run it in its lane"
let pki = mintPki(openssl)

suite "§8.1: TLS through connectTcp, against a real TLS server":

  test "a trusted certificate for the host: the handshake completes and frames cross":
    putEnv("SSL_CERT_FILE", pki.ca)
    let s = startServer(pki.goodCert, pki.goodKey)
    defer: s.stop()
    # By address: the certificate's IP entry is what is checked.
    let (c, reply) = tlsPlugin("acme.tls.ip").exchange("127.0.0.1", s.port)
    checkpoint c.message
    ck c.status == ioOk
    ck reply.startsWith("HELLO OVER TLS|TLSv1.")

  test "a certificate from a CA nobody trusts is refused":
    putEnv("SSL_CERT_FILE", pki.otherCa)
    let s = startServer(pki.goodCert, pki.goodKey)
    defer: s.stop()
    let (c, reply) = tlsPlugin("acme.tls.untrusted").exchange("127.0.0.1", s.port)
    checkpoint c.message
    ck c.status == ioFailed
    ck "certificate verify failed" in c.message.toLowerAscii or
          "verify" in c.message.toLowerAscii
    ck reply == ""

  test "a trusted certificate for ANOTHER name is refused":
    putEnv("SSL_CERT_FILE", pki.ca)
    let s = startServer(pki.wrongCert, pki.wrongKey)
    defer: s.stop()
    # The certificate chains to the trusted CA and names `wrong.example`, not
    # `127.0.0.1`. Before the name was bound (`plugin_io.expectPeerName`) this
    # handshake completed: `std/asyncnet` checks the chain only.
    let (c, reply) = tlsPlugin("acme.tls.wrongip").exchange("127.0.0.1", s.port)
    checkpoint c.message
    ck c.status == ioFailed
    ck reply == ""

  test "plaintext to a TLS server is not mistaken for TLS":
    putEnv("SSL_CERT_FILE", pki.ca)
    let s = startServer(pki.goodCert, pki.goodKey)
    defer: s.stop()
    let p = tlsPlugin("acme.tls.plain")
    let c = waitFor p.attemptConnect("127.0.0.1", s.port)
    ck c.status == ioOk
    discard waitFor c.stream.writeFrame("hello", frLengthPrefixed)
    let f = waitFor c.stream.readFrame(frLengthPrefixed)
    ck not (f.status == ioOk and f.frame.startsWith("HELLO|"))
    closeStream(c.stream)

removeDir(pki.dir)

echo "CHECKS: ", checks
