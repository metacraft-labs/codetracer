## Canonical-payload rules the conformance vectors deliberately do not cover.
##
## ``test-certificates-spec/vectors/README.md`` names its own gaps, and one of
## them is structural: *"Rejection cases as a group. Malformed records appear
## only where a decision depends on them. There is no systematic 'these records
## MUST be rejected' group yet."* The vectors are therefore a suite of things
## that must **work**; this file is the suite of things that must **not**.
##
## It also pins the two byte-level traps the standard spends the most prose on,
## from the serializer's side rather than through a vector, so a regression
## names the rule directly instead of naming a case id.
##
## NO MOCKS: every case here is a pure function over a value.

import std/[options, strutils, unittest]

import certificate

proc minimal(): TestCertificate =
  TestCertificate(
    schema: CertificateSchema,
    framework: "ct-test", project: "example", platform: "linux/amd64",
    targets: @["t-unit"], result: "passed",
    issuedAt: "2026-06-23T10:14:33Z", issuer: "ct-test@host",
    vcs: VcsState(repo: "example",
                  content: "git-tree-sha1:9f8e7d6c5b4a3928170695e4d3c2b1a099887766",
                  untracked: false),
    commands: @[@["ct", "test", "run"]])

suite "canonical payload — rules with no vector":

  test "byte order is not collation, not UTF-16 code units, not the escaping":
    ## The three orders Canonical-Payload.md §3 says the sort is *not*, each of
    ## which is some language's default.
    # Collation would fold case and put `Zebra` next to `zebra`; byte order
    # puts every capital ahead of every lowercase.
    check compareBytes("t-Zebra", "t-zebra") < 0
    # A character above the BMP encodes in UTF-16 as a surrogate pair starting
    # D800–DBFF, which compares BELOW E000–FFFF — reversing this pair. In UTF-8
    # bytes, F0… is above EF….
    check compareBytes("t-\u{1F600}", "t-Ａ") > 0
    # And sorting must happen on the raw value, before escaping: TAB is 0x09
    # and sorts below '!' (0x21), while its rendering `\t` starts with 0x5C and
    # would sort above it.
    check compareBytes("t-a\tb", "t-a!b") < 0
    check compareBytes("t-a\\tb", "t-a!b") > 0
    check sortedDeduplicated(["t-a!b", "t-a\tb"]) == @["t-a\tb", "t-a!b"]

  test "no Unicode normalization is applied anywhere":
    ## A precomposed é (U+00E9) and a decomposed e + U+0301 are different
    ## values: not folded, not deduplicated against each other, and sorted by
    ## their bytes like anything else. Normalizing would silently change what a
    ## signature covers (Canonical-Payload.md §4).
    let precomposed = "t-é"
    let decomposed = "t-é"
    check precomposed != decomposed
    let sorted = sortedDeduplicated([precomposed, decomposed])
    check sorted.len == 2
    check sorted == @[decomposed, precomposed]

  test "only the seven escapes in the table are ever produced":
    check escapeBasicString("a\\b") == "a\\\\b"
    check escapeBasicString("a\"b") == "a\\\"b"
    check escapeBasicString("a\nb") == "a\\nb"
    check escapeBasicString("a\rb") == "a\\rb"
    check escapeBasicString("a\tb") == "a\\tb"
    check escapeBasicString("a\bb") == "a\\bb"
    check escapeBasicString("a\fb") == "a\\fb"
    # `/` is an ordinary character. A JSON encoder MAY escape it, producing
    # `linux\/amd64` — valid JSON, invalid here, and a different signature.
    check escapeBasicString("linux/amd64") == "linux/amd64"
    # Non-ASCII is emitted literally as UTF-8, never as \uXXXX.
    check escapeBasicString("pröjekt-日本語-😀") == "pröjekt-日本語-😀"
    check "\\u" notin escapeBasicString("日本語")

  test "a control character with no escape has no canonical form":
    ## A TOML basic string cannot carry a raw control character and the table
    ## defines no escape for the ones it omits, so such a value is not
    ## representable and a producer MUST NOT emit one. Inventing an escape
    ## would be a repair, which §5 forbids.
    check isRepresentable("ordinary")
    check isRepresentable("tab\there")
    for forbidden in ["\x00", "\x01", "\x0B", "\x1F", "\x7F"]:
      check not isRepresentable("value" & forbidden)
      var cert = minimal()
      cert.issuer = "ct-test" & forbidden
      expect CertificateError:
        discard canonicalPayload(cert)

  test "a certificate covering nothing, or recording nothing, is not renderable":
    var noTargets = minimal()
    noTargets.targets = @[]
    expect CertificateError:
      discard canonicalPayload(noTargets)

    var noCommands = minimal()
    noCommands.commands = @[]
    expect CertificateError:
      discard canonicalPayload(noCommands)

    # An empty *argv* describes no command; an empty *argument* is an ordinary
    # argument and is fine.
    var emptyArgv = minimal()
    emptyArgv.commands = @[newSeq[string]()]
    expect CertificateError:
      discard canonicalPayload(emptyArgv)
    var emptyArgument = minimal()
    emptyArgument.commands = @[@["ct", "test", "--selector", ""]]
    check "argv = [\"ct\", \"test\", \"--selector\", \"\"]" in
          canonicalPayload(emptyArgument)

  test "the record carries no commit, clean or worktree":
    ## The 2026-10-09 revision: `[certificate.vcs]` is `repo`, `paths`,
    ## `content`, `untracked`, `base` — in that order — and nothing of the
    ## earlier draft. `base` is omitted when absent, never emitted as `""`
    ## (Canonical-Payload.md §2 rules 9-11).
    let unbased = canonicalPayload(minimal())
    check "\n[certificate.vcs]\nrepo = \"example\"\n" &
          "content = \"git-tree-sha1:9f8e7d6c5b4a3928170695e4d3c2b1a099887766\"\n" &
          "untracked = false\n\n[[certificate.command]]\n" in unbased
    check "base" notin unbased
    for earlier in ["commit", "clean", "worktree", "tree =", "patch_digest"]:
      check earlier notin unbased

    var based = minimal()
    based.vcs.base = "a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4"
    based.vcs.paths = @["src/z", "Cargo.lock", "src/z"]
    let payload = canonicalPayload(based)
    # `paths` sits between `repo` and `content`; `base` is LAST.
    check "repo = \"example\"\npaths = [\"Cargo.lock\", \"src/z\"]\n" &
          "content = \"git-tree-sha1:9f8e7d6c5b4a3928170695e4d3c2b1a099887766\"\n" &
          "untracked = false\n" &
          "base = \"a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4\"\n\n" in payload
    # `base` is covered by the signature like everything else: a different
    # base is a different payload.
    check payload != unbased

    # `content` is emitted VERBATIM (rule 9): the serializer does not split,
    # re-case or validate it — a malformed id is the verifier's finding.
    var uppercase = minimal()
    uppercase.vcs.content = "git-tree-sha1:9F8E"
    check "content = \"git-tree-sha1:9F8E\"\n" in canonicalPayload(uppercase)

    # But a record with no content binds nothing and has no canonical form.
    var unbound = minimal()
    unbound.vcs.content = ""
    expect CertificateError:
      discard canonicalPayload(unbound)

  test "an unsigned record omits key_id rather than emitting it empty":
    ## An omitted key and an empty key are different payloads
    ## (Canonical-Payload.md §2 rule 3), so this is a signature difference and
    ## not a cosmetic one.
    let unsigned = canonicalPayload(minimal())
    check "key_id" notin unsigned
    var signed = minimal()
    signed.keyId = "ct-test-2026-q3"
    let signedPayload = canonicalPayload(signed)
    check "key_id = \"ct-test-2026-q3\"\n" in signedPayload
    check signedPayload != unsigned
    # And it is last in [certificate], after issuer.
    check signedPayload.find("issuer =") < signedPayload.find("key_id =")

  test "the payload ends with exactly one newline and has no trailing whitespace":
    let payload = canonicalPayload(minimal())
    check payload.endsWith("\n")
    check not payload.endsWith("\n\n")
    check "\r" notin payload
    for line in payload.split('\n'):
      check line == line.strip(leading = false, trailing = true)

  test "the signature block is excluded from the payload but present on disk":
    ## A signature cannot cover itself (Canonical-Payload.md §2), and both
    ## spellings of "unsigned" mean the same thing (§6).
    var cert = minimal()
    cert.keyId = "ct-test-2026-q3"
    cert.signature = CertificateSignature(algorithm: "ed25519", value: "QUJD")
    let payload = canonicalPayload(cert)
    check "[certificate.signature]" notin payload
    let document = renderCertificate(cert)
    check "[certificate.signature]" in document
    check document.startsWith(payload)
    check cert.isSigned

    var emptyBlock = minimal()
    emptyBlock.signature = CertificateSignature(algorithm: "", value: "")
    check not emptyBlock.isSigned
    check "[certificate.signature]" notin renderCertificate(emptyBlock)

suite "reading a certificate back":

  test "a record missing a required field is malformed, not unknown-schema":
    ## The two are different failures and a verifier MUST distinguish them
    ## (Standard.md §7): a missing v1 field is decidably invalid, while an
    ## unimplemented schema version may be a perfectly good certificate.
    let document = renderCertificate(minimal())
    check readCertificate(document).status == crsOk

    let withoutIssuer = document.replace("issuer = \"ct-test@host\"\n", "")
    let read = readCertificate(withoutIssuer)
    check read.status == crsMalformed
    check "issuer" in read.detail

    let future = document.replace(CertificateSchema, "test-certificate.v2")
    let futureRead = readCertificate(future)
    check futureRead.status == crsUnknownSchema
    check futureRead.schema == "test-certificate.v2"

  test "an earlier-draft record is malformed, named as such, and not translated":
    ## A record `ct test` issued before the revision: `commit` + `clean`, no
    ## `content`. Decidably invalid (Canonical-Payload.md §7.1) — never
    ## unknown-schema, since the schema id did not change — and the reader
    ## says what it is and what to do, rather than only "a field is missing".
    ## No content is filled in from anything.
    let earlier = renderCertificate(minimal()).replace(
      "content = \"git-tree-sha1:9f8e7d6c5b4a3928170695e4d3c2b1a099887766\"\n",
      "commit = \"a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4\"\nclean = true\n")
    require "commit = " in earlier
    let read = readCertificate(earlier)
    check read.status == crsMalformed
    check read.earlierDraft
    check "earlier-draft" in read.detail
    check "run the tests" in read.detail
    check read.cert.vcs.content.len == 0

    # The dirty earlier-draft spelling is the same verdict.
    let dirtyEarlier = earlier.replace("clean = true\n", "clean = false\n") &
      "\n[certificate.vcs.worktree]\ntree = \"9f8e7d6c\"\n"
    check readCertificate(dirtyEarlier).earlierDraft

    # A record merely missing `content`, with nothing of the earlier draft,
    # is malformed but is not called an earlier draft.
    let bare = renderCertificate(minimal()).replace(
      "content = \"git-tree-sha1:9f8e7d6c5b4a3928170695e4d3c2b1a099887766\"\n", "")
    let bareRead = readCertificate(bare)
    check bareRead.status == crsMalformed
    check not bareRead.earlierDraft
    check "vcs.content" in bareRead.detail

    # The current shape reads, with `base` intact and verbatim.
    var based = minimal()
    based.vcs.base = "cc11223344556677889900aabbccddeeff001122"
    let current = readCertificate(renderCertificate(based))
    check current.status == crsOk
    check not current.earlierDraft
    check current.cert.vcs.base == based.vcs.base
    check canonicalPayload(current.cert) == canonicalPayload(based)

  test "an empty base is refused on read, never silently dropped":
    ## Canonical-Payload.md §2 rule 10: an absent `base` is OMITTED. One
    ## present and empty names no commit, and rebuilding the payload from the
    ## fields would drop a key the signer saw.
    let document = renderCertificate(minimal()).replace(
      "untracked = false\n", "untracked = false\nbase = \"\"\n")
    let read = readCertificate(document)
    check read.status == crsMalformed
    check "base" in read.detail

  test "records with no canonical form are rejected on read, signed or not":
    ## Canonical-Payload.md §4: a value carrying a control character the escape
    ## table cannot express "has no canonical form", and "a verifier
    ## encountering one MUST reject the record as malformed rather than invent
    ## an escape for it".
    ##
    ## The check lives in ``readCertificate`` rather than beside the signature
    ## verification, and that placement is the point. It used to run only when
    ## a signature was being checked, so an *unsigned* unrepresentable record
    ## read as valid and went on to contribute coverage. Which rules apply to a
    ## record must not depend on the consumer's signature policy.
    let good = renderCertificate(minimal())
    require readCertificate(good).status == crsOk

    # Raw control characters, in three different fields.
    for injected in ["\x01", "\x0B", "\x7F"]:
      let inIssuer = good.replace("issuer = \"ct-test@host\"",
                                  "issuer = \"ct-test" & injected & "\"")
      checkpoint "issuer carrying byte " & $uint8(injected[0])
      check readCertificate(inIssuer).status == crsMalformed
      let inTarget = good.replace("targets = [\"t-unit\"]",
                                  "targets = [\"t-unit" & injected & "\"]")
      checkpoint "target carrying byte " & $uint8(injected[0])
      check readCertificate(inTarget).status == crsMalformed

    # The same characters arriving as \uXXXX escapes, which a verifier MUST
    # accept on input — and must then reject for the same reason.
    let escaped = good.replace("issuer = \"ct-test@host\"",
                               "issuer = \"ct-test\\u0001\"")
    check readCertificate(escaped).status == crsMalformed

    # An empty argv describes no command (Canonical-Payload.md §2 rule 7).
    let noArgv = good.replace("argv = [\"ct\", \"test\", \"run\"]", "argv = []")
    let noArgvRead = readCertificate(noArgv)
    check noArgvRead.status == crsMalformed
    check "command" in noArgvRead.detail

  test "the reader survives hostile input rather than the process dying":
    ## Certificates travel in git notes, which anyone with push access can
    ## rewrite (Transport.md §2), so this parser reads attacker-controlled
    ## bytes. ``parseArray`` and ``parseValue`` are mutually recursive; without
    ## a depth bound, a wall of ``[`` overflows the C stack — reported as
    ## "call depth limit reached" in a debug build, and as a **SIGSEGV** in the
    ## ``-d:release`` build `ct` ships.
    let bomb = "schema = " & repeat('[', 200_000)
    expect TomlError:
      discard parseTomlSubset(bomb)
    # And through the front door a reader actually uses, it is an ordinary
    # malformed verdict rather than a crash.
    check readCertificate(bomb).status == crsMalformed

    # The bound is generous, not tight: nothing a certificate legitimately
    # contains comes near it.
    check parseTomlSubset("k = " & repeat('[', 8) & repeat(']', 8)) != nil

  test "a table cannot be defined twice, by header or by dotted key":
    ## TOML forbids both spellings. Accepting either would let one document
    ## express the same field twice with different values, leaving the verifier
    ## to pick one silently.
    expect TomlError:
      discard parseTomlSubset("[a]\nx = \"1\"\n[a]\ny = \"2\"\n")
    expect TomlError:
      discard parseTomlSubset("[c]\nvcs.repo = \"x\"\n[c.vcs]\ncommit = \"y\"\n")
    expect TomlError:
      discard parseTomlSubset("k = \"1\"\nk = \"2\"\n")
    # Defining a super-table AFTER its sub-table is legal, and
    # `vectors/payload/escapes/received.toml` relies on it.
    check parseTomlSubset("[a.b]\nx = \"1\"\n[a]\ny = \"2\"\n") != nil

  test "inline tables and multi-line strings are read only where opted into":
    ## A certificate may be rendered with any TOML spelling of its fields
    ## (Canonical-Payload.md §5), and the standard's store vectors use inline
    ## tables and multi-line strings. The certificate reader enables both; the
    ## base subset — what a key store or a project definition is read with —
    ## still refuses them.
    let inline = "t = { a = \"1\", b.c = [\"x\"] }\n" &
                 "arr = [ { argv = [\"p\"] }, { argv = [\"q\"] } ]\n"
    expect TomlError:
      discard parseTomlSubset(inline)
    let parsed = parseTomlSubset(inline, {teInlineTables})
    check parsed.field("t").strField("a") == "1"
    check parsed.field("t").field("b").strSeqField("c") == @["x"]
    check parsed.field("arr").items.len == 2
    check parsed.field("arr").items[1].strSeqField("argv") == @["q"]

    let multiline = "a = \"\"\"x\"\"\"\n" &
                    "b = \"\"\"\nline\\\n   joined\\u0041\"\"\"\"\n" &
                    "c = '''\r\nraw\\n\r\nend'''\n"
    expect TomlError:
      discard parseTomlSubset(multiline)
    let strings = parseTomlSubset(multiline, {teMultilineStrings})
    check strings.strField("a") == "x"
    # The newline after the opening delimiter is trimmed, a line-ending
    # backslash joins lines, escapes apply, and a fourth quote is content.
    check strings.strField("b") == "linejoinedA\""
    # Literal: no escapes, and CRLF reads as LF.
    check strings.strField("c") == "raw\\n\nend"

    # TOML 1.0's limits on inline tables hold: complete as written, one line,
    # no trailing comma — and a value array cannot be appended to by a header.
    for refused in ["t = { a = \"1\" }\n[t]\nb = \"2\"\n",
                    "t = { a = \"1\" }\nt.b = \"2\"\n",
                    "t = { a = \"1\", }\n",
                    "t = { a = \"1\",\n b = \"2\" }\n",
                    "t = { a = \"1\", a = \"2\" }\n",
                    "c = [ { argv = [\"p\"] } ]\n[[c]]\nargv = [\"q\"]\n"]:
      checkpoint refused
      expect TomlError:
        discard parseTomlSubset(refused, {teInlineTables})
    # Without the extension, a value array still cannot be appended to.
    expect TomlError:
      discard parseTomlSubset("c = [\"p\"]\n[[c]]\nargv = [\"q\"]\n")

    # And a certificate in those spellings reads to the same payload.
    let canonical = canonicalPayload(minimal())
    let respelled = "schema = \"\"\"test-certificate.v1\"\"\"\n" &
      "[certificate]\n" &
      "vcs = { repo = 'example', content = \"git-tree-sha1:9f8e7d6c5b4a3928170695e4d3c2b1a099887766\", untracked = false }\n" &
      "command = [ { argv = [\"ct\", \"test\", \"run\"] } ]\n" &
      "framework = \"ct-test\"\nproject = \"example\"\nplatform = \"linux/amd64\"\n" &
      "targets = [\"t-unit\"]\nresult = \"passed\"\n" &
      "issued_at = \"2026-06-23T10:14:33Z\"\nissuer = '''ct-test@host'''\n"
    let read = readCertificate(respelled)
    checkpoint read.detail
    check read.status == crsOk
    check canonicalPayload(read.cert) == canonical

  test "a key store that cannot be applied unambiguously is unreadable":
    ## A store is a trust decision, so anything that leaves "which key, with
    ## which status" undecided has to be a loud failure.
    let noKeyId = readKeyStore("""
schema = "registered-keys.v1"

[[key]]
public_key = "ssh-ed25519 AAAA"
status = "active"
""")
    check not noKeyId.readable

    let noPublicKey = readKeyStore("""
schema = "registered-keys.v1"

[[key]]
key_id = "orphan"
status = "active"
""")
    check not noPublicKey.readable

    # The one that matters: revocation is a status flip rather than a deletion
    # (Verification.md §3.1), so an `active` duplicate listed ABOVE a `revoked`
    # entry would shadow the revocation under first-wins lookup and quietly
    # restore a key someone deliberately withdrew.
    let shadowed = readKeyStore("""
schema = "registered-keys.v1"

[[key]]
key_id = "rotated"
public_key = "ssh-ed25519 AAAA"
status = "active"

[[key]]
key_id = "rotated"
public_key = "ssh-ed25519 AAAA"
status = "revoked"
""")
    check not shadowed.readable
    check "twice" in shadowed.unreadableReason

  test "an unreadable key store is not an empty one":
    ## Verification.md §3.1 — an empty or missing store *answers* the question
    ## (nobody is trusted, fail-closed); a store that cannot be read answers
    ## nothing. Collapsing the two sends an operator to re-run tests when the
    ## fault is a corrupt configuration file.
    let empty = readKeyStore("schema = \"registered-keys.v1\"\n")
    check empty.readable
    check empty.keys.len == 0
    check empty.lookup("anything").isNone

    let broken = readKeyStore("[[key\nkey_id = \"x\n")
    check not broken.readable
    check broken.unreadableReason.len > 0

    let populated = readKeyStore("""
schema = "registered-keys.v1"

[[key]]
key_id = "current"
public_key = "ssh-ed25519 AAAA"
status = "active"

[[key]]
key_id = "retired"
public_key = "ssh-ed25519 BBBB"
status = "revoked"
""")
    check populated.readable
    check populated.keys.len == 2
    # Revocation is a status flip, never a deletion: the key still resolves,
    # and is then rejected for its status rather than for being unrecognised.
    check populated.lookup("retired").isSome
    check populated.lookup("retired").get.status == ksRevoked
    check populated.lookup("current").get.status == ksActive
