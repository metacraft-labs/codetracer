## The config schema accepts the shipped default config, and config files
## written by older releases.
##
## `loadConfig` reads a config file strictly against `ConfigObject`, and when
## the schema rejects a file it REPLACES the user's file with the default one.
## So removing a key from the shipped `default_config.yaml` is only safe while
## the schema still accepts the key in an existing file, and adding a key to
## the schema is only safe while an existing file that lacks it still loads.
##
## The `traceSharing` section is the case in point: the shipped default now
## carries only `enabled`, and a file from an older release still carries
## `baseUrl`, `downloadApi`, `deleteApi` and `getUploadUrlApi`.  Both must
## load.
##
## No mocks: each case parses real YAML text with the real loader
## (`parseConfig`, the parsing half of `loadConfig`).  `loadConfig` itself is
## not driven, because on a schema mismatch it would overwrite the config file
## in the developer's own `~/.config/codetracer`.

import std / [unittest, strutils]

import config

const shippedDefault = staticRead("../config/default_config.yaml")

proc withTraceSharing(body: string): string =
  ## The shipped default with its `traceSharing:` section replaced by `body`.
  var lines: seq[string] = @[]
  var skipping = false
  for line in shippedDefault.splitLines():
    if line.startsWith("traceSharing:"):
      skipping = true
      lines.add body.strip(leading = false)
      continue
    if skipping:
      if line.startsWith("  ") or line.len == 0:
        if line.len == 0:
          skipping = false
          lines.add line
        continue
      skipping = false
    lines.add line
  lines.join("\n")

suite "config schema — traceSharing":

  test "the shipped default carries no sharing-service URLs":
    check "traceSharing:" in shippedDefault
    for key in ["baseUrl", "downloadApi", "deleteApi", "getUploadUrlApi"]:
      check key notin shippedDefault

  test "the shipped default loads":
    let config = parseConfig(shippedDefault)
    check config.traceSharing.enabled
    check config.traceSharing.baseUrl == ""

  test "a config from an older release, with the legacy keys, still loads":
    let legacy = withTraceSharing("""
traceSharing:
  enabled: true
  baseUrl: "http://localhost:55504/api/codetracer/v1"
  downloadApi: "/download"
  deleteApi: "/delete"
  getUploadUrlApi: "/get/upload/url"
""")
    check "getUploadUrlApi" in legacy
    let config = parseConfig(legacy)
    check config.traceSharing.enabled
    check config.traceSharing.baseUrl == "http://localhost:55504/api/codetracer/v1"
    check config.traceSharing.deleteApi == "/delete"

  test "a config with traceSharing disabled and nothing else loads":
    let config = parseConfig(withTraceSharing("""
traceSharing:
  enabled: false
"""))
    check not config.traceSharing.enabled

  test "a key the schema does not know is still refused":
    # The strictness `loadConfig` relies on, kept honest: if this ever started
    # passing, the cases above would prove nothing.
    expect CatchableError:
      discard parseConfig(withTraceSharing("""
traceSharing:
  enabled: true
  notARealKey: 1
"""))
