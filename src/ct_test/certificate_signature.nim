## The one signature *check* in this repository — split out of
## ``certificate_verification.nim`` so the verifier itself can be reached from
## code that has no subprocesses.
##
## Why this file exists
## --------------------
## ``certificate_verification.nim`` is the consumer half of the standard, and
## SB-1 needs it in the **status bar**, i.e. in a ViewModel that compiles on
## both Nim backends. Verifying a detached OpenSSH signature means running
## ``ssh-keygen``, which needs ``std/os`` and a process bridge, and neither
## exists under ``nim js``. Left in one module, the whole verifier was
## unreachable from the front end — and the only way to put a certificate in
## the status bar would have been to write a *second* verifier there, which is
## precisely the two-implementation drift this standard exists to prevent.
##
## So the split is along the dependency, not along the subject: the *algorithm*
## (framework filtering, authenticity, the VCS/platform match, coverage as a
## union, the three-valued outcome) stays in one place and is now pure; the
## *primitive* that needs a host lives here and is **injected**
## (``CertificateSignatureVerifier``). A consumer that has a host passes
## ``sshKeygenSignatureVerifier``; a consumer that has none passes nothing and
## gets ``scUndecidable`` — which is the honest answer and lands as
## **unverifiable**, never as "invalid" (Verification.md §7).
##
## Nothing here signs. There is no ``-Y sign`` in this file, and the only
## routine in CodeTracer that produces a certificate signature stays private to
## ``certificate_issuance.nim`` (Standard.md §6.2).

import std/[os, strutils]

import certificate
import certificate_verification
import process_exec

export SignatureCheck, CertificateSignatureVerifier

proc shellQuote(value: string): string =
  ## POSIX single-quote quoting. Written out rather than pulled from
  ## ``std/strutils`` so the escaping is visible at the one place it matters:
  ## these strings are temporary-directory paths this process created, but a
  ## ``TMPDIR`` containing a quote would otherwise be a command injection.
  result = "'"
  for ch in value:
    if ch == '\'':
      result.add "'\\''"
    else:
      result.add ch
  result.add "'"

proc verifyDetachedSignature*(payload, publicKey, signatureValue: string):
    tuple[check: SignatureCheck; detail: string] =
  ## Verify a detached OpenSSH signature over ``payload`` under the
  ## ``test-certificate-v1`` namespace (Standard.md §6.1).
  ##
  ## ``publicKey`` is an ``ssh-ed25519 AAAA…`` line; ``signatureValue`` is the
  ## base64 blob a certificate carries in ``signature.value``. ``ssh-keygen``
  ## reads the armored form instead, and the conversion is pure framing.
  ##
  ## The identity is arbitrary: an SSH signature blob binds the **namespace and
  ## the public key**, not a principal — the principal only selects a line in
  ## ``allowed_signers``.
  ##
  ## Returns ``scUndecidable`` — never ``scInvalid`` — when the check could not
  ## be *made* (no ``ssh-keygen``, unwritable temp dir). A consumer that
  ## reported "invalid signature" for a missing tool would send an operator to
  ## re-run tests over a configuration fault.
  if publicKey.len == 0:
    return (scInvalid, "no public key to verify against")
  if signatureValue.len == 0:
    return (scInvalid, "no signature value")

  let workDir = getTempDir() / "ct-test-cert-verify-" & $getCurrentProcessId() &
                "-" & $signatureValue.len & "-" & $payload.len
  try:
    createDir(workDir)
  except OSError as err:
    return (scUndecidable,
            "could not create a verification work directory: " & err.msg)
  defer:
    try: removeDir(workDir)
    except OSError: discard

  const identity = "certificate-signer@ct-test.invalid"
  let
    payloadPath = workDir / "payload"
    signaturePath = workDir / "signature"
    allowedPath = workDir / "allowed_signers"
  try:
    writeFile(payloadPath, payload)
    writeFile(signaturePath,
      "-----BEGIN SSH SIGNATURE-----\n" & signatureValue &
      "\n-----END SSH SIGNATURE-----\n")
    writeFile(allowedPath, identity & " " & publicKey.strip() & "\n")
  except IOError as err:
    return (scUndecidable, "could not stage the verification inputs: " & err.msg)

  # `ssh-keygen -Y verify` reads the signed data from stdin, so this goes
  # through the shell purely for the redirection.
  let command =
    "ssh-keygen -Y verify -f " & shellQuote(allowedPath) &
    " -I " & shellQuote(identity) &
    " -n " & shellQuote(SignatureNamespace) &
    " -s " & shellQuote(signaturePath) &
    " < " & shellQuote(payloadPath)
  let run = execCapturedShell(command, cwd = workDir)
  if run.exitCode == 0:
    return (scValid, "")
  let output = run.output.strip()
  if "not found" in output and "ssh-keygen" in output:
    return (scUndecidable, "ssh-keygen is not available: " & output)
  (scInvalid, if output.len > 0: output else: "signature did not verify")

proc sshKeygenSignatureVerifier*(): CertificateSignatureVerifier =
  ## The verifier to hand ``verifyCertificates`` on a host that has
  ## ``ssh-keygen``. Returned as a closure rather than exported as a bare proc
  ## so the injection point reads the same at every call site.
  proc(payload, publicKey, signatureValue: string):
      tuple[check: SignatureCheck; detail: string] {.closure, gcsafe.} =
    verifyDetachedSignature(payload, publicKey, signatureValue)
