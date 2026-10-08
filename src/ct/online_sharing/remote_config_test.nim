## Which address the client talks to, and which address it hands out.
##
## Two origins are in play for online sharing:
##
## * the **API base** — where every ``/api/v1/*`` call and the ``ct login``
##   sign-in page (``/auth/desktop``) go.  The default is
##   ``https://api.codetracer.com``; ``--base-url``,
##   ``CODETRACER_REMOTE_BASE_URL`` and ``remote.config`` override it, in that
##   order.
## * the **share base** — the origin of the link ``ct upload`` prints.  For
##   the default API base that is the product's web address,
##   ``https://ide.codetracer.com``; for an overridden base it is that base,
##   because a self-hosted deployment has no separate web origin.
##
## No mocks: every case runs the real resolver against a real
## ``remote.config`` file in a scratch directory and the real process
## environment.
##
## Run with:
##   LD_LIBRARY_PATH="$CT_LD_LIBRARY_PATH:$LD_LIBRARY_PATH" \
##     nim r --hints:off --warnings:off --mm:refc -d:ssl -d:useOpenssl3 \
##       src/ct/online_sharing/remote_config_test.nim

import std/[unittest, os, strutils]

import ./remote_config, ./artifact, ./authenticate, ./collab_invite_url

const SampleId = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"

let scratch = getTempDir() / ("ct-remote-config-test-" & $getCurrentProcessId())
removeDir(scratch)
createDir(scratch)

proc configWith(name: string, lines: seq[string]): RemoteConfig =
  let path = scratch / name / "remote.config"
  createDir(parentDir(path))
  if lines.len > 0:
    writeFile(path, lines.join("\n") & "\n")
  initRemoteConfig(path)

suite "online sharing — API base":

  setup:
    delEnv("CODETRACER_REMOTE_BASE_URL")
  teardown:
    delEnv("CODETRACER_REMOTE_BASE_URL")

  test "the default API base is api.codetracer.com":
    check DefaultBaseRemoteUrl == "https://api.codetracer.com"
    check configWith("empty", @[]).resolveBaseRemoteUrl() ==
      "https://api.codetracer.com"

  test "--base-url, then the environment, then remote.config override it":
    let conf = configWith("stored",
      @[RemoteUrlKey & "=https://stored.example.test"])
    check conf.resolveBaseRemoteUrl() == "https://stored.example.test"
    putEnv("CODETRACER_REMOTE_BASE_URL", "https://env.example.test")
    check conf.resolveBaseRemoteUrl() == "https://env.example.test"
    check conf.resolveBaseRemoteUrl("https://cli.example.test") ==
      "https://cli.example.test"

  test "ct login opens /auth/desktop on the API base":
    check authDesktopUrlFor(
      configWith("login", @[]).resolveBaseRemoteUrl(), 4242) ==
      "https://api.codetracer.com/auth/desktop?desktop-port=4242"
    check authDesktopUrlFor("https://ct.example.test/", 1) ==
      "https://ct.example.test/auth/desktop?desktop-port=1"

suite "online sharing — share links":

  test "the default API base issues links on ide.codetracer.com":
    check shareBaseUrlFor(DefaultBaseRemoteUrl) == "https://ide.codetracer.com"
    check shareLinkFor(DefaultBaseRemoteUrl, "acme", SampleId) ==
      "https://ide.codetracer.com/acme/" & SampleId & "/download"

  test "the default is recognised regardless of case and a trailing slash":
    check isDefaultBaseRemoteUrl("https://api.codetracer.com/")
    check isDefaultBaseRemoteUrl("HTTPS://API.CodeTracer.com")
    check shareBaseUrlFor("https://api.codetracer.com/") ==
      "https://ide.codetracer.com"
    check not isDefaultBaseRemoteUrl("http://api.codetracer.com")
    check not isDefaultBaseRemoteUrl("https://api.codetracer.com:8443")

  test "an overridden API base issues links on that base":
    check shareLinkFor("https://ct.example.test:8443/", "acme", SampleId) ==
      "https://ct.example.test:8443/acme/" & SampleId & "/download"
    check shareLinkFor("https://ide.codetracer.com", "acme", SampleId) ==
      "https://ide.codetracer.com/acme/" & SampleId & "/download"

  test "an issued link parses back to the same org and id":
    for base in [DefaultBaseRemoteUrl, "https://ct.example.test"]:
      let parsed = parseArtifactShareUrl(shareLinkFor(base, "acme", SampleId))
      check parsed.orgSlug == "acme"
      check parsed.artifactId == SampleId

suite "online sharing — links issued on the web address use the API base":

  test "an invite on ide.codetracer.com is exchanged through the default API base":
    let invite = parseCollabInviteUrl(
      "https://ide.codetracer.com/collab/join/token-1")
    check apiBaseUrlForWebOrigin(invite.baseUrl) == DefaultBaseRemoteUrl

  test "an invite on any other origin is exchanged through that origin":
    let invite = parseCollabInviteUrl(
      "http://127.0.0.1:5000/collab/join/token-2")
    check apiBaseUrlForWebOrigin(invite.baseUrl) == "http://127.0.0.1:5000"

removeDir(scratch)
